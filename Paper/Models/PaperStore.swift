import Foundation
import SwiftData
import Observation

/// One store shared by the app window and Siri / Shortcuts actions.
@MainActor
enum PaperData {
    static let container = makeContainer()
    static let store = PaperStore(context: container.mainContext)

    /// Opens the store; if an old store can't be migrated, moves it aside as a backup and starts fresh.
    private static func makeContainer() -> ModelContainer {
        let configuration = ModelConfiguration()
        if let container = try? ModelContainer(for: Document.self, Folder.self, configurations: configuration) {
            return container
        }

        let fileManager = FileManager.default
        let storeURL = configuration.url
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-shm", "-wal"] {
            let file = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: file.path) else { continue }
            let backup = URL(fileURLWithPath: storeURL.path + ".backup-\(stamp)" + suffix)
            try? fileManager.moveItem(at: file, to: backup)
        }

        do {
            return try ModelContainer(for: Document.self, Folder.self, configurations: configuration)
        } catch {
            fatalError("Could not open the paper store: \(error)")
        }
    }
}

@Observable
@MainActor
final class PaperStore {
    private let context: ModelContext
    private(set) var documents: [Document] = []
    private(set) var folders: [Folder] = []
    /// Set when a paper should open in a window from outside the UI (Siri, Shortcuts).
    var pendingOpen: PersistentIdentifier?
    /// The iCloud Drive "Paper" folder; nil on the iPhone until the user picks it.
    private(set) var folderURL: URL?
    @ObservationIgnored private var syncTimer: Timer?

    init(context: ModelContext) {
        self.context = context
        reload()
        connectFiles(PaperLocation.resolve())
    }

    func document(for id: PersistentIdentifier?) -> Document? {
        guard let id else { return nil }
        return documents.first { $0.persistentModelID == id }
    }

    /// The paper a window should show when none was chosen: the newest one, or a fresh paper.
    func defaultPaperID() -> PersistentIdentifier {
        documents.first?.persistentModelID ?? newPaper()
    }

    @discardableResult
    func newPaper(style: PaperStyle = .dotted) -> PersistentIdentifier {
        let doc = Document(paperStyle: style)
        context.insert(doc)
        try? context.save()
        reload()
        return doc.persistentModelID
    }

    @discardableResult
    func addPaper(with text: String) -> PersistentIdentifier {
        let doc = Document(content: text, paperStyle: documents.first?.paperStyle ?? .dotted)
        context.insert(doc)
        try? context.save()
        reload()
        writeFiles()
        pendingOpen = doc.persistentModelID
        return doc.persistentModelID
    }

    func setStyle(_ style: PaperStyle, for doc: Document) {
        doc.paperStyle = style
        doc.syncedAt = nil
        try? context.save()
        writeFiles()
    }

    func delete(_ doc: Document) {
        if let path = doc.syncedPath, let url = fileURL(path) { FileOps.delete(url) }
        context.delete(doc)
        try? context.save()
        reload()
    }

    // MARK: Folders

    func folder(for id: String?) -> Folder? {
        guard let id else { return nil }
        return folders.first { $0.folderID == id }
    }

    func folders(in parentID: String?) -> [Folder] {
        folders.filter { $0.parentID == parentID }
    }

    func papers(in folderID: String?) -> [Document] {
        documents.filter { $0.folderID == folderID }
    }

    func itemCount(in folder: Folder) -> Int {
        papers(in: folder.folderID).count + folders(in: folder.folderID).count
    }

    @discardableResult
    func newFolder(in parentID: String?) -> Folder {
        let folder = Folder(name: "New folder", parentID: parentID)
        context.insert(folder)
        try? context.save()
        reload()
        writeFiles()
        return folder
    }

    func rename(_ folder: Folder, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        folder.name = trimmed.isEmpty ? "Untitled folder" : trimmed
        try? context.save()
        reload()
        writeFiles()
    }

    /// Deletes the folder but keeps what's inside: its papers and subfolders move up a level.
    func delete(_ folder: Folder) {
        for paper in papers(in: folder.folderID) { paper.folderID = folder.parentID }
        for child in folders(in: folder.folderID) { child.parentID = folder.parentID }
        let path = folder.syncedPath
        context.delete(folder)
        try? context.save()
        reload()
        // Move the contents up on disk first, then remove the empty folder.
        writeFiles()
        if let path { removeFolderOnDisk(path) }
    }

