import Foundation

enum BlockType: String, Codable, CaseIterable, Identifiable {
    case paragraph
    case heading1
    case heading2
    case heading3
    case quote
    case callout
    case bulletList
    case numberedList
    case divider

    var id: String { rawValue }

    var label: String {
        switch self {
        case .paragraph: "Paragraph"
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .quote: "Quote"
        case .callout: "Callout"
        case .bulletList: "Bullet list"
        case .numberedList: "Numbered list"
        case .divider: "Divider"
        }
    }

    var icon: String {
        switch self {
        case .paragraph: "text.alignleft"
        case .heading1: "textformat.size.larger"
        case .heading2: "textformat.size"
        case .heading3: "textformat.size.smaller"
        case .quote: "text.quote"
        case .callout: "exclamationmark.bubble"
        case .bulletList: "list.bullet"
        case .numberedList: "list.number"
        case .divider: "minus"
        }
    }

    var markdownPrefix: String? {
        switch self {
        case .heading1: "# "
        case .heading2: "## "
        case .heading3: "### "
        case .quote: "> "
        case .bulletList: "- "
        case .numberedList: "1. "
        default: nil
        }
    }
}

struct Block: Identifiable, Codable, Equatable {
    let id: UUID
    var type: BlockType
    var content: String

    init(id: UUID = UUID(), type: BlockType = .paragraph, content: String = "") {
        self.id = id
        self.type = type
        self.content = content
    }

    static func detectShortcut(in text: String) -> (BlockType, String)? {
        let shortcuts: [(String, BlockType)] = [
            ("### ", .heading3),
            ("## ", .heading2),
            ("# ", .heading1),
            ("> ", .quote),
            ("- ", .bulletList),
            ("* ", .bulletList),
            ("1. ", .numberedList),
            ("--- ", .divider),
            ("! ", .callout),
        ]

        for (prefix, type) in shortcuts {
            if text.hasPrefix(prefix) {
                let remaining = String(text.dropFirst(prefix.count))
                return (type, remaining)
            }
        }
        return nil
    }
}
