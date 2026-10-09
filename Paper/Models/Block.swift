import Foundation

/// Legacy block format, kept only to migrate documents saved by the earlier block editor.
struct Block: Codable {
    var type: String
    var content: String

    var markdown: String {
        switch type {
        case "heading1": "# " + content
        case "heading2": "## " + content
        case "heading3": "### " + content
        case "quote": "> " + content
        case "callout": "! " + content
        case "bulletList": "- " + content
        case "numberedList": "1. " + content
        case "divider": "---"
        default: content
        }
    }
}
