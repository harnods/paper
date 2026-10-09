#if os(iOS)
import UIKit
import SwiftUI

/// The iPhone editor. It uses the same Markdown engine as the Mac (MarkdownStyler) and draws the
/// same bullets, numbers, checkboxes, quote bar, callout, divider and dotted paper.
final class PaperTextView: UITextView, UITextViewDelegate {
    private(set) var lineKinds: [LineKind] = []
    private var hiddenRanges: [HiddenRange] = []
    private var cachedLineRanges: [NSRange]?
    /// Edited span since the last restyle, in post-edit coordinates; nil means restyle everything.
    private var pendingDirty: NSRange?
    private var lastCaret = 0
    private var isAdjustingSelection = false
    private var didChangeFired = false
    private var lastInserted: String?
    /// Start of the line where "/" opened the block list.
    private var slashLineStart: Int?

    var paperStyle: PaperStyle = .dotted {
        didSet { if paperStyle != oldValue { decoration.setNeedsDisplay() } }
    }
    var onTextChange: ((String) -> Void)?

    private let decoration = PaperDecorationView()
    private lazy var keyboardBar = PaperKeyboardBar(textView: self)
    private let checkboxTap = CheckboxTapHandler()

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)

        delegate = self
        backgroundColor = .white
        tintColor = .black
        textColor = MarkdownStyler.textColor
        textContainerInset = UIEdgeInsets(top: 24, left: 20, bottom: 160, right: 20)
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        inputAccessoryView = keyboardBar

        decoration.textView = self
        insertSubview(decoration, at: 0)

        checkboxTap.textView = self
        let tap = UITapGestureRecognizer(target: checkboxTap, action: #selector(CheckboxTapHandler.tapped(_:)))
        tap.delegate = checkboxTap
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func load(_ markdown: String) {
        textStorage.setAttributedString(NSAttributedString(string: markdown))
        pendingDirty = nil
        restyle()
        undoManager?.removeAllActions()
    }

    /// Readable line length: on wide screens (landscape, iPad) the text stays a centred column,
    /// about as wide as the Mac paper's text.
    private static let maxTextWidth: CGFloat = 660 - 2 * MarkdownStyler.pageInset
    private static let minSideInset: CGFloat = 20

    override func layoutSubviews() {
        let side = max(Self.minSideInset, ((bounds.width - Self.maxTextWidth) / 2).rounded())
        if textContainerInset.left != side {
            textContainerInset.left = side
            textContainerInset.right = side
        }
        super.layoutSubviews()
        // The decoration layer covers only what's on screen and redraws as you scroll.
        if decoration.frame != bounds {
            decoration.frame = bounds
            decoration.setNeedsDisplay()
        }
        sendSubviewToBack(decoration)
    }

    // MARK: Lines

    var nsString: NSString { text as NSString }

    func lineRanges() -> [NSRange] {
        if let cachedLineRanges { return cachedLineRanges }
        var ranges: [NSRange] = []
        var start = 0
        let ns = nsString
        while true {
            let newline = ns.range(of: "\n", options: [], range: NSRange(location: start, length: ns.length - start))
            if newline.location == NSNotFound {
                ranges.append(NSRange(location: start, length: ns.length - start))
                break
            }
            ranges.append(NSRange(location: start, length: newline.location - start))
            start = newline.location + 1
        }
        cachedLineRanges = ranges
        return ranges
    }

    func lineIndex(at location: Int, in ranges: [NSRange]) -> Int {
        ranges.lastIndex { $0.location <= location } ?? 0
    }

    private func currentLine() -> (index: Int, range: NSRange, info: LineInfo) {
        let ranges = lineRanges()
        let index = lineIndex(at: selectedRange.location, in: ranges)
        let range = ranges[index]
        return (index, range, MarkdownStyler.parse(nsString.substring(with: range), isFirst: index == 0))
    }

    func restyle() {
        cachedLineRanges = nil
        let result = MarkdownStyler.style(textStorage, dirty: pendingDirty)
        pendingDirty = nil
        lineKinds = result.kinds
        hiddenRanges = result.hidden
        updateTypingAttributes()
        decoration.setNeedsDisplay()
    }

    /// Same as the Mac: an empty paper types in the title style; an empty line under the title gets
    /// the gap below the title.
    private func updateTypingAttributes() {
        let ranges = lineRanges()
        var attributes: [NSAttributedString.Key: Any]
        if textStorage.length == 0 {
            attributes = MarkdownStyler.attributes(for: .title)
        } else if ranges.count == 2, ranges[1].length == 0 {
            attributes = MarkdownStyler.attributes(for: .body)
            if let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                style.paragraphSpacingBefore = MarkdownStyler.titleGap
                attributes[.paragraphStyle] = style
            }
        } else {
            attributes = MarkdownStyler.attributes(for: currentLine().index == 0 ? .title : .body)
        }
        typingAttributes = attributes
    }

    // MARK: Editing

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        hiddenRanges = []
        cachedLineRanges = nil
        if handleKey(range, text) { return false }
        recordEdit(range, text)
        lastInserted = text
        return true
    }

    private func recordEdit(_ range: NSRange, _ text: String) {
        let edited = NSRange(location: range.location, length: (text as NSString).length)
        pendingDirty = pendingDirty.map { NSUnionRange($0, edited) } ?? edited
    }

    func textViewDidChange(_ textView: UITextView) {
        didChangeFired = true
        afterChange()
    }

    private func afterChange() {
        restyle()
        let inserted = lastInserted
        lastInserted = nil
        if inserted == " " { convertCheckboxShortcut() }
        if inserted == "/" { openSlashIfNeeded() }
        updateSlashMenu()
        onTextChange?(text)
    }

    /// Replaces text with undo, then restyles.
    func replace(_ range: NSRange, with string: String, caret: Int? = nil) {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return }
        hiddenRanges = []
        cachedLineRanges = nil
        recordEdit(range, string)
        didChangeFired = false
        replace(textRange, withText: string)
        if !didChangeFired { afterChange() }
        if let caret { selectedRange = NSRange(location: min(caret, nsString.length), length: 0) }
    }

    private func handleKey(_ range: NSRange, _ text: String) -> Bool {
        let selection = selectedRange
        let line = currentLine()

        if text == "\n", let items = slashMatches(), let first = items.first {
            applySlashItem(first)
            return true
        }

        if text == "\n", range.length == 0, selection.length == 0, line.info.kind.continuesOnReturn {
            if line.range.length - line.info.markerLength == 0 {
                replace(NSRange(location: line.range.location, length: line.info.markerLength), with: "",
                        caret: line.range.location)
                return true
            }
            let marker: String
            switch line.info.kind {
            case .numbered(let n): marker = line.info.indent + "\(n + 1). "
            case .todo: marker = line.info.indent + "- [ ] "
            case .quote: marker = "> "
            default: marker = line.info.indent + "- "
            }
            replace(range, with: "\n" + marker, caret: range.location + 1 + (marker as NSString).length)
            return true
        }

        // Backspace right after a hidden marker removes the marker (the line becomes text).
        if text.isEmpty, range.length == 1, selection.length == 0, line.info.markerLength > 0,
           line.info.kind != .title, line.info.kind != .divider,
           selection.location == line.range.location + line.info.markerLength {
            replace(NSRange(location: line.range.location, length: line.info.markerLength), with: "",
                    caret: line.range.location)
            return true
        }
        return false
    }

    /// Typing "[] " or "[ ] " at the start of a line turns it into a to-do.
    private func convertCheckboxShortcut() {
        let line = currentLine()
        guard line.index > 0 else { return }
        let lineText = nsString.substring(with: line.range)
        let indent = String(lineText.prefix(while: { $0 == " " || $0 == "\t" }))
        let rest = lineText.dropFirst(indent.count)
        for shortcut in ["[] ", "[ ] "] where rest.hasPrefix(shortcut) {
            let range = NSRange(location: line.range.location + indent.utf16.count, length: shortcut.utf16.count)
            replace(range, with: "- [ ] ", caret: range.location + 6 + (selectedRange.location - NSMaxRange(range)))
            return
        }
    }

    // MARK: Hidden syntax

    /// Keeps the caret out of hidden syntax, like on the Mac.
    private func snappedCaret(_ location: Int, from old: Int) -> Int {
        for hidden in hiddenRanges {
            let start = hidden.range.location
            let end = NSMaxRange(hidden.range)
            if hidden.isLinePrefix {
                guard location >= start, location < end else { continue }
                if location == old - 1, start > 0 { return start - 1 }
                return end
            } else if location > start, location < end {
                return location < old ? start : end
            }
        }
        return location
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !isAdjustingSelection else { return }
        let selection = selectedRange
        if selection.length == 0 {
            let snapped = snappedCaret(selection.location, from: lastCaret)
            if snapped != selection.location {
                isAdjustingSelection = true
                selectedRange = NSRange(location: snapped, length: 0)
                isAdjustingSelection = false
            }
        }
        lastCaret = selectedRange.location
        let lines = lineRanges()
        if textStorage.length == 0 || (lines.count == 2 && lines[1].length == 0) {
            updateTypingAttributes()
            layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: textStorage.length),
                                           actualCharacterRange: nil)
        }
        updateSlashMenu()
        keyboardBar.update()
        decoration.setNeedsDisplay()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        decoration.setNeedsDisplay()
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        decoration.setNeedsDisplay()
        return resigned
    }

    // MARK: Caret

    /// Top of the text line holding `location`, without paragraph spacing, in view coordinates.
    private func lineTop(at location: Int) -> CGFloat? {
        let ns = nsString
        let origin = textContainerInset.top
        if location >= ns.length, ns.length == 0 || ns.hasSuffix("\n") {
            let rect = layoutManager.extraLineFragmentRect
            guard !rect.isEmpty else { return nil }
            let style = typingAttributes[.paragraphStyle] as? NSParagraphStyle
            return rect.minY + origin + (style?.paragraphSpacingBefore ?? 0)
        }
        let character = min(location, ns.length - 1)
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        var effective = NSRange()
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &effective)
        let paragraph = ns.paragraphRange(for: NSRange(location: character, length: 0))
        let firstGlyph = layoutManager.glyphIndexForCharacter(at: paragraph.location)
        var before: CGFloat = 0
        if NSLocationInRange(firstGlyph, effective),
           let style = textStorage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle {
            before = style.paragraphSpacingBefore
        }
        return rect.minY + origin + before
    }

    /// The line box is taller than the text; keep the caret to the font's height, where the text sits.
    override func caretRect(for position: UITextPosition) -> CGRect {
        let rect = super.caretRect(for: position)
        let location = offset(from: beginningOfDocument, to: position)
        let ranges = lineRanges()
        let index = lineIndex(at: location, in: ranges)
        let kind = index < lineKinds.count ? lineKinds[index] : .body
        guard let top = lineTop(at: location) else { return rect }
        let font = MarkdownStyler.font(for: kind)
        return CGRect(x: rect.minX, y: top + MarkdownStyler.textTop(for: kind).rounded(),
                      width: rect.width, height: ceil(font.ascender - font.descender))
    }

    // MARK: Format commands

    @objc func toggleBoldMarkdown() { toggleWrap("**") }
    @objc func toggleItalicMarkdown() { toggleWrap("*") }
    @objc func toggleCodeMarkdown() { toggleWrap("`") }
    @objc func toggleStrikeMarkdown() { toggleWrap("~~") }
    @objc func toggleHighlightMarkdown() { toggleWrap("==") }

    private func isHidden(_ index: Int) -> Bool {
        guard index >= 0, index < nsString.length else { return false }
        return textStorage.attribute(.paperHidden, at: index, effectiveRange: nil) != nil
    }

    private func syntaxRun(_ text: String, hasMarker marker: String, atEnd: Bool) -> Bool {
        guard marker == "*" else { return atEnd ? text.hasSuffix(marker) : text.hasPrefix(marker) }
        let stars = atEnd ? text.reversed().prefix(while: { $0 == "*" }).count : text.prefix(while: { $0 == "*" }).count
        return stars == 1 || stars == 3
    }

    /// Same as the Mac: adds or removes `marker` around the selection, never stacking markers.
    private func toggleWrap(_ marker: String) {
        let ns = nsString
        let m = (marker as NSString).length
        var sel = selectedRange
        while sel.length > 0, isHidden(sel.location) { sel.location += 1; sel.length -= 1 }
        while sel.length > 0, isHidden(NSMaxRange(sel) - 1) { sel.length -= 1 }

        var left = sel.location
        while isHidden(left - 1) { left -= 1 }
        var right = NSMaxRange(sel)
        while isHidden(right) { right += 1 }
        let leftRun = ns.substring(with: NSRange(location: left, length: sel.location - left))
        let rightRun = ns.substring(with: NSRange(location: NSMaxRange(sel), length: right - NSMaxRange(sel)))
        let inner = ns.substring(with: sel)

        if sel.length > 0, syntaxRun(leftRun, hasMarker: marker, atEnd: true), syntaxRun(rightRun, hasMarker: marker, atEnd: false) {
            replace(NSRange(location: sel.location - m, length: sel.length + 2 * m), with: inner)
            selectedRange = NSRange(location: sel.location - m, length: sel.length)
            return
        }
        if sel.length > 0, leftRun != marker, syntaxRun(leftRun, hasMarker: marker, atEnd: false),
           syntaxRun(rightRun, hasMarker: marker, atEnd: true) {
            let newLeft = String(leftRun.dropFirst(marker.count))
            let newRight = String(rightRun.dropLast(marker.count))
            replace(NSRange(location: left, length: right - left), with: newLeft + inner + newRight)
            selectedRange = NSRange(location: left + (newLeft as NSString).length, length: sel.length)
            return
        }
        replace(sel, with: marker + inner + marker)
        selectedRange = NSRange(location: sel.location + m, length: sel.length)
    }

    static let blockItems: [(label: String, prefix: String)] = [
        ("Text", ""),
        ("Heading 1", "# "),
        ("Heading 2", "## "),
        ("Heading 3", "### "),
        ("Bullet list", "- "),
        ("Numbered list", "1. "),
        ("To-do list", "- [ ] "),
        ("Quote", "> "),
        ("Callout", "! "),
        ("Divider", "---"),
    ]

    /// Turns the line at the caret into another block type.
    func setLinePrefix(_ prefix: String) {
        let line = currentLine()
        guard line.index > 0 else { return }
        if prefix == "---" {
            let end = NSMaxRange(line.range)
            replace(NSRange(location: end, length: 0), with: "\n---\n", caret: end + 5)
            return
        }
        let offset = selectedRange.location - line.range.location - line.info.markerLength
        let markerRange = NSRange(location: line.range.location,
                                  length: line.info.kind == .divider ? line.range.length : line.info.markerLength)
        replace(markerRange, with: prefix, caret: line.range.location + (prefix as NSString).length + max(offset, 0))
    }

    func currentBlockLabel() -> String {
        switch currentLine().info.kind {
        case .title: "Title"
        case .heading(1): "Heading 1"
        case .heading(2): "Heading 2"
        case .heading: "Heading 3"
        case .bullet: "Bullet list"
        case .numbered: "Numbered list"
        case .todo: "To-do list"
        case .quote: "Quote"
        case .callout: "Callout"
        case .divider: "Divider"
        case .body: "Text"
        }
    }

    var isOnTitle: Bool { currentLine().index == 0 }

    // MARK: Slash menu

    private func openSlashIfNeeded() {
        let line = currentLine()
        guard line.index > 0, nsString.substring(with: line.range) == "/" else { return }
        slashLineStart = line.range.location
        updateSlashMenu()
    }

    /// Block types matching what's typed after "/", or nil when the menu is closed.
    func slashMatches() -> [(label: String, prefix: String)]? {
        guard let start = slashLineStart, start < nsString.length else { return nil }
        let ranges = lineRanges()
        let index = lineIndex(at: start, in: ranges)
        let line = ranges[index]
        let lineText = nsString.substring(with: line)
        guard line.location == start, lineText.hasPrefix("/"),
              NSLocationInRange(selectedRange.location, NSRange(location: start, length: line.length + 1)) else { return nil }
        let query = lineText.dropFirst().lowercased()
        let items = Self.blockItems.filter { query.isEmpty || $0.label.lowercased().contains(query) }
        return items.isEmpty ? nil : items
    }

    private func updateSlashMenu() {
        let matches = slashMatches()
        if matches == nil { slashLineStart = nil }
        keyboardBar.showSlashItems(matches)
    }

    func applySlashItem(_ item: (label: String, prefix: String)) {
        guard let start = slashLineStart else { return }
        let ranges = lineRanges()
        let line = ranges[lineIndex(at: start, in: ranges)]
        slashLineStart = nil
        if item.prefix == "---" {
            replace(line, with: "---\n", caret: line.location + 4)
        } else {
            replace(line, with: item.prefix, caret: line.location + (item.prefix as NSString).length)
        }
        updateSlashMenu()
    }

    func closeSlashMenu() {
        slashLineStart = nil
        updateSlashMenu()
    }

    // MARK: Edit menu

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange,
                  suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard range.length > 0, !isOnTitle else { return UIMenu(children: suggestedActions) }
        let format = UIMenu(title: "Format", children: [
            UIAction(title: "Bold", image: UIImage(systemName: "bold")) { [weak self] _ in self?.toggleBoldMarkdown() },
            UIAction(title: "Italic", image: UIImage(systemName: "italic")) { [weak self] _ in self?.toggleItalicMarkdown() },
            UIAction(title: "Strikethrough", image: UIImage(systemName: "strikethrough")) { [weak self] _ in self?.toggleStrikeMarkdown() },
            UIAction(title: "Code", image: UIImage(systemName: "chevron.left.forwardslash.chevron.right")) { [weak self] _ in self?.toggleCodeMarkdown() },
            UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in self?.toggleHighlightMarkdown() },
        ])
        return UIMenu(children: [format] + suggestedActions)
    }

    // MARK: To-dos

    func checkboxRect(forLine index: Int, ranges: [NSRange]) -> CGRect? {
        guard index > 0, index < ranges.count, index < lineKinds.count,
              case .todo = lineKinds[index],
              let line = geometry(forLineAt: ranges[index].location) else { return nil }
        let info = MarkdownStyler.parse(nsString.substring(with: ranges[index]), isFirst: false)
        let size = MarkdownStyler.checkboxSize
        let font = MarkdownStyler.bodyFont
        let textMid = line.firstLine.minY + MarkdownStyler.textTop(for: .body) + (font.ascender - font.descender) / 2
        let x = line.content.minX + CGFloat(info.level) * MarkdownStyler.listIndent + 2
        return CGRect(x: x, y: (textMid - size / 2).rounded(), width: size, height: size)
    }

    /// The to-do line whose checkbox is at `point` (with a finger-sized margin).
    func checkboxLine(at point: CGPoint) -> Int? {
        let ranges = lineRanges()
        for index in visibleLines(in: bounds, ranges: ranges) {
            if let box = checkboxRect(forLine: index, ranges: ranges), box.insetBy(dx: -12, dy: -10).contains(point) {
                return index
            }
        }
        return nil
    }

    func toggleTodo(line index: Int) {
        let ranges = lineRanges()
        guard index < ranges.count else { return }
        let info = MarkdownStyler.parse(nsString.substring(with: ranges[index]), isFirst: false)
        guard case .todo(let checked) = info.kind else { return }
        let mark = NSRange(location: ranges[index].location + info.indent.utf16.count + 3, length: 1)
        let selection = selectedRange
        replace(mark, with: checked ? " " : "x")
        selectedRange = selection
    }

    // MARK: Geometry

    struct LineGeometry {
        var fragment: CGRect
        var content: CGRect
        var firstLine: CGRect
    }

    /// Same measurements as the Mac editor, in this view's content coordinates.
    func geometry(forLineAt location: Int) -> LineGeometry? {
        let ns = nsString
        var fragments: [CGRect] = []
        if location >= ns.length {
            var rect = layoutManager.extraLineFragmentRect
            if rect.isEmpty {
                rect = CGRect(x: 0, y: 0, width: textContainer.size.width, height: MarkdownStyler.bodyLineHeight)
            }
            fragments = [rect]
        } else {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let glyphs = layoutManager.glyphRange(forCharacterRange: paragraph, actualCharacterRange: nil)
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                fragments.append(rect)
            }
        }
        guard let first = fragments.first else { return nil }
        let union = fragments.dropFirst().reduce(first) { $0.union($1) }

        let style = location < ns.length
            ? textStorage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            : nil
        let before = style?.paragraphSpacingBefore ?? 0
        let lineSpacing = style?.lineSpacing ?? 0
        let after = (style?.paragraphSpacing ?? 0) + lineSpacing
        let padding = textContainer.lineFragmentPadding

        func toView(_ rect: CGRect) -> CGRect {
            CGRect(x: textContainerInset.left + padding, y: rect.minY + textContainerInset.top,
                   width: textContainer.size.width - padding * 2, height: rect.height)
        }

        var content = toView(union)
        content.origin.y += before
        content.size.height = max(0, content.height - before - after)

        var firstLine = toView(first)
        firstLine.origin.y += before
        firstLine.size.height = max(0, firstLine.height - before - (fragments.count == 1 ? after : lineSpacing))

        return LineGeometry(fragment: toView(union), content: content, firstLine: firstLine)
    }

    func visibleLines(in rect: CGRect, ranges: [NSRange]) -> ClosedRange<Int> {
        guard !ranges.isEmpty else { return 0...0 }
        let containerRect = rect.offsetBy(dx: -textContainerInset.left, dy: -textContainerInset.top)
        let glyphs = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = lineIndex(at: chars.location, in: ranges)
        let last = lineIndex(at: NSMaxRange(chars), in: ranges)
        return first...max(first, last)
    }

    // MARK: Drawing

    private static let dotSpacing: CGFloat = 26

    private static let grain: UIColor = {
        let size = 128
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            var seed: UInt32 = 0x9E3779B9
            for y in 0..<size {
                for x in 0..<size {
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let v = Double(seed >> 24) / 255
                    guard v > 0.5 else { continue }
                    UIColor(white: 0, alpha: (v - 0.5) * 0.07).setFill()
                    context.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        return UIColor(patternImage: image)
    }()

    /// Draws the paper and the block decorations for the visible area (`visible` is in content coordinates).
    func drawDecorations(in visible: CGRect) {
        UIColor.white.setFill()
        UIRectFill(visible)
        Self.grain.setFill()
        UIRectFillUsingBlendMode(visible, .normal)

        if paperStyle == .dotted {
            let spacing = Self.dotSpacing
            let dot: CGFloat = 2.6
            UIColor.black.withAlphaComponent(0.2).setFill()
            let columns = Int(bounds.width / spacing)
            var y = (visible.minY / spacing).rounded(.down) * spacing
            while y < visible.maxY + spacing {
                for column in 1..<max(columns, 2) {
                    let x = CGFloat(column) * spacing
                    UIBezierPath(ovalIn: CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)).fill()
                }
                y += spacing
            }
        }

        let ranges = lineRanges()
        let lines = visibleLines(in: visible, ranges: ranges)
        var listCounts: [Int] = []
        for (index, kind) in lineKinds.enumerated() where index < ranges.count {
            var number = 0
            var numberLevel = 0
            if case .numbered = kind {
                numberLevel = MarkdownStyler.parse(nsString.substring(with: ranges[index]), isFirst: false).level
                if listCounts.count > numberLevel + 1 { listCounts.removeLast(listCounts.count - numberLevel - 1) }
                while listCounts.count < numberLevel + 1 { listCounts.append(0) }
                listCounts[numberLevel] += 1
                number = listCounts[numberLevel]
            } else {
                listCounts.removeAll()
            }
            guard lines.contains(index), kind != .body, kind != .title,
                  let line = geometry(forLineAt: ranges[index].location) else { continue }
            let content = line.content
            switch kind {
            case .divider:
                UIColor(red: 0xCA / 255, green: 0xD5 / 255, blue: 0xDA / 255, alpha: 1).setFill()
                UIRectFill(CGRect(x: 0, y: content.midY.rounded(), width: bounds.width, height: 1))
            case .callout:
                let box = CGRect(x: content.minX, y: content.minY - 8, width: content.width, height: content.height + 16)
                UIColor.black.withAlphaComponent(0.04).setFill()
                UIBezierPath(roundedRect: box, cornerRadius: 6).fill()
                ("\u{1F4A1}" as NSString).draw(at: CGPoint(x: content.minX + 12,
                                                         y: line.firstLine.minY + MarkdownStyler.textTop(for: .callout)),
                                                withAttributes: [.font: MarkdownStyler.bodyFont])
            case .quote:
                UIColor.black.withAlphaComponent(0.85).setFill()
                UIRectFill(CGRect(x: content.minX + 2, y: content.minY + 1, width: 3, height: max(content.height - 2, 0)))
            case .bullet:
                let info = MarkdownStyler.parse(nsString.substring(with: ranges[index]), isFirst: false)
                let x = content.minX + CGFloat(info.level) * MarkdownStyler.listIndent + 7
                let y = line.firstLine.minY + MarkdownStyler.textTop(for: .bullet)
                ("\u{2022}" as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
                    .font: MarkdownStyler.bodyFont,
                    .foregroundColor: MarkdownStyler.textColor,
                ])
            case .todo(let checked):
                guard let box = checkboxRect(forLine: index, ranges: ranges) else { break }
                let path = UIBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 4)
                if checked {
                    UIColor.black.withAlphaComponent(0.8).setFill()
                    path.fill()
                    let tick = UIBezierPath()
                    tick.move(to: CGPoint(x: box.minX + box.width * 0.27, y: box.minY + box.height * 0.52))
                    tick.addLine(to: CGPoint(x: box.minX + box.width * 0.44, y: box.minY + box.height * 0.69))
                    tick.addLine(to: CGPoint(x: box.minX + box.width * 0.75, y: box.minY + box.height * 0.33))
                    tick.lineWidth = 1.8
                    tick.lineCapStyle = .round
                    tick.lineJoinStyle = .round
                    UIColor.white.setStroke()
                    tick.stroke()
                } else {
                    path.lineWidth = 1.5
                    UIColor.black.withAlphaComponent(0.55).setStroke()
                    path.stroke()
                }
            case .numbered:
                let label = "\(number)." as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: MarkdownStyler.bodyFont,
                    .foregroundColor: MarkdownStyler.textColor,
                ]
                let width = label.size(withAttributes: attributes).width
                let right = content.minX + CGFloat(numberLevel) * MarkdownStyler.listIndent + MarkdownStyler.numberIndent - 6
                label.draw(at: CGPoint(x: right - width, y: line.firstLine.minY + MarkdownStyler.textTop(for: .numbered(1))),
                           withAttributes: attributes)
            default:
                break
            }
        }

        drawPlaceholders(ranges: ranges, visible: lines)
    }

    private func drawPlaceholders(ranges: [NSRange], visible: ClosedRange<Int>) {
        let isFocused = isFirstResponder && selectedRange.length == 0
        let caretLine = lineIndex(at: selectedRange.location, in: ranges)

        for index in visible where index < ranges.count {
            let range = ranges[index]
            let info = MarkdownStyler.parse(nsString.substring(with: range), isFirst: index == 0)
            guard range.length == info.markerLength else { continue }

            let placeholder: String
            if index == 0 {
                placeholder = "Untitled"
            } else if let text = info.kind.placeholder, info.markerLength > 0 {
                placeholder = text
            } else if info.kind == .body, isFocused, index == caretLine {
                placeholder = "Type / for commands"
            } else {
                continue
            }

            guard let line = geometry(forLineAt: range.location) else { continue }
            let style = range.location < nsString.length
                ? textStorage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                : typingAttributes[.paragraphStyle] as? NSParagraphStyle
            var y = line.firstLine.minY + MarkdownStyler.textTop(for: info.kind)
            if range.location >= nsString.length, let top = lineTop(at: range.location) {
                y = top + MarkdownStyler.textTop(for: info.kind)
            }
            let x = line.content.minX + max(style?.firstLineHeadIndent ?? 0, style?.headIndent ?? 0)
            (placeholder as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
                .font: MarkdownStyler.font(for: info.kind),
                .foregroundColor: MarkdownStyler.placeholderColor,
            ])
        }
    }
}

