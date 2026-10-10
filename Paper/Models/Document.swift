import Foundation
import SwiftData

@Model
final class Document {
    var title: String = ""
    var content: String = ""
    var blocksJSON: String = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var paperStyleRaw: String = PaperStyle.dotted.rawValue
    /// The folder this paper is in; nil means the top level.
    var folderID: String?

    // Where this paper lives in the iCloud Drive "Paper" folder.
    /// Stable ID written in the file's front matter, so a renamed or moved file is still this paper.
    var fileID: String?
    /// Path of the file relative to the Paper folder, e.g. "Work/Plan.md"; nil until first written.
    var syncedPath: String?
    /// The `updatedAt` that was last written to or read from the file.
    var syncedAt: Date?
    /// The file's modification date when it was last written or read, to spot changes from the other device.
    var fileDate: Date?

    /// Changed here since the file was last written.
    var needsWrite: Bool {
        guard let syncedAt else { return true }
        return updatedAt > syncedAt
    }

    var paperStyle: PaperStyle {
        get { PaperStyle(rawValue: paperStyleRaw) ?? .dotted }
        set { paperStyleRaw = newValue.rawValue }
    }

    /// Markdown source. Older documents stored blocks as JSON; convert them once on read.
    var markdown: String {
        get {
            if content.isEmpty, !blocksJSON.isEmpty,
               let data = blocksJSON.data(using: .utf8),
               let blocks = try? JSONDecoder().decode([Block].self, from: data) {
                let body = blocks.map(\.markdown).joined(separator: "\n")
                return title.isEmpty ? body : title + "\n" + body
            }
            return content
        }
        set {
            content = newValue
            blocksJSON = ""
            title = Document.title(from: newValue)
            updatedAt = Date()
        }
    }

    /// Takes text that changed in the file on the other device.
    func applyFromDisk(_ text: String, modified: Date) {
        content = text
        blocksJSON = ""
        title = Document.title(from: text)
        updatedAt = modified
    }

    static func title(from markdown: String) -> String {
        let firstLine = markdown.split(separator: "\n", omittingEmptySubsequences: false).first ?? ""
        return firstLine.drop(while: { $0 == "#" || $0 == " " }).trimmingCharacters(in: .whitespaces)
    }

    init(content: String = "", paperStyle: PaperStyle = .dotted) {
        self.title = Document.title(from: content)
        self.content = content
        self.blocksJSON = ""
        self.createdAt = Date()
        self.updatedAt = Date()
        self.paperStyleRaw = paperStyle.rawValue
    }
}
