#if os(macOS)
import AppKit

final class PaperTextView: NSTextView {
    private(set) var lineKinds: [LineKind] = []
    private var hiddenRanges: [HiddenRange] = []
    private lazy var formatToolbar = FormatToolbar(textView: self)
    /// Selection left by a style action; the toolbar stays closed until the selection changes.
    private var dismissedSelection: NSRange?
    private var hoveredLine: Int?
    /// The + or drag handle under the pointer, drawn darker on a soft background.
    private var hoveredControl: BlockControl?
    private enum BlockControl { case plus, handle }
    private var dropIndicatorY: CGFloat?
    private var isDraggingBlock = false
    var paperMenuItems: (() -> [NSMenuItem])?

    private let handleWidth: CGFloat = 18

    // MARK: Lines

    var nsString: NSString { string as NSString }

    /// Content range of every line, excluding the newline.
    func lineRanges() -> [NSRange] {
        if let cachedLineRanges { return cachedLineRanges }
        let ranges = computeLineRanges()
        cachedLineRanges = ranges
        return ranges
    }

    private var cachedLineRanges: [NSRange]?
    /// Edited span since the last restyle, in post-edit coordinates; nil means restyle everything.
    private var pendingDirty: NSRange?

    private func computeLineRanges() -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        let ns = nsString
        while true {
            let search = NSRange(location: start, length: ns.length - start)
            let newline = ns.range(of: "\n", options: [], range: search)
            if newline.location == NSNotFound {
                ranges.append(NSRange(location: start, length: ns.length - start))
                return ranges
            }
            ranges.append(NSRange(location: start, length: newline.location - start))
            start = newline.location + 1
        }
    }

    func lineIndex(at location: Int, in ranges: [NSRange]) -> Int {
        ranges.lastIndex { $0.location <= location } ?? 0
    }

    func restyle() {
        guard let storage = textStorage else { return }
        cachedLineRanges = nil
        let result = MarkdownStyler.style(storage, dirty: pendingDirty)
        pendingDirty = nil
        lineKinds = result.kinds
        hiddenRanges = result.hidden
        updateTypingAttributes()
        needsDisplay = true
    }

    /// Empty lines at the end have no characters to take styling from, so they would be laid out
    /// (and the caret and placeholder drawn) with default spacing. An empty paper gets the title
    /// style; an empty line right under the title gets the gap below the title.
    @discardableResult
    private func updateTypingAttributes() -> Bool {
        let ranges = lineRanges()
        var attributes: [NSAttributedString.Key: Any]
        var isSpecial = true
        if (textStorage?.length ?? 0) == 0 {
            attributes = MarkdownStyler.attributes(for: .title)
        } else if ranges.count == 2, ranges[1].length == 0 {
            attributes = MarkdownStyler.attributes(for: .body)
            if let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                style.paragraphSpacingBefore = MarkdownStyler.titleGap
                attributes[.paragraphStyle] = style
            }
        } else {
            attributes = MarkdownStyler.attributes(for: .body)
            isSpecial = false
        }
        typingAttributes = attributes
        return isSpecial
    }

    // MARK: Hidden syntax

    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        // Hidden ranges are stale until the edit is restyled; don't snap against them meanwhile.
        hiddenRanges = []
        formatToolbar.isHidden = true
        cachedLineRanges = nil
        let allowed = super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
        if allowed {
            // Remember what changed so restyling only touches those paragraphs.
            let edited = NSRange(location: affectedCharRange.location, length: (replacementString as NSString?)?.length ?? 0)
            pendingDirty = pendingDirty.map { NSUnionRange($0, edited) } ?? edited
        }
        return allowed
    }

    /// Keeps the caret out of hidden syntax so arrow keys never seem to stick.
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

    /// Replaces text through the normal editing path so undo works.
    func replace(_ range: NSRange, with text: String, caret: Int? = nil) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        if let caret {
            setSelectedRange(NSRange(location: caret, length: 0))
        }
    }

    private func currentLine() -> (index: Int, range: NSRange, info: LineInfo) {
        let ranges = lineRanges()
        let index = lineIndex(at: selectedRange().location, in: ranges)
        let range = ranges[index]
        let info = MarkdownStyler.parse(nsString.substring(with: range), isFirst: index == 0)
        return (index, range, info)
    }

    // MARK: Keyboard

    override func doCommand(by selector: Selector) {
        if handleCommand(selector) { return }
        super.doCommand(by: selector)
    }

    private func handleCommand(_ selector: Selector) -> Bool {
        let selection = selectedRange()
        let line = currentLine()

        switch selector {
        case #selector(insertNewline(_:)):
            guard selection.length == 0, line.info.kind.continuesOnReturn else { return false }
            let contentLength = line.range.length - line.info.markerLength
            if contentLength == 0 {
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
            insertText("\n" + marker, replacementRange: selection)
            return true

        case #selector(deleteBackward(_:)):
            guard selection.length == 0, line.info.markerLength > 0, line.info.kind != .title,
                  line.info.kind != .divider,
                  selection.location == line.range.location + line.info.markerLength
            else { return false }
            replace(NSRange(location: line.range.location, length: line.info.markerLength), with: "",
                    caret: line.range.location)
            return true

        case #selector(insertTab(_:)):
            guard [.bullet, .numbered(0), .todo(checked: false)].contains(where: { sameKind($0, line.info.kind) })
            else { return false }
            replace(NSRange(location: line.range.location, length: 0), with: "    ",
                    caret: selection.location + 4)
            return true

        case #selector(insertBacktab(_:)):
            let lineText = nsString.substring(with: line.range)
            let spaces = min(lineText.prefix(while: { $0 == " " }).count, 4)
            guard spaces > 0 else { return true }
            replace(NSRange(location: line.range.location, length: spaces), with: "",
                    caret: max(selection.location - spaces, line.range.location))
            return true

        default:
            return false
        }
    }

    private func sameKind(_ a: LineKind, _ b: LineKind) -> Bool {
        switch (a, b) {
        case (.numbered, .numbered), (.todo, .todo): true
        default: a == b
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        if flags.contains(.command), flags.contains(.control), !flags.contains(.option), !flags.contains(.shift) {
            if event.keyCode == 126 { moveBlockUp(nil); return }
            if event.keyCode == 125 { moveBlockDown(nil); return }
        }
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        if (string as? String) == " " { convertCheckboxShortcut() }
        guard (string as? String) == "/" else { return }
        let line = currentLine()
        if line.index > 0, nsString.substring(with: line.range) == "/" {
            let lineStart = line.range.location
            DispatchQueue.main.async { [weak self] in self?.showSlashMenu(lineStart: lineStart) }
        }
    }

    /// Typing "[] " or "[ ] " at the start of a line turns it into a to-do.
    private func convertCheckboxShortcut() {
        let line = currentLine()
        guard line.index > 0 else { return }
        let text = nsString.substring(with: line.range)
        let indent = String(text.prefix(while: { $0 == " " || $0 == "\t" }))
        let rest = text.dropFirst(indent.count)
        for shortcut in ["[] ", "[ ] "] where rest.hasPrefix(shortcut) {
            let range = NSRange(location: line.range.location + indent.utf16.count, length: shortcut.utf16.count)
            replace(range, with: "- [ ] ", caret: range.location + 6 + (selectedRange().location - NSMaxRange(range)))
            return
        }
    }

    // MARK: Slash menu

    private static let slashItems: [(String, String)] = [
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

    private func showSlashMenu(lineStart: Int) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, item) in Self.slashItems.enumerated() {
            let menuItem = NSMenuItem(title: item.0, action: #selector(applySlashItem(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = index
            menuItem.representedObject = lineStart
            menu.addItem(menuItem)
        }
        var point = NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y)
        if let rect = rectForLine(at: lineStart) {
            point = NSPoint(x: rect.minX, y: rect.maxY + 4)
        }
        _ = menu.popUp(positioning: menu.items.first, at: point, in: self)
    }

    @objc private func applySlashItem(_ sender: NSMenuItem) {
        guard let lineStart = sender.representedObject as? Int, lineStart < nsString.length,
              nsString.substring(with: NSRange(location: lineStart, length: 1)) == "/" else { return }
        let prefix = Self.slashItems[sender.tag].1
        if prefix == "---" {
            replace(NSRange(location: lineStart, length: 1), with: "---\n", caret: lineStart + 4)
        } else {
            replace(NSRange(location: lineStart, length: 1), with: prefix, caret: lineStart + (prefix as NSString).length)
        }
    }

    // MARK: Format commands

    @objc func toggleBoldMarkdown(_ sender: Any?) { toggleWrap("**") }
    @objc func toggleItalicMarkdown(_ sender: Any?) { toggleWrap("*") }
    @objc func toggleCodeMarkdown(_ sender: Any?) { toggleWrap("`") }
    @objc func toggleStrikeMarkdown(_ sender: Any?) { toggleWrap("~~") }
    /// ⇧⌘H: yellow highlight on, or off if the selection is already highlighted.
    @objc func toggleHighlightMarkdown(_ sender: Any?) {
        applyHighlight(currentHighlight == nil ? .yellow : nil)
    }

    /// From the toolbar's color menu; an item without a color removes the highlight.
    @objc func setHighlightColor(_ sender: NSMenuItem) {
        applyHighlight((sender.representedObject as? String).flatMap(HighlightColor.init(rawValue:)))
    }

    func applyHighlight(_ color: HighlightColor?) {
        guard let storage = textStorage else { return }
        let selection = HighlightColor.trimmedSelection(selectedRange(), in: storage)
        guard let edit = HighlightColor.edit(in: nsString, selection: selection, color: color) else { return }
        replace(edit.range, with: edit.replacement)
        setSelectedRange(edit.selection)
        dismissFormatToolbar()
    }

    var currentHighlight: HighlightColor? {
        guard let storage = textStorage else { return nil }
        return HighlightColor.current(in: nsString, selection: HighlightColor.trimmedSelection(selectedRange(), in: storage))
    }

    private func isHidden(_ index: Int) -> Bool {
        guard index >= 0, index < nsString.length else { return false }
        return textStorage?.attribute(.paperHidden, at: index, effectiveRange: nil) != nil
    }

    /// Whether `run` ends (or starts) with `marker`, without mistaking `**` for `*`.
    private func syntaxRun(_ text: String, hasMarker marker: String, atEnd: Bool) -> Bool {
        guard marker == "*" else { return atEnd ? text.hasSuffix(marker) : text.hasPrefix(marker) }
        let stars = atEnd ? text.reversed().prefix(while: { $0 == "*" }).count : text.prefix(while: { $0 == "*" }).count
        return stars == 1 || stars == 3
    }

    /// Adds or removes `marker` around the selection. Hidden syntax at the selection's edges is
    /// ignored, and existing markers next to it are removed instead of stacked.
    private func toggleWrap(_ marker: String) {
        let ns = nsString
        let m = (marker as NSString).length
        var sel = selectedRange()
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
            let outer = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            replace(outer, with: inner)
            setSelectedRange(NSRange(location: sel.location - m, length: sel.length))
            dismissFormatToolbar()
            return
        }
        if sel.length > 0, leftRun != marker, syntaxRun(leftRun, hasMarker: marker, atEnd: false),
           syntaxRun(rightRun, hasMarker: marker, atEnd: true) {
            let span = NSRange(location: left, length: right - left)
            let newLeft = String(leftRun.dropFirst(marker.count))
            let newRight = String(rightRun.dropLast(marker.count))
            replace(span, with: newLeft + inner + newRight)
            setSelectedRange(NSRange(location: left + (newLeft as NSString).length, length: sel.length))
            dismissFormatToolbar()
            return
        }

        replace(sel, with: marker + inner + marker)
        setSelectedRange(NSRange(location: sel.location + m, length: sel.length))
        dismissFormatToolbar()
    }

    private func dismissFormatToolbar() {
        dismissedSelection = selectedRange()
        formatToolbar.isHidden = true
    }

    @objc func setLineText(_ sender: Any?) { setLinePrefix("") }
    @objc func setLineHeading1(_ sender: Any?) { setLinePrefix("# ") }
    @objc func setLineHeading2(_ sender: Any?) { setLinePrefix("## ") }
    @objc func setLineHeading3(_ sender: Any?) { setLinePrefix("### ") }
    @objc func setLineBullet(_ sender: Any?) { setLinePrefix("- ") }
    @objc func setLineNumbered(_ sender: Any?) { setLinePrefix("1. ") }
    @objc func setLineTodo(_ sender: Any?) { setLinePrefix("- [ ] ") }
    @objc func setLineQuote(_ sender: Any?) { setLinePrefix("> ") }
    @objc func setLineCallout(_ sender: Any?) { setLinePrefix("! ") }

    private func setLinePrefix(_ prefix: String) {
        let line = currentLine()
        guard line.index > 0 else { return }
        let offset = selectedRange().location - line.range.location - line.info.markerLength
        let markerRange = NSRange(location: line.range.location,
                                  length: line.info.kind == .divider ? line.range.length : line.info.markerLength)
        let caret = line.range.location + (prefix as NSString).length + max(offset, 0)
        replace(markerRange, with: prefix, caret: caret)
    }

    // MARK: Moving blocks

    @objc func moveBlockUp(_ sender: Any?) {
        let ranges = lineRanges()
        let index = lineIndex(at: selectedRange().location, in: ranges)
        guard index > 0 else { return }
        moveLine(from: index, toBoundary: index - 1, ranges: ranges)
    }

    @objc func moveBlockDown(_ sender: Any?) {
        let ranges = lineRanges()
        let index = lineIndex(at: selectedRange().location, in: ranges)
        guard index < ranges.count - 1 else { return }
        moveLine(from: index, toBoundary: index + 2, ranges: ranges)
    }

    /// Moves line `source` so it sits before the line currently at `boundary` (0...count).
    private func moveLine(from source: Int, toBoundary boundary: Int, ranges: [NSRange]) {
        guard boundary != source, boundary != source + 1 else { return }
        let ns = nsString
        var lines = ranges.map { ns.substring(with: $0) }
        let caretOffset = max(0, min(selectedRange().location - ranges[source].location, ranges[source].length))
        let moved = lines.remove(at: source)
        let target = boundary > source ? boundary - 1 : boundary
        lines.insert(moved, at: target)

        let low = min(source, target)
        let high = max(source, target)
        let span = NSRange(location: ranges[low].location,
                           length: NSMaxRange(ranges[high]) - ranges[low].location)
        let replacement = lines[low...high].joined(separator: "\n")
        let newStart = span.location + lines[low..<target].reduce(0) { $0 + ($1 as NSString).length + 1 }
        replace(span, with: replacement, caret: newStart + caretOffset)
        scrollRangeToVisible(selectedRange())
    }

    // MARK: Geometry

    struct LineGeometry {
        /// The whole paragraph, including spacing around it.
        var fragment: NSRect
        /// The text area, without paragraph spacing.
        var content: NSRect
        /// The first visual line of the text area.
        var firstLine: NSRect
    }

    func geometry(forLineAt location: Int) -> LineGeometry? {
        guard let layoutManager, let textContainer else { return nil }
        let ns = nsString
        var fragments: [NSRect] = []
        if location >= ns.length {
            var rect = layoutManager.extraLineFragmentRect
            if rect.isEmpty {
                rect = NSRect(x: 0, y: 0, width: textContainer.size.width, height: MarkdownStyler.bodyLineHeight)
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
            ? textStorage?.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle
            : nil
        let before = style?.paragraphSpacingBefore ?? 0
        let lineSpacing = style?.lineSpacing ?? 0
        let after = (style?.paragraphSpacing ?? 0) + lineSpacing
        let padding = textContainer.lineFragmentPadding

        func toView(_ rect: NSRect) -> NSRect {
            NSRect(x: textContainerOrigin.x + padding, y: rect.minY + textContainerOrigin.y,
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

    func rectForLine(at location: Int) -> NSRect? {
        geometry(forLineAt: location)?.content
    }

    private func lineIndex(atPoint point: NSPoint) -> Int {
        let ranges = lineRanges()
        let location = characterIndexForInsertion(at: point)
        return lineIndex(at: min(location, nsString.length), in: ranges)
    }

    private func handleRect(forLine index: Int, ranges: [NSRange]) -> NSRect? {
        // The title is always first and has no other type, so it gets no + or drag handle.
        guard index > 0, index < ranges.count, let line = geometry(forLineAt: ranges[index].location)?.firstLine else { return nil }
        return NSRect(x: line.minX - handleWidth - 10, y: line.minY, width: handleWidth, height: max(line.height, 18))
    }

    /// The checkbox of a to-do line, in view coordinates.
    private func checkboxRect(forLine index: Int, ranges: [NSRange]) -> NSRect? {
        guard index > 0, index < ranges.count, index < lineKinds.count,
              case .todo = lineKinds[index],
              let line = geometry(forLineAt: ranges[index].location) else { return nil }
        let info = MarkdownStyler.parse(nsString.substring(with: ranges[index]), isFirst: false)
        let size = MarkdownStyler.checkboxSize
        let font = MarkdownStyler.bodyFont
        let textMid = line.firstLine.minY + MarkdownStyler.textTop(for: .body) + (font.ascender - font.descender) / 2
        let x = line.content.minX + CGFloat(info.level) * MarkdownStyler.listIndent + 2
        return NSRect(x: x, y: (textMid - size / 2).rounded(), width: size, height: size)
    }

    /// Flips "- [ ]" and "- [x]" on a to-do line.
    private func toggleTodo(line index: Int, ranges: [NSRange]) {
        let info = MarkdownStyler.parse(nsString.substring(with: ranges[index]), isFirst: false)
        guard case .todo(let checked) = info.kind else { return }
        let mark = NSRange(location: ranges[index].location + info.indent.utf16.count + 3, length: 1)
        let caret = selectedRange()
        replace(mark, with: checked ? " " : "x")
        setSelectedRange(caret)
    }

    private func plusRect(forLine index: Int, ranges: [NSRange]) -> NSRect? {
        guard let handle = handleRect(forLine: index, ranges: ranges) else { return nil }
        return NSRect(x: handle.minX - handleWidth - 2, y: handle.minY, width: handleWidth, height: handle.height)
    }

    /// Adds an empty block below `line` and opens the block menu on it.
    private func insertBlock(below line: Int, ranges: [NSRange]) {
        let location = NSMaxRange(ranges[line])
        window?.makeFirstResponder(self)
        replace(NSRange(location: location, length: 0), with: "\n/", caret: location + 2)
        let lineStart = location + 1
        DispatchQueue.main.async { [weak self] in self?.showSlashMenu(lineStart: lineStart) }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.filter { $0.owner === self && $0.userInfo?["paper"] != nil }.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: ["paper": true]))
    }

    /// Whether the pointer is over a floating control (format toolbar, go-to-bottom chip), where the
    /// text view must not force its I-beam cursor.
    private func isOverToolbar(_ event: NSEvent) -> Bool {
        if !formatToolbar.isHidden, formatToolbar.superview === self,
           formatToolbar.frame.contains(convert(event.locationInWindow, from: nil)) {
            return true
        }
        var view = window?.contentView?.hitTest(event.locationInWindow)
        while let current = view {
            if current is ScrollToBottomChip { return true }
            view = current.superview
        }
        return false
    }

    override func cursorUpdate(with event: NSEvent) {
        if isOverToolbar(event) {
            NSCursor.pointingHand.set()
            return
        }
        if let control = blockControl(at: event) {
            (control == .plus ? NSCursor.pointingHand : NSCursor.openHand).set()
            return
        }
        super.cursorUpdate(with: event)
    }

    /// The + or drag handle of the hovered line under the pointer, if any.
    private func blockControl(at event: NSEvent) -> BlockControl? {
        guard !isDraggingBlock, let line = hoveredLine else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let ranges = lineRanges()
        if let plus = plusRect(forLine: line, ranges: ranges), plus.insetBy(dx: -2, dy: -2).contains(point) { return .plus }
        if let handle = handleRect(forLine: line, ranges: ranges), handle.insetBy(dx: -2, dy: -2).contains(point) { return .handle }
        return nil
    }

    private func isOverCheckbox(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        let ranges = lineRanges()
        guard let box = checkboxRect(forLine: lineIndex(atPoint: point), ranges: ranges) else { return false }
        return box.insetBy(dx: -4, dy: -4).contains(point)
    }

    override func mouseMoved(with event: NSEvent) {
        if isOverToolbar(event) || isOverCheckbox(event) {
            NSCursor.pointingHand.set()
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let line = lineIndex(atPoint: point)
        if line != hoveredLine {
            hoveredLine = line
            needsDisplay = true
        }
        let control = blockControl(at: event)
        if control != hoveredControl {
            hoveredControl = control
            toolTip = control == .plus ? "Add a block below" : control == .handle ? "Drag to move" : nil
            needsDisplay = true
        }
        if let control {
            // Show that the + is clickable and the handle can be grabbed.
            (control == .plus ? NSCursor.pointingHand : NSCursor.openHand).set()
            return
        }
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredLine = nil
        hoveredControl = nil
        toolTip = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if point.y < textContainerOrigin.y - 8 {
            window?.performDrag(with: event)
            return
        }

        let ranges = lineRanges()
        let line = lineIndex(atPoint: point)
        if let box = checkboxRect(forLine: line, ranges: ranges)?.insetBy(dx: -4, dy: -4), box.contains(point) {
            toggleTodo(line: line, ranges: ranges)
            return
        }
        if let plus = plusRect(forLine: line, ranges: ranges)?.insetBy(dx: -2, dy: -2), plus.contains(point) {
            insertBlock(below: line, ranges: ranges)
            return
        }
        if let handle = handleRect(forLine: line, ranges: ranges)?.insetBy(dx: -2, dy: -2), handle.contains(point) {
            dragBlock(from: line, ranges: ranges)
            return
        }
        super.mouseDown(with: event)
    }

    private func dragBlock(from source: Int, ranges: [NSRange]) {
        isDraggingBlock = true
        NSCursor.closedHand.push()
        var boundary: Int?

        while let event = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if event.type == .leftMouseUp { break }
            autoscroll(with: event)
            let point = convert(event.locationInWindow, from: nil)
            let line = lineIndex(atPoint: point)
            guard let rect = rectForLine(at: ranges[line].location) else { continue }
            let below = point.y > rect.midY
            boundary = below ? line + 1 : line
            dropIndicatorY = below ? rect.maxY : rect.minY
            needsDisplay = true
        }

        NSCursor.pop()
        isDraggingBlock = false
        dropIndicatorY = nil
        needsDisplay = true
        if let boundary {
            moveLine(from: source, toBoundary: boundary, ranges: ranges)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if let items = paperMenuItems?(), !items.isEmpty {
            menu.insertItem(.separator(), at: 0)
            for item in items.reversed() {
                menu.insertItem(item, at: 0)
            }
        }
        return menu
    }

    // MARK: Drawing

    /// Lines that intersect `rect`, so drawing skips everything off screen.
    private func visibleLines(in rect: NSRect, ranges: [NSRange]) -> ClosedRange<Int> {
        guard let layoutManager, let textContainer, !ranges.isEmpty else { return 0...max(ranges.count - 1, 0) }
        let containerRect = rect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphs = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        let chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let first = lineIndex(at: chars.location, in: ranges)
        let last = lineIndex(at: NSMaxRange(chars), in: ranges)
        return first...max(first, last)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let ranges = lineRanges()

        let visible = visibleLines(in: rect, ranges: ranges)
        var listCounts: [Int] = []
        for (index, kind) in lineKinds.enumerated() where index < ranges.count {
            // Numbering counts every line above, visible or not.
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
            guard visible.contains(index), kind != .body, kind != .title,
                  let line = geometry(forLineAt: ranges[index].location) else { continue }
            let content = line.content
            switch kind {
            case .divider:
                // Full-bleed: edge to edge of the paper, not just the text column.
                let y = content.midY.rounded()
                NSColor(red: 0xCA / 255, green: 0xD5 / 255, blue: 0xDA / 255, alpha: 1).setFill()
                NSRect(x: bounds.minX, y: y, width: bounds.width, height: 1).fill()
            case .callout:
                let box = NSRect(x: content.minX, y: content.minY - 8, width: content.width, height: content.height + 16)
                NSColor.black.withAlphaComponent(0.04).setFill()
                NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
                ("\u{1F4A1}" as NSString).draw(at: NSPoint(x: content.minX + 12,
                                                         y: line.firstLine.minY + MarkdownStyler.textTop(for: .callout)),
                                                withAttributes: [.font: MarkdownStyler.bodyFont])
            case .quote:
                let bar = NSRect(x: content.minX + 2, y: content.minY + 1, width: 3, height: max(content.height - 2, 0))
                NSColor.black.withAlphaComponent(0.85).setFill()
                bar.fill()
            case .bullet:
                let info = MarkdownStyler.parse(nsString.substring(with: ranges[index]), isFirst: false)
                let x = content.minX + CGFloat(info.level) * MarkdownStyler.listIndent + 7
                let y = line.firstLine.minY + MarkdownStyler.textTop(for: .bullet)
                ("\u{2022}" as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                    .font: MarkdownStyler.bodyFont,
                    .foregroundColor: MarkdownStyler.textColor,
                ])
            case .todo(let checked):
                if let box = checkboxRect(forLine: index, ranges: ranges) {
                    let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: 4, yRadius: 4)
                    if checked {
                        NSColor.black.withAlphaComponent(0.8).setFill()
                        path.fill()
                        let tick = NSBezierPath()
                        tick.move(to: NSPoint(x: box.minX + box.width * 0.27, y: box.minY + box.height * 0.52))
                        tick.line(to: NSPoint(x: box.minX + box.width * 0.44, y: box.minY + box.height * 0.69))
                        tick.line(to: NSPoint(x: box.minX + box.width * 0.75, y: box.minY + box.height * 0.33))
                        tick.lineWidth = 1.8
                        tick.lineCapStyle = .round
                        tick.lineJoinStyle = .round
                        NSColor.white.setStroke()
                        tick.stroke()
                    } else {
                        path.lineWidth = 1.5
                        NSColor.black.withAlphaComponent(0.55).setStroke()
                        path.stroke()
                    }
                }
            case .numbered:
                // Numbered by position (1, 2, 3…), whatever digits were typed; nested lists count separately.
                let level = numberLevel
                let label = "\(number)." as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: MarkdownStyler.bodyFont,
                    .foregroundColor: MarkdownStyler.textColor,
                ]
                let width = label.size(withAttributes: attributes).width
                let right = content.minX + CGFloat(level) * MarkdownStyler.listIndent + MarkdownStyler.numberIndent - 6
                let y = line.firstLine.minY + MarkdownStyler.textTop(for: .numbered(1))
                label.draw(at: NSPoint(x: right - width, y: y), withAttributes: attributes)
            default:
                break
            }
        }

        drawPlaceholders(ranges: ranges, visible: visible)
        drawBlockControls(ranges: ranges)
    }

    private func drawPlaceholders(ranges: [NSRange], visible: ClosedRange<Int>) {
        let isFocused = window?.firstResponder === self && selectedRange().length == 0
        let caretLine = lineIndex(at: selectedRange().location, in: ranges)

        for index in visible where index < ranges.count {
            let range = ranges[index]
            let info = MarkdownStyler.parse(nsString.substring(with: range), isFirst: index == 0)
            guard range.length == info.markerLength else { continue }

            let text: String
            if index == 0 {
                text = "Untitled"
            } else if let placeholder = info.kind.placeholder, info.markerLength > 0 {
                text = placeholder
            } else if info.kind == .body, isFocused, index == caretLine {
                text = "Type / for commands"
            } else {
                continue
            }

            guard let line = geometry(forLineAt: range.location) else { continue }
            let style = range.location < nsString.length
                ? textStorage?.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
                : nil
            let x = line.content.minX + max(style?.firstLineHeadIndent ?? 0, style?.headIndent ?? 0)
            let y = line.firstLine.minY + MarkdownStyler.textTop(for: info.kind)
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                .font: MarkdownStyler.font(for: info.kind),
                .foregroundColor: MarkdownStyler.placeholderColor,
            ])
        }
    }

    /// The drop line and the hovered line's + and drag handle. Drawn with the background (they sit
    /// in the margin or between lines, never over text): drawing them in draw(_:) didn't show up.
    private func drawBlockControls(ranges: [NSRange]) {
        if let y = dropIndicatorY {
            let x = textContainerOrigin.x
            let width = (textContainer?.size.width ?? bounds.width)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y - 1, width: width, height: 2), xRadius: 1, yRadius: 1).fill()
        }

        if !isDraggingBlock, let line = hoveredLine, let plus = plusRect(forLine: line, ranges: ranges) {
            drawControlBackground(plus, isHovered: hoveredControl == .plus)
            NSColor.black.withAlphaComponent(hoveredControl == .plus ? 0.7 : 0.45).setFill()
            let arm: CGFloat = 5
            NSBezierPath(roundedRect: NSRect(x: plus.midX - arm, y: plus.midY - 0.75, width: arm * 2, height: 1.5),
                         xRadius: 0.75, yRadius: 0.75).fill()
            NSBezierPath(roundedRect: NSRect(x: plus.midX - 0.75, y: plus.midY - arm, width: 1.5, height: arm * 2),
                         xRadius: 0.75, yRadius: 0.75).fill()
        }

        if !isDraggingBlock, let line = hoveredLine, let handle = handleRect(forLine: line, ranges: ranges) {
            drawControlBackground(handle, isHovered: hoveredControl == .handle)
            NSColor.black.withAlphaComponent(hoveredControl == .handle ? 0.7 : 0.45).setFill()
            let dot: CGFloat = 3
            let gap: CGFloat = 4
            let startX = handle.midX - (dot * 2 + gap) / 2
            let startY = handle.midY - (dot * 3 + gap * 2) / 2
            for row in 0..<3 {
                for col in 0..<2 {
                    let r = NSRect(x: startX + CGFloat(col) * (dot + gap),
                                   y: startY + CGFloat(row) * (dot + gap), width: dot, height: dot)
                    NSBezierPath(ovalIn: r).fill()
                }
            }
        }
    }

    /// Soft rounded background behind the + or handle under the pointer, like a hovered button.
    private func drawControlBackground(_ rect: NSRect, isHovered: Bool) {
        guard isHovered else { return }
        let box = NSRect(x: rect.minX - 1, y: rect.midY - 12, width: rect.width + 2, height: 24)
        NSColor.black.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
    }

    /// The line box includes extra line spacing below the text; keep the caret to the font's height.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var rect = rect
        let kind = currentLine().info.kind
        let font = MarkdownStyler.font(for: kind)
        let height = ceil(font.ascender - font.descender)
        if rect.height > height {
            // Match the caret to where the text sits in its line box.
            rect.origin.y += MarkdownStyler.textTop(for: kind).rounded()
            rect.size.height = height
        }
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        var ranges = ranges
        if !stillSelecting, ranges.count == 1, let range = ranges.first?.rangeValue, range.length == 0 {
            let snapped = snappedCaret(range.location, from: selectedRange().location)
            if snapped != range.location {
                ranges = [NSValue(range: NSRange(location: snapped, length: 0))]
            }
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        let lines = lineRanges()
        if (textStorage?.length ?? 0) == 0 || (lines.count == 2 && lines[1].length == 0) {
            updateTypingAttributes()
            if let length = textStorage?.length {
                layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: length),
                                                actualCharacterRange: nil)
            }
        }
        needsDisplay = true
        if stillSelecting {
            formatToolbar.isHidden = true
        } else {
            DispatchQueue.main.async { [weak self] in self?.updateFormatToolbar() }
        }
    }

    override func resignFirstResponder() -> Bool {
        formatToolbar.isHidden = true
        return super.resignFirstResponder()
    }

    // MARK: Format toolbar

    /// Label for the block type at the caret, shown on the toolbar's "Turn into" button.
    func currentBlockLabel() -> String {
        let line = currentLine()
        switch line.info.kind {
        case .title: return "Title"
        case .heading(1): return "Heading 1"
        case .heading(2): return "Heading 2"
        case .heading: return "Heading 3"
        case .bullet: return "Bullet list"
        case .numbered: return "Numbered list"
        case .todo: return "To-do list"
        case .quote: return "Quote"
        case .callout: return "Callout"
        case .divider: return "Divider"
        case .body: return "Text"
        }
    }

    var caretIsOnTitle: Bool { currentLine().index == 0 }

    private func updateFormatToolbar() {
        let selection = selectedRange()
        if let dismissed = dismissedSelection {
            if dismissed == selection {
                formatToolbar.isHidden = true
                return
            }
            dismissedSelection = nil
        }
        // The title has a fixed style, so selecting it never offers formatting.
        guard selection.length > 0, !caretIsOnTitle, window?.firstResponder === self,
              let layoutManager, let textContainer else {
            formatToolbar.isHidden = true
            return
        }
        if formatToolbar.superview !== self { addSubview(formatToolbar) }
        formatToolbar.refresh()

        let glyphs = layoutManager.glyphRange(forCharacterRange: selection, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y

        let size = formatToolbar.fittingSize
        let gap: CGFloat = 8
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - gap)
        if origin.y < visibleRect.minY + 4 {
            origin.y = rect.maxY + gap
        }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        formatToolbar.frame = NSRect(origin: origin, size: size)
        formatToolbar.isHidden = false
    }
}

