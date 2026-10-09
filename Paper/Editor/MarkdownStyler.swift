#if os(macOS)
import AppKit

enum LineKind: Equatable {
    case title
    case heading(Int)
    case bullet
    case numbered(Int)
    case quote
    case callout
    case divider
    case body

    var continuesOnReturn: Bool {
        switch self {
        case .bullet, .numbered, .quote: true
        default: false
        }
    }
}

struct LineInfo {
    var kind: LineKind
    /// Length (UTF-16) of the markdown prefix, including leading indentation.
    var markerLength: Int
    var indent: String
}

enum MarkdownStyler {
    static let textColor = NSColor.black
    static let markerColor = NSColor.black.withAlphaComponent(0.22)
    static let placeholderColor = NSColor.black.withAlphaComponent(0.25)
    static let bodySize: CGFloat = 16
    static let bodyLineHeight: CGFloat = 26

    static var bodyFont: NSFont { .systemFont(ofSize: bodySize) }

    static func font(for kind: LineKind) -> NSFont {
        switch kind {
        case .title: .systemFont(ofSize: 30, weight: .bold)
        case .heading(1): .systemFont(ofSize: 26, weight: .bold)
        case .heading(2): .systemFont(ofSize: 21, weight: .semibold)
        case .heading: .systemFont(ofSize: 18, weight: .semibold)
        default: bodyFont
        }
    }

    static func parse(_ line: String, isFirst: Bool) -> LineInfo {
        if isFirst {
            let hashes = line.prefix(while: { $0 == "#" }).count
            let marker = hashes > 0 && line.dropFirst(hashes).hasPrefix(" ") ? hashes + 1 : 0
            return LineInfo(kind: .title, markerLength: marker, indent: "")
        }

        let indent = String(line.prefix(while: { $0 == " " || $0 == "\t" }))
        let rest = line.dropFirst(indent.count)

        if indent.isEmpty {
            for level in (1...3).reversed() where rest.hasPrefix(String(repeating: "#", count: level) + " ") {
                return LineInfo(kind: .heading(level), markerLength: level + 1, indent: "")
            }
            if rest.hasPrefix("> ") { return LineInfo(kind: .quote, markerLength: 2, indent: "") }
            if rest.hasPrefix("! ") { return LineInfo(kind: .callout, markerLength: 2, indent: "") }
            let trimmed = rest.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "***" {
                return LineInfo(kind: .divider, markerLength: (line as NSString).length, indent: "")
            }
        }

        if rest.hasPrefix("- ") || rest.hasPrefix("* ") || rest.hasPrefix("+ ") {
            return LineInfo(kind: .bullet, markerLength: indent.utf16.count + 2, indent: indent)
        }

        let digits = rest.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(". "), let number = Int(digits) {
            return LineInfo(kind: .numbered(number), markerLength: indent.utf16.count + digits.count + 2, indent: indent)
        }

        return LineInfo(kind: .body, markerLength: 0, indent: "")
    }

    /// Restyles the whole storage and returns the kind of each line, in order.
    @discardableResult
    static func style(_ storage: NSTextStorage) -> [LineKind] {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        var kinds: [LineKind] = []

        storage.beginEditing()
        storage.setAttributes(baseAttributes(for: .body, markerWidth: 0), range: full)

        var lineIndex = 0
        ns.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            let line = ns.substring(with: range)
            let info = parse(line, isFirst: lineIndex == 0)
            kinds.append(info.kind)
            styleLine(storage, range: range, line: line, info: info)
            lineIndex += 1
        }
        // A trailing newline leaves an empty last line that enumerateSubstrings skips.
        if ns.length == 0 || ns.hasSuffix("\n") {
            kinds.append(kinds.isEmpty ? .title : .body)
        }

        storage.endEditing()
        return kinds
    }

    static func baseAttributes(for kind: LineKind, markerWidth: CGFloat) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        switch kind {
        case .title:
            paragraph.paragraphSpacing = 10
        case .heading:
            paragraph.paragraphSpacingBefore = 10
            paragraph.paragraphSpacing = 2
        case .bullet, .numbered, .quote, .callout:
            paragraph.minimumLineHeight = bodyLineHeight
            paragraph.maximumLineHeight = bodyLineHeight
            paragraph.headIndent = markerWidth
        default:
            paragraph.minimumLineHeight = bodyLineHeight
            paragraph.maximumLineHeight = bodyLineHeight
        }
        return [
            .font: font(for: kind),
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
    }

    private static func styleLine(_ storage: NSTextStorage, range: NSRange, line: String, info: LineInfo) {
        guard range.length > 0 else {
            storage.addAttributes(baseAttributes(for: info.kind, markerWidth: 0), range: range)
            return
        }

        let font = font(for: info.kind)
        let markerRange = NSRange(location: range.location, length: min(info.markerLength, range.length))
        let markerWidth = (storage.attributedSubstring(from: markerRange).string as NSString)
            .size(withAttributes: [.font: font]).width

        storage.addAttributes(baseAttributes(for: info.kind, markerWidth: markerWidth), range: range)

        if info.kind == .quote {
            let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            storage.addAttribute(.font, value: italic, range: range)
        }

        if markerRange.length > 0 {
            storage.addAttribute(.foregroundColor, value: markerColor, range: markerRange)
        }

        if info.kind != .divider {
            styleInline(storage, range: range, baseFont: font)
        }
    }

    private static let bold = try! NSRegularExpression(pattern: "\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*")
    private static let italic = try! NSRegularExpression(pattern: "(?<![*\\w])\\*(?=[^*\\s])(.+?)(?<=[^*\\s])\\*(?![*\\w])")
    private static let code = try! NSRegularExpression(pattern: "`([^`\\n]+)`")
    private static let strike = try! NSRegularExpression(pattern: "~~(?=\\S)(.+?)(?<=\\S)~~")

    private static func styleInline(_ storage: NSTextStorage, range: NSRange, baseFont: NSFont) {
        let text = storage.string
        let manager = NSFontManager.shared

        func apply(_ regex: NSRegularExpression, markerLength: Int, _ body: (NSRange) -> Void) {
            regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
                guard let match else { return }
                let whole = match.range
                body(match.range(at: 1))
                storage.addAttribute(.foregroundColor, value: markerColor,
                                     range: NSRange(location: whole.location, length: markerLength))
                storage.addAttribute(.foregroundColor, value: markerColor,
                                     range: NSRange(location: NSMaxRange(whole) - markerLength, length: markerLength))
            }
        }

        apply(bold, markerLength: 2) { inner in
            storage.enumerateAttribute(.font, in: inner, options: []) { value, sub, _ in
                let f = (value as? NSFont) ?? baseFont
                storage.addAttribute(.font, value: manager.convert(f, toHaveTrait: .boldFontMask), range: sub)
            }
        }
        apply(italic, markerLength: 1) { inner in
            storage.enumerateAttribute(.font, in: inner, options: []) { value, sub, _ in
                let f = (value as? NSFont) ?? baseFont
                storage.addAttribute(.font, value: manager.convert(f, toHaveTrait: .italicFontMask), range: sub)
            }
        }
        apply(strike, markerLength: 2) { inner in
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: inner)
        }
        apply(code, markerLength: 1) { inner in
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular), range: inner)
            storage.addAttribute(.backgroundColor, value: NSColor.black.withAlphaComponent(0.05), range: inner)
        }
    }
}
#endif