    func move(_ paper: Document, to folderID: String?) {
        paper.folderID = folderID
        try? context.save()
        reload()
        writeFiles()
    }

    // MARK: Files in iCloud Drive

    #if os(iOS)
    /// The iPhone picks the Paper folder once; after that it's remembered.
    func chooseFolder(_ url: URL) {
        connectFiles(PaperLocation.choose(url))
    }
    #endif

    private func connectFiles(_ url: URL?) {
        folderURL = url
        guard url != nil else { return }
        syncFiles()
        syncTimer?.invalidate()
        // Pick up changes made on the other device.
        syncTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncFiles() }
        }
    }

    /// Reads what changed on disk, then writes what changed here.
    func syncFiles() {
        readFiles()
        writeFiles()
    }

    private func fileURL(_ path: String) -> URL? {
        guard let folderURL else { return nil }
        return path.isEmpty ? folderURL : folderURL.appending(path: path)
    }

    private struct DiskFile {
        let url: URL
        let modified: Date
    }

    /// Everything in the Paper folder: subfolders, Markdown files, and files iCloud hasn't downloaded yet.
    private func scanDisk() -> (folders: Set<String>, files: [String: DiskFile], pending: Set<String>)? {
        guard let folderURL, FileOps.exists(folderURL) else { return nil }
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        var folders = Set<String>()
        var files: [String: DiskFile] = [:]
        var pending = Set<String>()

        func walk(_ directory: URL, _ relative: String) {
            let items = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
            for item in items {
                let name = item.lastPathComponent
                if name.hasPrefix(".") {
                    // A file still in the cloud shows up as ".Name.md.icloud": ask for it, and count it as there.
                    if name.hasSuffix(".icloud") {
                        let real = String(name.dropFirst().dropLast(".icloud".count))
                        if real.lowercased().hasSuffix(".md") {
                            pending.insert(PaperPath.join(relative, real))
                            try? fileManager.startDownloadingUbiquitousItem(at: directory.appending(path: real))
                        }
                    }
                    continue
                }
                let path = PaperPath.join(relative, name)
                let values = try? item.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    folders.insert(path)
                    walk(item, path)
                } else if name.lowercased().hasSuffix(".md") {
                    files[path] = DiskFile(url: item, modified: values?.contentModificationDate ?? .distantPast)
                }
            }
        }
        walk(folderURL, "")
        return (folders, files, pending)
    }

    /// Brings in papers and folders that were added, changed, moved or deleted on the other device.
    private func readFiles() {
        guard let disk = scanDisk() else { return }
        var changed = false
        var updated: [Document] = []

        // Folders: every folder on disk gets a folder here, parents first.
        var folderByPath: [String: Folder] = [:]
        for folder in folders { if let path = folder.syncedPath { folderByPath[path] = folder } }
        for path in disk.folders.sorted(by: { PaperPath.depth($0) < PaperPath.depth($1) }) where folderByPath[path] == nil {
            let folder = Folder(name: PaperPath.name(path), parentID: folderByPath[PaperPath.parent(path)]?.folderID)
            folder.syncedPath = path
            context.insert(folder)
            folderByPath[path] = folder
            changed = true
        }
        func folderID(forFileAt path: String) -> String? {
            let directory = PaperPath.parent(path)
            return directory.isEmpty ? nil : folderByPath[directory]?.folderID
        }

        // Papers: match by path first, then by the ID in the front matter (moved or renamed files).
        var byPath: [String: Document] = [:]
        var byID: [String: Document] = [:]
        for doc in documents {
            if let path = doc.syncedPath { byPath[path] = doc }
            if let id = doc.fileID { byID[id] = doc }
        }
        var seen = Set<PersistentIdentifier>()
        let known = disk.files.filter { byPath[$0.key] != nil }
        let unknown = disk.files.filter { byPath[$0.key] == nil }

        for (path, file) in known {
            guard let doc = byPath[path] else { continue }
            seen.insert(doc.persistentModelID)
            guard doc.fileDate != file.modified else { continue }
            guard let text = FileOps.read(file.url) else { continue }
            if apply(PaperFile.parse(text), modified: file.modified, to: doc) { updated.append(doc) }
            changed = true
        }

        for (path, file) in unknown.sorted(by: { $0.key < $1.key }) {
            guard let text = FileOps.read(file.url) else { continue }
            let parsed = PaperFile.parse(text)
            if let id = parsed.id, let doc = byID[id], !seen.contains(doc.persistentModelID) {
                // Moved or renamed on the other device.
                seen.insert(doc.persistentModelID)
                doc.syncedPath = path
                doc.folderID = folderID(forFileAt: path)
                if apply(parsed, modified: file.modified, to: doc) { updated.append(doc) }
            } else {
                let doc = Document(content: parsed.body, paperStyle: parsed.style ?? .dotted)
                // A copy of a known file gets its own ID (written on the next save).
                doc.fileID = parsed.id.flatMap { byID[$0] == nil ? $0 : nil }
                doc.createdAt = parsed.created ?? file.modified
                doc.updatedAt = file.modified
                doc.syncedAt = doc.fileID == nil ? nil : file.modified
                doc.syncedPath = path
                doc.fileDate = file.modified
                doc.folderID = folderID(forFileAt: path)
                context.insert(doc)
                if let id = doc.fileID { byID[id] = doc }
                seen.insert(doc.persistentModelID)
            }
            changed = true
        }

        // Deleted on the other device. If the folder looks empty, iCloud may still be loading: keep everything.
        let diskIsEmpty = disk.files.isEmpty && disk.folders.isEmpty && disk.pending.isEmpty
        if !diskIsEmpty {
            for doc in documents where doc.syncedPath != nil && !seen.contains(doc.persistentModelID) {
                guard let path = doc.syncedPath, !disk.pending.contains(path) else { continue }
                context.delete(doc)
                changed = true
            }
            for folder in folders {
                guard let path = folder.syncedPath, !disk.folders.contains(path) else { continue }
                context.delete(folder)
                changed = true
            }
        }

        guard changed else { return }
        try? context.save()
        reload()
        for doc in updated {
            NotificationCenter.default.post(name: .paperChangedOnDisk, object: doc)
        }
    }

    /// Takes the file's version unless this paper has newer edits. Returns true when the text changed.
    private func apply(_ file: PaperFile, modified: Date, to doc: Document) -> Bool {
        doc.fileDate = modified
        if file.id == nil { doc.syncedAt = nil }  // Add the front matter on the next write.
        guard !doc.needsWrite || modified > doc.updatedAt else { return false }
        let textChanged = doc.markdown != file.body
        if textChanged { doc.applyFromDisk(file.body, modified: modified) }
        if let style = file.style { doc.paperStyle = style }
        if file.id != nil { doc.syncedAt = doc.updatedAt }
        return textChanged
    }

    /// Writes new and edited papers, and moves files and folders that were renamed or moved here.
    func writeFiles() {
        guard folderURL != nil else { return }
        for folder in folders.sorted(by: { depth(of: $0) < depth(of: $1) }) { writeFolder(folder) }
        for doc in documents { writePaper(doc) }
        try? context.save()
    }

    private func depth(of folder: Folder) -> Int {
        var depth = 0
        var parentID = folder.parentID
        while let id = parentID, depth < 32 {
            depth += 1
            parentID = self.folder(for: id)?.parentID
        }
        return depth
    }

    private func directoryPath(for folderID: String?) -> String? {
        guard let folderID else { return "" }
        guard let folder = folder(for: folderID) else { return "" }
        return folder.syncedPath
    }

    private func writeFolder(_ folder: Folder) {
        guard let parent = directoryPath(for: folder.parentID) else { return }
        let base = PaperPath.safeName(folder.name, fallback: "Untitled folder")
        if let current = folder.syncedPath, PaperPath.parent(current) == parent,
           PaperPath.name(current) == base, let url = fileURL(current) {
            if !FileOps.exists(url) { FileOps.createDirectory(url) }
            return
        }
        let target = freePath(in: parent, stem: base, ext: "", current: folder.syncedPath)
        guard let targetURL = fileURL(target) else { return }
        if let current = folder.syncedPath, let currentURL = fileURL(current), FileOps.exists(currentURL) {
            guard FileOps.move(currentURL, to: targetURL) else { return }
            renamePaths(from: current, to: target)
        } else {
            FileOps.createDirectory(targetURL)
        }
        folder.syncedPath = target
        // Two folders can't share a name on disk; show the name the folder really has.
        if PaperPath.name(target) != folder.name { folder.name = PaperPath.name(target) }
    }

    /// After a folder moves on disk, everything inside it has a new path.
    private func renamePaths(from old: String, to new: String) {
        func renamed(_ path: String?) -> String? {
            guard let path else { return nil }
            if path == old { return new }
            if path.hasPrefix(old + "/") { return new + path.dropFirst(old.count) }
            return path
        }
        for folder in folders { folder.syncedPath = renamed(folder.syncedPath) }
        for doc in documents { doc.syncedPath = renamed(doc.syncedPath) }
    }

    private func writePaper(_ doc: Document) {
        let isNew = doc.syncedPath == nil
        // A blank paper stays off disk until something is written on it.
        if isNew, doc.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        guard let directory = directoryPath(for: doc.folderID) else { return }
        let stem = PaperPath.safeName(doc.title, fallback: "Untitled")

        var target = doc.syncedPath ?? ""
        let currentStem = String(PaperPath.name(target).dropLast(3))
        if isNew || PaperPath.parent(target) != directory || !PaperPath.stem(currentStem, matches: stem) {
            target = freePath(in: directory, stem: stem, ext: ".md", current: doc.syncedPath)
        }
        guard let targetURL = fileURL(target) else { return }

        if let current = doc.syncedPath, current != target,
           let currentURL = fileURL(current), FileOps.exists(currentURL) {
            guard FileOps.move(currentURL, to: targetURL) else { return }
            doc.syncedPath = target
            doc.fileDate = FileOps.modificationDate(targetURL)
        }

        guard isNew || doc.needsWrite || !FileOps.exists(targetURL) else { return }
        if doc.fileID == nil { doc.fileID = UUID().uuidString }
        let text = PaperFile.render(id: doc.fileID ?? "", style: doc.paperStyle, created: doc.createdAt, body: doc.markdown)
        guard FileOps.write(text, to: targetURL) else { return }
        doc.syncedPath = target
        doc.syncedAt = doc.updatedAt
        doc.fileDate = FileOps.modificationDate(targetURL)
    }

    /// "Plan.md", or "Plan 2.md" if that's taken. A path the item already has counts as free.
    private func freePath(in directory: String, stem: String, ext: String, current: String?) -> String {
        var number = 1
        while true {
            let name = number == 1 ? stem : "\(stem) \(number)"
            let path = PaperPath.join(directory, name + ext)
            if path.lowercased() == current?.lowercased() { return path }
            if let url = fileURL(path), !FileOps.exists(url) { return path }
            number += 1
        }
    }

    /// Removes a deleted folder from disk, moving up anything that isn't a paper first.
    private func removeFolderOnDisk(_ path: String) {
        guard let url = fileURL(path) else { return }
        let parent = PaperPath.parent(path)
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        for item in leftovers where item.lastPathComponent != ".DS_Store" {
            let name = item.deletingPathExtension().lastPathComponent
            let ext = item.pathExtension.isEmpty ? "" : "." + item.pathExtension
            if let destination = fileURL(freePath(in: parent, stem: name, ext: ext, current: nil)) {
                FileOps.move(item, to: destination)
            }
        }
        FileOps.delete(url)
    }

    private func reload() {
        let descriptor = FetchDescriptor<Document>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        documents = (try? context.fetch(descriptor)) ?? []
        let folderDescriptor = FetchDescriptor<Folder>(sortBy: [SortDescriptor(\.name)])
        folders = (try? context.fetch(folderDescriptor)) ?? []
    }
}

extension Notification.Name {
    /// Posted with the Document whose text changed in its file, so an open editor can show it.
    static let paperChangedOnDisk = Notification.Name("PaperChangedOnDisk")
}