/// Sits behind the text and draws the paper for the part that's on screen.
final class PaperDecorationView: UIView {
    weak var textView: PaperTextView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = true
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let textView, let context = UIGraphicsGetCurrentContext() else { return }
        // Draw in the text view's content coordinates.
        context.translateBy(x: -frame.minX, y: -frame.minY)
        textView.drawDecorations(in: frame)
    }
}

/// Taps on a checkbox tick it, instead of moving the caret.
final class CheckboxTapHandler: NSObject, UIGestureRecognizerDelegate {
    weak var textView: PaperTextView?

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let textView else { return false }
        return textView.checkboxLine(at: gestureRecognizer.location(in: textView)) != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        // Win over the text view's own taps, so the caret doesn't jump to the checkbox.
        other.view === textView && other is UITapGestureRecognizer
    }

    @objc func tapped(_ recognizer: UITapGestureRecognizer) {
        guard let textView, let line = textView.checkboxLine(at: recognizer.location(in: textView)) else { return }
        textView.toggleTodo(line: line)
    }
}

/// The bar above the keyboard: block type and text formatting, or the block list after "/".
final class PaperKeyboardBar: UIInputView {
    private weak var textView: PaperTextView?
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let turnInto = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private var formatViews: [UIView] = []
    private var slashLabels: [String] = []