/// Borderless toolbar button with a pointer cursor and a soft background on hover.
final class ToolbarButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private let hoverLayer = CALayer()

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    /// Clicks on the label or chevron inside the button count as clicks on the button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return super.hitTest(point) }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseEntered(with event: NSEvent) { setHovered(isEnabled) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func layout() {
        super.layout()
        hoverLayer.frame = bounds.insetBy(dx: 2, dy: 2)
    }

    /// Soft background inset 2pt inside the button, so neighbouring hovers never touch.
    private func setHovered(_ hovered: Bool) {
        wantsLayer = true
        if hoverLayer.superlayer == nil, let layer {
            hoverLayer.cornerRadius = 6
            hoverLayer.frame = bounds.insetBy(dx: 2, dy: 2)
            layer.insertSublayer(hoverLayer, at: 0)
        }
        hoverLayer.backgroundColor = hovered ? NSColor.black.withAlphaComponent(0.06).cgColor : NSColor.clear.cgColor
    }
}

/// Floating bar shown above selected text: turn the block into another type, or style the text.
final class FormatToolbar: NSView {
    private weak var textView: PaperTextView?
    private let turnIntoButton = ToolbarButton(title: "", target: nil, action: nil)
    private let turnIntoLabel = NSTextField(labelWithString: "Text")
    private let stack = NSStackView()
    private var highlightButton: NSButton?

