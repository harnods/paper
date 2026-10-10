import Foundation

/// Where papers live on disk: a "Paper" folder in iCloud Drive. Each paper is a Markdown file and
/// each folder is a real folder, so the Mac and the iPhone read and write the same files.
@MainActor
enum PaperLocation {
    private static let bookmarkKey = "paperFolderBookmark"

    #if os(macOS)
    /// The Mac app isn't sandboxed, so it can use the iCloud Drive folder directly.
    static func resolve() -> URL? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let iCloud = home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        // Without iCloud Drive, fall back to Documents so nothing is lost.
        let base = fileManager.fileExists(atPath: iCloud.path) ? iCloud : home.appending(path: "Documents", directoryHint: .isDirectory)
        let root = base.appending(path: "Paper", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    #else
    private static var accessed: URL?

    /// The iPhone can only reach iCloud Drive through a folder the user picked once; keep a bookmark to it.
    static func resolve() -> URL? {
        if let accessed { return accessed }
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
              url.startAccessingSecurityScopedResource() else { return nil }
        if stale, let fresh = try? url.bookmarkData() {
            UserDefaults.standard.set(fresh, forKey: bookmarkKey)
        }
        accessed = url
        return url
    }

    static func choose(_ url: URL) -> URL? {
        guard url.startAccessingSecurityScopedResource() else { return nil }
        guard let data = try? url.bookmarkData() else {
            url.stopAccessingSecurityScopedResource()
            return nil
        }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        accessed?.stopAccessingSecurityScopedResource()
        accessed = url
        return url
    }
    #endif
}

/// A paper as it's written on disk: a little front matter, then the Markdown.
///
///     ---
///     id: 7C1E…
///     style: dotted
///     created: 2026-10-09T08:00:00Z
///     ---
///     # Title
///     …
struct PaperFile {
    var id: String?
    var style: PaperStyle?
    var created: Date?
    var body: String

    private static let dateFormatter = ISO8601DateFormatter()

    static func parse(_ raw: String) -> PaperFile {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var file = PaperFile(body: text)
        guard text.hasPrefix("---\n") else { return file }
        let rest = text.dropFirst(4)
        let closing: Range<Substring.Index>
        if let range = rest.range(of: "\n---\n") {
            closing = range
        } else if rest.hasSuffix("\n---") {
            closing = rest.index(rest.endIndex, offsetBy: -4)..<rest.endIndex
        } else {
            return file
        }
        for line in rest[..<closing.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "id": file.id = value.isEmpty ? nil : value
            case "style": file.style = PaperStyle(rawValue: value)
            case "created": file.created = dateFormatter.date(from: value)
            default: break
            }
        }
        file.body = String(rest[closing.upperBound...])
        return file
    }

    static func render(id: String, style: PaperStyle, created: Date, body: String) -> String {
        "---\nid: \(id)\nstyle: \(style.rawValue)\ncreated: \(dateFormatter.string(from: created))\n---\n" + body
    }
}

/// File operations that play well with iCloud Drive (they go through a file coordinator).
enum FileOps {
    static func read(_ url: URL) -> String? {
        var text: String?
        var error: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { url in
            text = try? String(contentsOf: url, encoding: .utf8)
        }
        return text
    }

    @discardableResult
    static func write(_ text: String, to url: URL) -> Bool {
        var done = false
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { url in
            done = (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
        }
        return done
    }

    @discardableResult
    static func move(_ source: URL, to destination: URL) -> Bool {
        var done = false
        var error: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(writingItemAt: source, options: .forMoving,
                               writingItemAt: destination, options: .forReplacing, error: &error) { from, to in
            coordinator.item(at: from, willMoveTo: to)
            done = (try? FileManager.default.moveItem(at: from, to: to)) != nil
            if done { coordinator.item(at: from, didMoveTo: to) }
        }
        return done
    }

    /// On the Mac, deleted papers go to the Trash so they can be recovered.
    static func delete(_ url: URL) {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &error) { url in
            #if os(macOS)
            try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            #else
            try? FileManager.default.removeItem(at: url)
            #endif
        }
    }

    static func createDirectory(_ url: URL) {
        var error: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &error) { url in
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static func modificationDate(_ url: URL) -> Date? {
        var url = url
        url.removeAllCachedResourceValues()
        return try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}

/// Paths inside the Paper folder are kept relative, like "Work/Plan.md".
enum PaperPath {
    static func join(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : directory + "/" + name
    }

    static func parent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    static func name(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    static func depth(_ path: String) -> Int {
        path.isEmpty ? 0 : path.split(separator: "/").count
    }

    /// A name that's safe for a file or folder: no slashes or colons, no leading dot, not too long.
    static func safeName(_ title: String, fallback: String) -> String {
        var name = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return name.isEmpty ? fallback : name
    }

    /// "Plan.md" and "Plan 2.md" both count as named after the title "Plan".
    static func stem(_ stem: String, matches base: String) -> Bool {
        if stem == base { return true }
        guard stem.hasPrefix(base + " ") else { return false }
        return Int(stem.dropFirst(base.count + 1)) != nil
    }
}