    init(textView: PaperTextView) {
        self.textView = textView
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 48), inputViewStyle: .default)
        allowsSelfSizing = false
        autoresizingMask = .flexibleWidth
        backgroundColor = .white

        let hairline = UIView()
        hairline.backgroundColor = UIColor.black.withAlphaComponent(0.1)
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        stack.axis = .horizontal
        stack.spacing = 2
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        doneButton.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        doneButton.tintColor = UIColor.black.withAlphaComponent(0.7)
        doneButton.accessibilityLabel = "Hide keyboard"
        doneButton.addAction(UIAction { [weak self] _ in self?.textView?.resignFirstResponder() }, for: .touchUpInside)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(doneButton)

        NSLayoutConstraint.activate([
            hairline.topAnchor.constraint(equalTo: topAnchor),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 44),
            doneButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            doneButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            doneButton.widthAnchor.constraint(equalToConstant: 44),
            doneButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        buildFormatButtons()
        showFormat()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildFormatButtons() {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = .black
        config.imagePlacement = .trailing
        config.imagePadding = 6
        config.image = UIImage(systemName: "chevron.down",
                               withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        turnInto.configuration = config
        turnInto.showsMenuAsPrimaryAction = true
        turnInto.contentHorizontalAlignment = .leading
        turnInto.widthAnchor.constraint(greaterThanOrEqualToConstant: 128).isActive = true
        turnInto.heightAnchor.constraint(equalToConstant: 44).isActive = true
        turnInto.menu = UIMenu(children: PaperTextView.blockItems.map { item in
            UIAction(title: item.label) { [weak self] _ in self?.textView?.setLinePrefix(item.prefix) }
        })

        let separator = UIView()
        separator.backgroundColor = UIColor.black.withAlphaComponent(0.1)
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 20).isActive = true

        formatViews = [
            turnInto,
            separator,
            iconButton("bold", "Bold") { $0.toggleBoldMarkdown() },
            iconButton("italic", "Italic") { $0.toggleItalicMarkdown() },
            iconButton("strikethrough", "Strikethrough") { $0.toggleStrikeMarkdown() },
            iconButton("chevron.left.forwardslash.chevron.right", "Inline code") { $0.toggleCodeMarkdown() },
            iconButton("highlighter", "Highlight") { $0.toggleHighlightMarkdown() },
            iconButton("checklist", "To-do list") { $0.setLinePrefix("- [ ] ") },
        ]
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: @escaping (PaperTextView) -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)),
                        for: .normal)
        button.tintColor = .black
        button.accessibilityLabel = label
        button.widthAnchor.constraint(equalToConstant: 44).isActive = true
        button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        button.addAction(UIAction { [weak self] _ in
            guard let textView = self?.textView else { return }
            action(textView)
        }, for: .touchUpInside)
        return button
    }

    private func setArranged(_ views: [UIView]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        views.forEach(stack.addArrangedSubview)
        scroll.contentOffset = .zero
    }

    private func showFormat() {
        slashLabels = []
        stack.spacing = 2
        setArranged(formatViews)
        update()
    }

    /// Refreshes the block label; formatting doesn't apply to the title.
    func update() {
        guard slashLabels.isEmpty, let textView else { return }
        turnInto.configuration?.attributedTitle = AttributedString(
            textView.currentBlockLabel(), attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15, weight: .medium)]))
        let enabled = !textView.isOnTitle
        for view in formatViews { (view as? UIControl)?.isEnabled = enabled }
        for view in formatViews { view.alpha = enabled ? 1 : 0.3 }
    }

    /// Shows the matching block types while "/" is open, and the formatting buttons otherwise.
    func showSlashItems(_ items: [(label: String, prefix: String)]?) {
        guard let items else {
            if !slashLabels.isEmpty { showFormat() }
            return
        }
        let labels = items.map(\.label)
        guard labels != slashLabels else { return }
        slashLabels = labels
        var views: [UIView] = items.map { item in
            var config = UIButton.Configuration.gray()
            config.baseForegroundColor = .black
            config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.05)
            config.cornerStyle = .capsule
            config.attributedTitle = AttributedString(item.label, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 15)]))
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
            let button = UIButton(configuration: config)
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            button.addAction(UIAction { [weak self] _ in self?.textView?.applySlashItem(item) }, for: .touchUpInside)
            return button
        }
        views.insert(iconButton("xmark", "Close") { $0.closeSlashMenu() }, at: 0)
        stack.spacing = 6
        setArranged(views)
    }
}

