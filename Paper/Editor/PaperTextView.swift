#if os(macOS)
import AppKit

final class PaperTextView: NSTextView {
    private(set) var lineKinds: [LineKind] = []
    private var hiddenRanges: [HiddenRange] = []
    private lazy var formatToolbar = FormatToolbar(textView: self)
    /// Dotted and ruled paper snap text to the grid; plain paper uses reading spacing.
    var paperStyle: PaperStyle = .dotted {
        didSet { if paperStyle != oldValue { restyle() } }
    }
    var isGrid: Bool { paperStyle != .plain }
    /// Selection left by a style action; the toolbar stays closed until the selection changes.
    private var dismissedSelection: NSRange?
    private var hoveredLine: Int?
    private var dropIndicatorY: CGFloat?
    private var isDraggingBlock = false
    var paperMenuItems: (() -> [NSMenuItem])?

    private let handleWidth: CGFloat = 18

    // MARK: Lines

    var nsString: NSString { string as NSString }

    /// Content range of every line, excluding the newline.
    func lineRanges() -> [NSRange] {
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
        let result = MarkdownStyler.style(storage, grid: isGrid)
        lineKinds = result.kinds
        hiddenRanges = result.hidden
        let full = NSRange(location: 0, length: storage.length)
        layoutManager?.invalidateGlyphs(forCharacterRange: full, changeInLength: 0, actualCharacterRange: nil)
        layoutManager?.invalidateLayout(forCharacterRange: full, actualCharacterRange: nil)
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
            attributes = MarkdownStyler.attributes(for: .title, grid: isGrid)
        } else if ranges.count == 2, ranges[1].length == 0 {
            attributes = MarkdownStyler.attributes(for: .body, grid: isGrid)
            if let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
                style.paragraphSpacingBefore = isGrid ? MarkdownStyler.gridUnit : MarkdownStyler.titleGap
                attributes[.paragraphStyle] = style
            }
        } else {
            attributes = MarkdownStyler.attributes(for: .body, grid: isGrid)
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
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
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
            guard [.bullet, .numbered(0)].contains(where: { sameKind($0, line.info.kind) }) else { return false }
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
        case (.numbered, .numbered): true
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
        guard (string as? String) == "/" else { return }
        let line = currentLine()
        if line.index > 0, nsString.substring(with: line.range) == "/" {
            let lineStart = line.range.location
            DispatchQueue.main.async { [weak self] in self?.showSlashMenu(lineStart: lineStart) }
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
    @objc func toggleHighlightMarkdown(_ sender: Any?) { toggleWrap("==") }

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

    private func isOverToolbar(_ event: NSEvent) -> Bool {
        guard !formatToolbar.isHidden, formatToolbar.superview === self else { return false }
        return formatToolbar.frame.contains(convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        if isOverToolbar(event) {
            NSCursor.pointingHand.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if isOverToolbar(event) {
            NSCursor.pointingHand.set()
            return
        }
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let line = lineIndex(atPoint: point)
        if line != hoveredLine {
            hoveredLine = line
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredLine = nil
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

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let ranges = lineRanges()

        var listCounts: [Int] = []
        for (index, kind) in lineKinds.enumerated() where index < ranges.count {
            if case .numbered = kind {} else { listCounts.removeAll() }
            guard kind != .body, kind != .title, let line = geometry(forLineAt: ranges[index].location) else { continue }
            let content = line.content
            switch kind {
            case .divider:
                // Full-bleed: edge to edge of the paper, not just the text column.
                let y = content.midY.rounded()
                NSColor(red: 0xCA / 255, green: 0xD5 / 255, blue: 0xDA / 255, alpha: 1).setFill()
                NSRect(x: bounds.minX, y: y - 0.75, width: bounds.width, height: 1.5).fill()
            case .callout:
                let box = NSRect(x: content.minX, y: content.minY - 8, width: content.width, height: content.height + 16)
                NSColor.black.withAlphaComponent(0.04).setFill()
                NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
                ("\u{1F4A1}" as NSString).draw(at: NSPoint(x: content.minX + 12,
                                                         y: line.firstLine.minY + MarkdownStyler.textTop(for: .callout, grid: isGrid)),
                                                withAttributes: [.font: MarkdownStyler.bodyFont])
            case .quote:
                let bar = NSRect(x: content.minX + 2, y: content.minY + 1, width: 3, height: max(content.height - 2, 0))
                NSColor.black.withAlphaComponent(0.85).setFill()
                bar.fill()
            case .bullet:
                let info = MarkdownStyler.parse(nsString.substring(with: ranges[index]), isFirst: false)
                let x = content.minX + CGFloat(info.level) * MarkdownStyler.listIndent + 7
                let y = line.firstLine.minY + MarkdownStyler.textTop(for: .bullet, grid: isGrid)
                ("\u{2022}" as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                    .font: MarkdownStyler.bodyFont,
                    .foregroundColor: MarkdownStyler.textColor,
                ])
            case .numbered:
                // Numbered by position (1, 2, 3…), whatever digits were typed; nested lists count separately.
                let info = MarkdownStyler.parse(nsString.substring(with: ranges[index]), isFirst: false)
                let level = info.level
                if listCounts.count > level + 1 { listCounts.removeLast(listCounts.count - level - 1) }
                while listCounts.count < level + 1 { listCounts.append(0) }
                listCounts[level] += 1
                let label = "\(listCounts[level])." as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: MarkdownStyler.bodyFont,
                    .foregroundColor: MarkdownStyler.textColor,
                ]
                let width = label.size(withAttributes: attributes).width
                let right = content.minX + CGFloat(level) * MarkdownStyler.listIndent + MarkdownStyler.numberIndent - 6
                let y = line.firstLine.minY + MarkdownStyler.textTop(for: .numbered(1), grid: isGrid)
                label.draw(at: NSPoint(x: right - width, y: y), withAttributes: attributes)
            default:
                break
            }
        }

        drawPlaceholders(ranges: ranges)
    }

    private func drawPlaceholders(ranges: [NSRange]) {
        let isFocused = window?.firstResponder === self && selectedRange().length == 0
        let caretLine = lineIndex(at: selectedRange().location, in: ranges)

        for (index, range) in ranges.enumerated() {
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
            let y = line.firstLine.minY + MarkdownStyler.textTop(for: info.kind, grid: isGrid)
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                .font: MarkdownStyler.font(for: info.kind),
                .foregroundColor: MarkdownStyler.placeholderColor,
            ])
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let ranges = lineRanges()

        if let y = dropIndicatorY {
            let x = textContainerOrigin.x
            let width = (textContainer?.size.width ?? bounds.width)
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: y - 1, width: width, height: 2), xRadius: 1, yRadius: 1).fill()
        }

        if !isDraggingBlock, let line = hoveredLine, let plus = plusRect(forLine: line, ranges: ranges) {
            NSColor.black.withAlphaComponent(0.3).setFill()
            let arm: CGFloat = 5
            NSBezierPath(roundedRect: NSRect(x: plus.midX - arm, y: plus.midY - 0.75, width: arm * 2, height: 1.5),
                         xRadius: 0.75, yRadius: 0.75).fill()
            NSBezierPath(roundedRect: NSRect(x: plus.midX - 0.75, y: plus.midY - arm, width: 1.5, height: arm * 2),
                         xRadius: 0.75, yRadius: 0.75).fill()
        }

        if !isDraggingBlock, let line = hoveredLine, let handle = handleRect(forLine: line, ranges: ranges) {
            NSColor.black.withAlphaComponent(0.25).setFill()
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

    /// The line box includes extra line spacing below the text; keep the caret to the font's height.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var rect = rect
        let kind = currentLine().info.kind
        let font = MarkdownStyler.font(for: kind)
        let height = ceil(font.ascender - font.descender)
        if rect.height > height {
            // Match the caret to where the text sits in its line box.
            rect.origin.y += MarkdownStyler.textTop(for: kind, grid: isGrid).rounded()
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
    private let turnIntoButton = ToolbarButton(title: "Text", target: nil, action: nil)
    private let stack = NSStackView()

    private static let blockTypes: [(String, Selector)] = [
        ("Text", #selector(PaperTextView.setLineText(_:))),
        ("Heading 1", #selector(PaperTextView.setLineHeading1(_:))),
        ("Heading 2", #selector(PaperTextView.setLineHeading2(_:))),
        ("Heading 3", #selector(PaperTextView.setLineHeading3(_:))),
        ("Bullet list", #selector(PaperTextView.setLineBullet(_:))),
        ("Numbered list", #selector(PaperTextView.setLineNumbered(_:))),
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

        turnIntoButton.isBordered = false
        turnIntoButton.font = .systemFont(ofSize: 14, weight: .medium)
        turnIntoButton.contentTintColor = NSColor.black.withAlphaComponent(0.8)
        turnIntoButton.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        turnIntoButton.imagePosition = .imageTrailing
        // Keep the chevron beside the label; the pair is centred, leaving room at both edges.
        turnIntoButton.imageHugsTitle = true
        turnIntoButton.refusesFirstResponder = true
        turnIntoButton.target = self
        turnIntoButton.action = #selector(showTurnIntoMenu)
        turnIntoButton.toolTip = "Turn into"
        turnIntoButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        turnIntoButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true

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
        stack.addArrangedSubview(iconButton("highlighter", "Highlight  ⇧⌘H",
                                            #selector(PaperTextView.toggleHighlightMarkdown(_:))))
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
        turnIntoButton.title = textView.currentBlockLabel()
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
#endif
