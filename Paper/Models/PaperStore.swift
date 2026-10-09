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

    init(context: ModelContext) {
        self.context = context
        reload()
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
        pendingOpen = doc.persistentModelID
        return doc.persistentModelID
    }

    func setStyle(_ style: PaperStyle, for doc: Document) {
        doc.paperStyle = style
        try? context.save()
    }

    func delete(_ doc: Document) {
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
        return folder
    }

    func rename(_ folder: Folder, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        folder.name = trimmed.isEmpty ? "Untitled folder" : trimmed
        try? context.save()
        reload()
    }

    /// Deletes the folder but keeps what's inside: its papers and subfolders move up a level.
    func delete(_ folder: Folder) {
        for paper in papers(in: folder.folderID) { paper.folderID = folder.parentID }
        for child in folders(in: folder.folderID) { child.parentID = folder.parentID }
        context.delete(folder)
        try? context.save()
        reload()
    }

    func move(_ paper: Document, to folderID: String?) {
        paper.folderID = folderID
        try? context.save()
        reload()
    }

    private func reload() {
        let descriptor = FetchDescriptor<Document>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        documents = (try? context.fetch(descriptor)) ?? []
        let folderDescriptor = FetchDescriptor<Folder>(sortBy: [SortDescriptor(\.name)])
        folders = (try? context.fetch(folderDescriptor)) ?? []
    }
}