// MARK: SwiftUI

struct PaperEditorView: UIViewRepresentable {
    let document: Document
    let store: PaperStore

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, store: store)
    }

    func makeUIView(context: Context) -> PaperTextView {
        let textView = PaperTextView()
        textView.paperStyle = document.paperStyle
        textView.load(document.markdown)
        textView.onTextChange = { [weak coordinator = context.coordinator] text in
            coordinator?.scheduleSave(text)
        }
        context.coordinator.textView = textView
        context.coordinator.observe()
        // A new, empty paper opens ready to type; an existing one opens for reading.
        if document.markdown.isEmpty {
            DispatchQueue.main.async { textView.becomeFirstResponder() }
        }
        return textView
    }

    func updateUIView(_ textView: PaperTextView, context: Context) {
        textView.paperStyle = document.paperStyle
    }

    static func dismantleUIView(_ textView: PaperTextView, coordinator: Coordinator) {
        coordinator.flushSave()
    }

    @MainActor
    final class Coordinator: NSObject {
        let document: Document
        let store: PaperStore
        weak var textView: PaperTextView?
        private var observers: [NSObjectProtocol] = []
        private var saveTask: Task<Void, Never>?
        private var unsavedText: String?

        init(document: Document, store: PaperStore) {
            self.document = document
            self.store = store
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func observe() {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .paperChangedOnDisk, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.showChangesFromDisk() }
            })
            observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushSave() }
            })
        }

        func scheduleSave(_ text: String) {
            unsavedText = text
            saveTask?.cancel()
            saveTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.flushSave()
            }
        }

        func flushSave() {
            guard let text = unsavedText else { return }
            unsavedText = nil
            if text != document.markdown { document.markdown = text }
            store.writeFiles()
        }

        private func showChangesFromDisk() {
            guard unsavedText == nil, let textView, textView.text != document.markdown else { return }
            let selection = textView.selectedRange
            textView.load(document.markdown)
            let length = (textView.text as NSString).length
            textView.selectedRange = NSRange(location: min(selection.location, length), length: 0)
        }
    }
}
#endif
