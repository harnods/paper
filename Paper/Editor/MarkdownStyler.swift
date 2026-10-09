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

    var placeholder: String? {
        switch self {
        case .heading(1): "Heading 1"
        case .heading(2): "Heading 2"
        case .heading: "Heading 3"
        case .bullet, .numbered: "List"
        case .quote: "Quote"
        case .callout: "Callout"
        default: nil
        }
    }
}

struct LineInfo {
    var kind: LineKind
    /// Length (UTF-16) of the markdown prefix, including leading indentation.
    var markerLength: Int
    var indent: String

    var level: Int {
        indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 4
    }

    /// Line markers that are hidden and replaced by drawing (bullets, bars, boxes) or styling.
    var hidesMarker: Bool {
        if case .numbered = kind { return false }
        return markerLength > 0
    }
}

/// A run of markdown syntax that is styled away (zero width).
struct HiddenRange {
    var range: NSRange
    /// Line prefixes cover the line start, so the caret may not sit anywhere inside them.
    var isLinePrefix: Bool
}

struct StyleResult {
    var kinds: [LineKind]
    var hidden: [HiddenRange]
}

extension NSAttributedString.Key {
    static let paperHidden = NSAttributedString.Key("paperHidden")
}

enum MarkdownStyler {
    static let textColor = NSColor.black
    static let placeholderColor = NSColor.black.withAlphaComponent(0.25)
    static let highlightColor = NSColor(red: 1.0, green: 0.88, blue: 0.35, alpha: 0.55)
    static let bodySize: CGFloat = 16
    static let bodyLineHeight: CGFloat = 26
    static let blockSpacing: CGFloat = 12
    static let listItemSpacing: CGFloat = 4
    static let listIndent: CGFloat = 24

    static var bodyFont: NSFont { .systemFont(ofSize: bodySize) }
    private static let metrics = NSLayoutManager()

