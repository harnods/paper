#if os(macOS)
import AppKit
import SwiftUI

/// Draws the paper: white, a fixed grain, and the dot or ruled pattern in scrolled coordinates.
final class PaperClipView: NSClipView {
    var style: PaperStyle = .dotted {
        didSet { if style != oldValue { needsDisplay = true } }
    }

    private static let dotSpacing: CGFloat = 26

    private static let grain: NSColor = {
        let size = 128
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return .clear }
        var seed: UInt32 = 0x9E3779B9
        for y in 0..<size {
            for x in 0..<size {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let v = Double(seed >> 24) / 255
                rep.setColor(NSColor(deviceWhite: v > 0.5 ? 0 : 0.55, alpha: v > 0.5 ? (v - 0.5) * 0.07 : 0),
                             atX: x, y: y)
            }
        }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return NSColor(patternImage: image)
    }()

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        Self.grain.setFill()
        dirtyRect.fill(using: .sourceOver)

        guard style == .dotted else { return }
        let spacing = Self.dotSpacing
        NSColor.black.withAlphaComponent(0.2).setFill()
        let dot: CGFloat = 2.6
        let columns = Int(bounds.width / spacing)
        var y = ((dirtyRect.minY / spacing).rounded(.down)) * spacing
        while y < dirtyRect.maxY + spacing {
            for column in 1..<max(columns, 1) {
                let x = CGFloat(column) * spacing
                NSBezierPath(ovalIn: NSRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)).fill()
            }
            y += spacing
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView = documentView as? NSTextView else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }
}

/// Round "go to bottom" button that floats over the paper while you're far from the end.
final class ScrollToBottomChip: NSView {
    static let size: CGFloat = 34
    var onClick: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.size, height: Self.size))
        wantsLayer = true
        layer?.cornerRadius = Self.size / 2
        layer?.backgroundColor = NSColor.white.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.black.withAlphaComponent(0.1).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.12
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false
        alphaValue = 0
        isHidden = true
        toolTip = "Go to bottom"
        setAccessibilityRole(.button)
        setAccessibilityLabel("Go to bottom")

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        if let symbol = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let imageView = NSImageView(image: symbol)
            imageView.contentTintColor = NSColor.black.withAlphaComponent(0.7)
            imageView.frame = bounds
            imageView.autoresizingMask = [.width, .height]
            addSubview(imageView)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }

    func setVisible(_ visible: Bool) {
        guard visible == isHidden else { return }
        if visible { isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            if !visible { self?.isHidden = true }
        })
    }
}

struct MarkdownEditor: NSViewRepresentable {
    let document: Document
    let style: PaperStyle
    let store: PaperStore
    let actions: PaperActions

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, store: store, actions: actions)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = PaperTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 800), textContainer: container)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: MarkdownStyler.pageInset, height: MarkdownStyler.pageInset)
        textView.insertionPointColor = .black
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.selectedTextAttributes = [.backgroundColor: NSColor.selectedTextBackgroundColor]
        textView.delegate = context.coordinator
        textView.paperMenuItems = { [weak coordinator = context.coordinator] in
            coordinator?.paperMenuItems() ?? []
        }

        let clipView = PaperClipView()
        clipView.style = style
        clipView.drawsBackground = false

        let scrollView = NSScrollView()
        scrollView.contentView = clipView
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = PaperLayout.cornerRadius
        scrollView.layer?.cornerCurve = .continuous
        scrollView.layer?.masksToBounds = true

        let chip = ScrollToBottomChip()
        scrollView.addSubview(chip)
        context.coordinator.attachChip(chip, to: scrollView, textView: textView)

        textView.string = document.markdown
        textView.restyle()
        textView.undoManager?.removeAllActions()

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        (scrollView.contentView as? PaperClipView)?.style = style
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let document: Document
        let store: PaperStore
        let actions: PaperActions

        private var observers: [NSObjectProtocol] = []
        private weak var chip: ScrollToBottomChip?
        private weak var scrollView: NSScrollView?
        private weak var textView: NSTextView?

        init(document: Document, store: PaperStore, actions: PaperActions) {
            self.document = document
            self.store = store
            self.actions = actions
        }

        deinit {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func attachChip(_ chip: ScrollToBottomChip, to scrollView: NSScrollView, textView: NSTextView) {
            self.chip = chip
            self.scrollView = scrollView
            self.textView = textView
            chip.onClick = { [weak self] in self?.scrollToBottom() }

            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            textView.postsFrameChangedNotifications = true
            scrollView.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            for (name, object) in [(NSView.boundsDidChangeNotification, clip as NSView),
                                   (NSView.frameDidChangeNotification, textView as NSView),
                                   (NSView.frameDidChangeNotification, scrollView as NSView)] {
                observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateChip() }
                })
            }
            DispatchQueue.main.async { [weak self] in self?.updateChip() }
        }

        /// Shows the chip when more than about a screen's third of text is below the visible area.
        private func updateChip() {
            guard let chip, let scrollView, let textView else { return }
            // Measure in the clip view (always top-down) and convert, so the chip lands at the bottom
            // whichever way the scroll view counts its coordinates.
            let clipView = scrollView.contentView
            let size = ScrollToBottomChip.size
            let visible = clipView.bounds
            let rectInClip = NSRect(x: visible.midX - size / 2, y: visible.maxY - size - 20, width: size, height: size)
            chip.frame = scrollView.convert(rectInClip, from: clipView)
            let clip = scrollView.contentView.bounds
            let remaining = textView.frame.height - clip.maxY
            chip.setVisible(remaining > max(160, clip.height / 3))
        }

        private func scrollToBottom() {
            guard let scrollView, let textView else { return }
            let clip = scrollView.contentView
            let target = NSPoint(x: 0, y: max(0, textView.frame.height - clip.bounds.height))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(target)
            }
            scrollView.reflectScrolledClipView(clip)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? PaperTextView else { return }
            textView.restyle()
            document.markdown = textView.string
        }

        func paperMenuItems() -> [NSMenuItem] {
            var items: [NSMenuItem] = []
            items.append(item("New paper", #selector(newPaper)))
            items.append(item("View all papers", #selector(viewAllPapers)))

            let styleItem = NSMenuItem(title: "Paper style", action: nil, keyEquivalent: "")
            let styleMenu = NSMenu()
            for (index, style) in PaperStyle.allCases.enumerated() {
                let entry = item(style.label, #selector(setStyle(_:)))
                entry.tag = index
                entry.state = document.paperStyle == style ? .on : .off
                styleMenu.addItem(entry)
            }
            styleItem.submenu = styleMenu
            items.append(styleItem)

            items.append(item("Delete paper", #selector(deletePaper)))
            return items
        }

        private func item(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        @objc private func newPaper() { actions.newPaper() }
        @objc private func viewAllPapers() { actions.viewAllPapers() }
        @objc private func deletePaper() { actions.delete() }
        @objc private func setStyle(_ sender: NSMenuItem) {
            store.setStyle(PaperStyle.allCases[sender.tag], for: document)
        }
    }
}
#endif
