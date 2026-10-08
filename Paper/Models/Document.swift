import Foundation
import SwiftData

@Model
final class Document {
    var title: String
    var content: String
    var createdAt: Date
    var updatedAt: Date
    var paperStyleRaw: String

    var paperStyle: PaperStyle {
        get { PaperStyle(rawValue: paperStyleRaw) ?? .plain }
        set { paperStyleRaw = newValue.rawValue }
    }

    init(
        title: String = "",
        content: String = "",
        paperStyle: PaperStyle = .plain
    ) {
        self.title = title
        self.content = content
        self.createdAt = Date()
        self.updatedAt = Date()
        self.paperStyleRaw = paperStyle.rawValue
    }
}