    static func font(for kind: LineKind) -> NSFont {
        switch kind {
        case .title: .systemFont(ofSize: 36, weight: .bold)
        case .heading(1): .systemFont(ofSize: 30, weight: .semibold)
        case .heading(2): .systemFont(ofSize: 24, weight: .semibold)
        case .heading: .systemFont(ofSize: 20, weight: .semibold)
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

    /// Restyles the whole storage; returns each line's kind and the hidden syntax ranges.
    @discardableResult
    static func style(_ storage: NSTextStorage) -> StyleResult {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        var result = StyleResult(kinds: [], hidden: [])

        storage.beginEditing()
        storage.setAttributes(attributes(for: .body), range: full)

        var lineIndex = 0
        ns.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, range, enclosing, _ in
            let line = ns.substring(with: range)
            let info = parse(line, isFirst: lineIndex == 0)
            result.kinds.append(info.kind)
            styleLine(storage, range: range, enclosing: enclosing, line: line, info: info, result: &result)
            if lineIndex == 1 {
                addSpaceBelowTitle(storage, enclosing: enclosing)
            }
            lineIndex += 1
        }
        // A trailing newline leaves an empty last line that enumerateSubstrings skips.
        if ns.length == 0 || ns.hasSuffix("\n") {
            result.kinds.append(result.kinds.isEmpty ? .title : .body)
        }

        storage.endEditing()
        return result
    }

    static func attributes(for kind: LineKind, info: LineInfo? = nil, markerWidth: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        let font = font(for: kind)
        let paragraph = NSMutableParagraphStyle()
        let natural = metrics.defaultLineHeight(for: font)

        switch kind {
        case .title:
            paragraph.lineSpacing = max(0, font.pointSize * 1.2 - natural)
        case .heading(let level):
            paragraph.lineSpacing = max(0, font.pointSize * 1.3 - natural)
            paragraph.paragraphSpacingBefore = level == 1 ? 20 : level == 2 ? 16 : 12
            paragraph.paragraphSpacing = 6
        default:
            paragraph.lineSpacing = max(0, bodyLineHeight - natural)
            paragraph.paragraphSpacing = blockSpacing
        }

        let level = CGFloat(info?.level ?? 0)
        switch kind {
        case .bullet:
            paragraph.firstLineHeadIndent = level * listIndent + listIndent
            paragraph.headIndent = paragraph.firstLineHeadIndent
            paragraph.paragraphSpacing = listItemSpacing
        case .numbered:
            paragraph.headIndent = markerWidth
            paragraph.paragraphSpacing = listItemSpacing
        case .quote:
            paragraph.firstLineHeadIndent = 18
            paragraph.headIndent = 18
        case .callout:
            paragraph.firstLineHeadIndent = 38
            paragraph.headIndent = 38
            paragraph.tailIndent = -14
            paragraph.paragraphSpacingBefore = 6
            paragraph.paragraphSpacing = blockSpacing + 6
        default:
            break
        }

        return [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
    }

    /// Space between the title and the first block, set as space before the first block.
    static let titleGap: CGFloat = 28

    private static func addSpaceBelowTitle(_ storage: NSTextStorage, enclosing: NSRange) {
        guard enclosing.length > 0,
              let current = storage.attribute(.paragraphStyle, at: enclosing.location, effectiveRange: nil) as? NSParagraphStyle,
              let style = current.mutableCopy() as? NSMutableParagraphStyle else { return }
        style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, titleGap)
        storage.addAttribute(.paragraphStyle, value: style, range: enclosing)
    }

    private static func hide(_ range: NSRange, in storage: NSTextStorage, isLinePrefix: Bool, result: inout StyleResult) {
        guard range.length > 0 else { return }
        storage.addAttribute(.paperHidden, value: true, range: range)
        result.hidden.append(HiddenRange(range: range, isLinePrefix: isLinePrefix))
    }

    private static func styleLine(_ storage: NSTextStorage, range: NSRange, enclosing: NSRange, line: String,
                                  info: LineInfo, result: inout StyleResult) {
        let font = font(for: info.kind)
        let markerRange = NSRange(location: range.location, length: min(info.markerLength, range.length))
        let markerWidth = (storage.attributedSubstring(from: markerRange).string as NSString)
            .size(withAttributes: [.font: font]).width

        // Paragraph attributes span the newline so spacing applies even to empty lines.
        storage.addAttributes(attributes(for: info.kind, info: info, markerWidth: markerWidth), range: enclosing)

        if info.hidesMarker {
            hide(markerRange, in: storage, isLinePrefix: true, result: &result)
        }

        if info.kind != .divider, range.length > markerRange.length {
            styleInline(storage, range: range, baseFont: font, result: &result)
        }
    }

    private static let bold = try! NSRegularExpression(pattern: "\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*")
    private static let italic = try! NSRegularExpression(pattern: "(?<![*\\w])\\*(?=[^*\\s])(.+?)(?<=[^*\\s])\\*(?![*\\w])")
    private static let code = try! NSRegularExpression(pattern: "`([^`\\n]+)`")
    private static let strike = try! NSRegularExpression(pattern: "~~(?=\\S)(.+?)(?<=\\S)~~")
    private static let highlight = try! NSRegularExpression(pattern: "==(?=\\S)(.+?)(?<=\\S)==")

    private static func styleInline(_ storage: NSTextStorage, range: NSRange, baseFont: NSFont, result: inout StyleResult) {
        let text = storage.string
        let manager = NSFontManager.shared

        func apply(_ regex: NSRegularExpression, markerLength: Int, _ body: (NSRange) -> Void) {
            for match in regex.matches(in: text, options: [], range: range) {
                let whole = match.range
                body(match.range(at: 1))
                hide(NSRange(location: whole.location, length: markerLength), in: storage, isLinePrefix: false, result: &result)
                hide(NSRange(location: NSMaxRange(whole) - markerLength, length: markerLength), in: storage,
                     isLinePrefix: false, result: &result)
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
        apply(highlight, markerLength: 2) { inner in
            storage.addAttribute(.backgroundColor, value: highlightColor, range: inner)
        }
        apply(code, markerLength: 1) { inner in
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: baseFont.pointSize - 1, weight: .regular), range: inner)
            storage.addAttribute(.backgroundColor, value: NSColor.black.withAlphaComponent(0.05), range: inner)
        }
    }
}
#endif