    private static let blockTypes: [(String, Selector)] = [
        ("Text", #selector(PaperTextView.setLineText(_:))),
        ("Heading 1", #selector(PaperTextView.setLineHeading1(_:))),
        ("Heading 2", #selector(PaperTextView.setLineHeading2(_:))),
        ("Heading 3", #selector(PaperTextView.setLineHeading3(_:))),
        ("Bullet list", #selector(PaperTextView.setLineBullet(_:))),
        ("Numbered list", #selector(PaperTextView.setLineNumbered(_:))),
        ("To-do list", #selector(PaperTextView.setLineTodo(_:))),
        ("Quote", #selector(PaperTextView.setLineQuote(_:))),
        ("Callout", #selector(PaperTextView.setLineCallout(_:))),
    ]

    init(textView: PaperTextView) {
        self.textView = textView
        super.init(frame: .zero)
        isHidden = true
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.1).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false

        // Label on the left, chevron on the right, like a pop-up button.
        turnIntoButton.title = ""
        turnIntoButton.isBordered = false
        turnIntoButton.refusesFirstResponder = true
        turnIntoButton.target = self
        turnIntoButton.action = #selector(showTurnIntoMenu)
        turnIntoButton.toolTip = "Turn into"
        turnIntoLabel.font = .systemFont(ofSize: 14, weight: .medium)
        turnIntoLabel.textColor = NSColor.black.withAlphaComponent(0.8)
        turnIntoLabel.translatesAutoresizingMaskIntoConstraints = false
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) ?? NSImage())
        chevron.contentTintColor = NSColor.black.withAlphaComponent(0.6)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        turnIntoButton.addSubview(turnIntoLabel)
        turnIntoButton.addSubview(chevron)
        NSLayoutConstraint.activate([
            turnIntoButton.heightAnchor.constraint(equalToConstant: 32),
            turnIntoButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 128),
            turnIntoLabel.leadingAnchor.constraint(equalTo: turnIntoButton.leadingAnchor, constant: 10),
            turnIntoLabel.centerYAnchor.constraint(equalTo: turnIntoButton.centerYAnchor),
            chevron.trailingAnchor.constraint(equalTo: turnIntoButton.trailingAnchor, constant: -10),
            chevron.centerYAnchor.constraint(equalTo: turnIntoButton.centerYAnchor),
            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: turnIntoLabel.trailingAnchor, constant: 8),
        ])

        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(turnIntoButton)
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(iconButton("bold", "Bold  ⌘B", #selector(PaperTextView.toggleBoldMarkdown(_:))))
        stack.addArrangedSubview(iconButton("italic", "Italic  ⌘I", #selector(PaperTextView.toggleItalicMarkdown(_:))))
        stack.addArrangedSubview(iconButton("strikethrough", "Strikethrough  ⇧⌘X",
                                            #selector(PaperTextView.toggleStrikeMarkdown(_:))))
        stack.addArrangedSubview(iconButton("chevron.left.forwardslash.chevron.right", "Inline code  ⌘E",
                                            #selector(PaperTextView.toggleCodeMarkdown(_:))))
        highlightButton = iconButton("highlighter", "Highlight color", #selector(showHighlightMenu))
        highlightButton?.target = self
        if let highlightButton { stack.addArrangedSubview(highlightButton) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var mouseDownCanMoveWindow: Bool { false }

    func refresh() {
        guard let textView else { return }
        turnIntoLabel.stringValue = textView.currentBlockLabel()
        turnIntoButton.isEnabled = !textView.caretIsOnTitle
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) ?? NSImage()
        let button = ToolbarButton(image: image, target: textView, action: action)
        button.isBordered = false
        button.contentTintColor = NSColor.black.withAlphaComponent(0.75)
        button.toolTip = tip
        button.refusesFirstResponder = true
        button.widthAnchor.constraint(equalToConstant: 32).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func separator() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.1).cgColor
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        line.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return line
    }

    /// A row of color dots (the current one ringed), plus a "no highlight" dot when there is one.
    @objc private func showHighlightMenu() {
        guard let textView, let highlightButton else { return }
        let menu = NSMenu()
        let item = NSMenuItem()
        item.view = HighlightPalette(current: textView.currentHighlight) { [weak menu, weak textView] color in
            menu?.cancelTracking()
            textView?.applyHighlight(color)
        }
        menu.addItem(item)
        _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: highlightButton.bounds.maxY + 4), in: highlightButton)
    }

    @objc private func showTurnIntoMenu() {
        guard let textView else { return }
        let current = textView.currentBlockLabel()
        let menu = NSMenu()
        for (title, action) in Self.blockTypes {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = textView
            item.state = title == current ? .on : .off
            menu.addItem(item)
        }
        _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: turnIntoButton.bounds.maxY + 4), in: turnIntoButton)
    }
}
/// Color dots for the highlight menu. Each dot shows the color as it looks on the paper.
final class HighlightPalette: NSView {
    private let onPick: (HighlightColor?) -> Void
    private let choices: [HighlightColor?]
    private static let dotSize: CGFloat = 28

    init(current: HighlightColor?, onPick: @escaping (HighlightColor?) -> Void) {
        self.onPick = onPick
        let removeChoice: [HighlightColor?] = current == nil ? [] : [nil]
        choices = HighlightColor.allCases.map { Optional($0) } + removeChoice
        let padding: CGFloat = 10
        super.init(frame: NSRect(x: 0, y: 0, width: padding * 2 + CGFloat(choices.count) * Self.dotSize,
                                 height: Self.dotSize + 12))
        for (index, choice) in choices.enumerated() {
            let button = NSButton(image: Self.dot(choice, selected: choice != nil && choice == current),
                                  target: self, action: #selector(pick(_:)))
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.tag = index
            button.frame = NSRect(x: padding + CGFloat(index) * Self.dotSize, y: 6, width: Self.dotSize, height: Self.dotSize)
            button.toolTip = choice?.label ?? "Remove highlight"
            button.setAccessibilityLabel(choice.map { "\($0.label) highlight" } ?? "Remove highlight")
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func pick(_ sender: NSButton) {
        onPick(choices[sender.tag])
    }

    /// A filled dot in the highlight color (ringed when it's the current one), or a slashed dot for "none".
    private static func dot(_ color: HighlightColor?, selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: dotSize, height: dotSize), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 6, dy: 6))
            NSColor.white.setFill()
            circle.fill()
            if let color {
                color.color.setFill()
                circle.fill()
            }
            NSColor.black.withAlphaComponent(0.18).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            if color == nil {
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: rect.minX + 9, y: rect.minY + 9))
                slash.line(to: NSPoint(x: rect.maxX - 9, y: rect.maxY - 9))
                slash.lineWidth = 1.5
                NSColor.black.withAlphaComponent(0.5).setStroke()
                slash.stroke()
            }
            if selected {
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5))
                ring.lineWidth = 1.5
                NSColor.black.withAlphaComponent(0.65).setStroke()
                ring.stroke()
            }
            return true
        }
    }
}
#endif
