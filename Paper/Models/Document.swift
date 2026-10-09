import Foundation
import SwiftData

@Model
final class Document {
    var title: String
    var content: String
    var blocksJSON: String
    var createdAt: Date
    var updatedAt: Date
    var paperStyleRaw: String

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
