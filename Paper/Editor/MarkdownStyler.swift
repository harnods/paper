#if os(macOS)
import AppKit

enum LineKind: Equatable {
    case title
    case heading(Int)
    case bullet
    case todo(checked: Bool)
    case numbered(Int)
    case quote
    case callout
    case divider
    case body

    var continuesOnReturn: Bool {
        switch self {
        case .bullet, .numbered, .quote, .todo: true
        default: false
        }
    }

    var placeholder: String? {
        switch self {
        case .heading(1): "Heading 1"
        case .heading(2): "Heading 2"
        case .heading: "Heading 3"
        case .bullet, .numbered: "List"
        case .todo: "To-do"
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
        markerLength > 0
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
    static let numberIndent: CGFloat = 28
    static let todoIndent: CGFloat = 28
    static let checkboxSize: CGFloat = 16
    static let secondaryTextColor = NSColor.black.withAlphaComponent(0.4)
    /// Space around the text on the page.
    static let pageInset: CGFloat = 56

    static let bodyFont = NSFont.systemFont(ofSize: bodySize)
    private static let titleFont = NSFont.systemFont(ofSize: 36, weight: .semibold)
    private static let heading1Font = NSFont.systemFont(ofSize: 30, weight: .semibold)
    private static let heading2Font = NSFont.systemFont(ofSize: 24, weight: .semibold)
    private static let heading3Font = NSFont.systemFont(ofSize: 20, weight: .semibold)
    /// Hidden syntax keeps its characters but draws them invisibly at near-zero width.
    private static let hiddenFont = NSFont.systemFont(ofSize: 0.01)
    private static let metrics = NSLayoutManager()

    static func font(for kind: LineKind) -> NSFont {
        switch kind {
        case .title: titleFont
        case .heading(1): heading1Font
        case .heading(2): heading2Font
        case .heading: heading3Font
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

        for (box, checked) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true)] where rest.hasPrefix(box) {
            return LineInfo(kind: .todo(checked: checked), markerLength: indent.utf16.count + 6, indent: indent)
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

    /// Returns each line's kind and the hidden syntax ranges for the whole storage, but only rewrites
    /// attributes for paragraphs touching `dirty` (all of them when nil). Rewriting attributes forces
    /// relayout, so limiting it to the edited paragraphs keeps typing fast in long papers.
    @discardableResult
    static func style(_ storage: NSTextStorage, dirty: NSRange? = nil) -> StyleResult {
        let ns = storage.string as NSString
        let full = NSRange(location: 0, length: ns.length)
        var result = StyleResult(kinds: [], hidden: [])
        var dirtyRange = full
        if let dirty {
            let start = min(dirty.location, ns.length)
            dirtyRange = ns.paragraphRange(for: NSRange(location: start, length: min(dirty.length, ns.length - start)))
        }

        storage.beginEditing()
        if dirty == nil {
            storage.setAttributes(attributes(for: .body), range: full)
        }

        var lineIndex = 0
        ns.enumerateSubstrings(in: full, options: [.byParagraphs, .substringNotRequired]) { _, range, enclosing, _ in
            let line = ns.substring(with: range)
            let info = parse(line, isFirst: lineIndex == 0)
            result.kinds.append(info.kind)
            // The title and the line under it depend on their position, so they are always restyled.
            let apply = dirty == nil || lineIndex <= 1 || NSIntersectionRange(enclosing, dirtyRange).length > 0
                || NSLocationInRange(enclosing.location, dirtyRange)
            if apply, dirty != nil {
                storage.setAttributes(attributes(for: .body), range: enclosing)
            }
            styleLine(storage, range: range, enclosing: enclosing, line: line, info: info, apply: apply, result: &result)
            if lineIndex == 1, apply {
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

    static func attributes(for kind: LineKind, info: LineInfo? = nil,
                           markerWidth: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        let font = font(for: kind)
        let paragraph = NSMutableParagraphStyle()
        // A fixed line height (also keeps lines made only of hidden syntax at full height).
        let height = lineHeight(for: kind)
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height

        switch kind {
        case .title:
            break
        case .heading(let level):
            paragraph.paragraphSpacingBefore = level == 1 ? 20 : level == 2 ? 16 : 12
            paragraph.paragraphSpacing = 6
        case .bullet, .numbered, .todo:
            paragraph.paragraphSpacing = listItemSpacing
        case .callout:
            paragraph.paragraphSpacingBefore = 6
            paragraph.paragraphSpacing = blockSpacing + 6
        default:
            paragraph.paragraphSpacing = blockSpacing
        }

        let level = CGFloat(info?.level ?? 0)
        switch kind {
        case .bullet:
            paragraph.firstLineHeadIndent = level * listIndent + listIndent
            paragraph.headIndent = paragraph.firstLineHeadIndent
        case .todo:
            paragraph.firstLineHeadIndent = level * listIndent + todoIndent
            paragraph.headIndent = paragraph.firstLineHeadIndent
        case .numbered:
            paragraph.firstLineHeadIndent = level * listIndent + numberIndent
            paragraph.headIndent = paragraph.firstLineHeadIndent
        case .quote:
            paragraph.firstLineHeadIndent = 18
            paragraph.headIndent = 18
        case .callout:
            paragraph.firstLineHeadIndent = 38
            paragraph.headIndent = 38
            paragraph.tailIndent = -14
        default:
            break
        }

        return [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
            .baselineOffset: baselineOffset(for: kind),
        ]
    }

    private static func naturalHeight(_ font: NSFont) -> CGFloat {
        metrics.defaultLineHeight(for: font)
    }

    /// Line box height per block type.
    static func lineHeight(for kind: LineKind) -> CGFloat {
        let font = font(for: kind)
        let natural = naturalHeight(font)
        switch kind {
        case .title: return max(natural, (font.pointSize * 1.2).rounded())
        case .heading: return max(natural, (font.pointSize * 1.3).rounded())
        default: return max(natural, bodyLineHeight)
        }
    }

    /// Extra line height would otherwise all sit above the glyphs; raising the baseline by half of
    /// it centres the text in its line box, like CSS line-height.
    static func baselineOffset(for kind: LineKind) -> CGFloat {
        max(0, (lineHeight(for: kind) - naturalHeight(font(for: kind))) / 2)
    }

    /// Distance from the top of a line box to the top of its text, for drawing alongside it.
    static func textTop(for kind: LineKind) -> CGFloat {
        let font = font(for: kind)
        return lineHeight(for: kind) + font.descender - baselineOffset(for: kind) - font.ascender
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

    private static func hide(_ range: NSRange, in storage: NSTextStorage, isLinePrefix: Bool, apply: Bool,
                             result: inout StyleResult) {
        guard range.length > 0 else { return }
        result.hidden.append(HiddenRange(range: range, isLinePrefix: isLinePrefix))
        guard apply else { return }
        storage.addAttributes([
            .paperHidden: true,
            .font: hiddenFont,
            .foregroundColor: NSColor.clear,
        ], range: range)
    }

    private static func styleLine(_ storage: NSTextStorage, range: NSRange, enclosing: NSRange, line: String,
                                  info: LineInfo, apply: Bool, result: inout StyleResult) {
        let font = font(for: info.kind)
        let markerRange = NSRange(location: range.location, length: min(info.markerLength, range.length))

        if apply {
            let markerWidth = (storage.attributedSubstring(from: markerRange).string as NSString)
                .size(withAttributes: [.font: font]).width
            // Paragraph attributes span the newline so spacing applies even to empty lines.
            storage.addAttributes(attributes(for: info.kind, info: info, markerWidth: markerWidth), range: enclosing)
        }

        if info.hidesMarker {
            hide(markerRange, in: storage, isLinePrefix: true, apply: apply, result: &result)
        }

        // A ticked to-do is struck through and greyed out. Set before inline styling, which then
        // hides any syntax inside the line.
        if apply, case .todo(checked: true) = info.kind, range.length > markerRange.length {
            let content = NSRange(location: NSMaxRange(markerRange), length: range.length - markerRange.length)
            storage.addAttributes([
                .foregroundColor: secondaryTextColor,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: secondaryTextColor,
            ], range: content)
        }

        if info.kind != .divider, range.length > markerRange.length {
            styleInline(storage, range: range, baseFont: font, apply: apply, result: &result)
        }
    }

    private static let bold = try! NSRegularExpression(pattern: "\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*")
    private static let italic = try! NSRegularExpression(pattern: "(?<![*\\w])\\*(?=[^*\\s])(.+?)(?<=[^*\\s])\\*(?![*\\w])")
    private static let code = try! NSRegularExpression(pattern: "`([^`\\n]+)`")
    private static let strike = try! NSRegularExpression(pattern: "~~(?=\\S)(.+?)(?<=\\S)~~")
    private static let highlight = try! NSRegularExpression(pattern: "==(?=\\S)(.+?)(?<=\\S)==")

    private static func styleInline(_ storage: NSTextStorage, range: NSRange, baseFont: NSFont, apply shouldApply: Bool,
                                    result: inout StyleResult) {
        let text = storage.string
        let manager = NSFontManager.shared

        func apply(_ regex: NSRegularExpression, markerLength: Int, _ body: (NSRange) -> Void) {
            for match in regex.matches(in: text, options: [], range: range) {
                let whole = match.range
                if shouldApply { body(match.range(at: 1)) }
                hide(NSRange(location: whole.location, length: markerLength), in: storage, isLinePrefix: false,
                     apply: shouldApply, result: &result)
                hide(NSRange(location: NSMaxRange(whole) - markerLength, length: markerLength), in: storage,
                     isLinePrefix: false, apply: shouldApply, result: &result)
            }
        }

        // "Bold" is drawn in semibold: full bold reads too heavy on the page.
        apply(bold, markerLength: 2) { inner in
            storage.enumerateAttribute(.font, in: inner, options: []) { value, sub, _ in
                let f = (value as? NSFont) ?? baseFont
                var strong = NSFont.systemFont(ofSize: f.pointSize, weight: .semibold)
                if manager.traits(of: f).contains(.italicFontMask) {
                    strong = manager.convert(strong, toHaveTrait: .italicFontMask)
                }
                storage.addAttribute(.font, value: strong, range: sub)
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
