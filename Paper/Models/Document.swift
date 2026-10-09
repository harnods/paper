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
        get { PaperStyle(rawValue: paperStyleRaw) ?? .plain }
        set { paperStyleRaw = newValue.rawValue }
    }

    var blocks: [Block] {
        get {
            guard !blocksJSON.isEmpty,
                  let data = blocksJSON.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([Block].self, from: data) else {
                if !content.isEmpty {
                    return [Block(type: .paragraph, content: content)]
                }
                return [Block()]
            }
            return decoded.isEmpty ? [Block()] : decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                blocksJSON = json
            }
        }
    }

    init(
        title: String = "",
        content: String = "",
        paperStyle: PaperStyle = .plain
    ) {
        self.title = title
        self.content = content
        self.blocksJSON = ""
        self.createdAt = Date()
        self.updatedAt = Date()
        self.paperStyleRaw = paperStyle.rawValue
    }
}
