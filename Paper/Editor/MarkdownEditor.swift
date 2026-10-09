#if os(macOS)
import AppKit
import SwiftUI

/// Draws the paper: white, a fixed grain, and the dot or ruled pattern in scrolled coordinates.
final class PaperClipView: NSClipView {
    var style: PaperStyle = .dotted {
        didSet { if style != oldValue { needsDisplay = true } }
    }

    private static let spacing: CGFloat = 26
    private static let topOffset: CGFloat = 20

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

        let spacing = Self.spacing
        let firstRow = max(0, ((dirtyRect.minY - Self.topOffset) / spacing).rounded(.down))
        var y = Self.topOffset + firstRow * spacing

        switch style {
        case .plain:
            break
        case .dotted:
            NSColor.black.withAlphaComponent(0.2).setFill()
            let dot: CGFloat = 2.6
            let columns = Int(bounds.width / spacing)
            let startX = (bounds.width - CGFloat(columns - 1) * spacing) / 2
            while y < dirtyRect.maxY + spacing {
                for column in 0..<columns {
                    let x = startX + CGFloat(column) * spacing
                    NSBezierPath(ovalIn: NSRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)).fill()
                }
                y += spacing
            }
        case .lines:
            NSColor(red: 0.35, green: 0.55, blue: 0.85, alpha: 0.22).setFill()
            while y < dirtyRect.maxY + spacing {
                NSRect(x: dirtyRect.minX, y: y.rounded(), width: dirtyRect.width, height: 1).fill()
                y += spacing
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView = documentView as? NSTextView else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    }
}

struct MarkdownEditor: NSViewRepresentable {
    let document: Document
    let style: PaperStyle
    let store: PaperStore

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, store: store)
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
        textView.textContainerInset = NSSize(width: 56, height: 56)
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

        init(document: Document, store: PaperStore) {
            self.document = document
            self.store = store
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? PaperTextView else { return }
            textView.restyle()
            document.markdown = textView.string
        }

        func paperMenuItems() -> [NSMenuItem] {
            var items: [NSMenuItem] = []
            items.append(item("New paper", #selector(newPaper)))
            if store.documents.count > 1 {
                items.append(item("Next paper", #selector(nextPaper)))
                items.append(item("Previous paper", #selector(previousPaper)))
            }

            let styleItem = NSMenuItem(title: "Paper style", action: nil, keyEquivalent: "")
            let styleMenu = NSMenu()
            for (index, style) in PaperStyle.allCases.enumerated() {
                let entry = item(style.label, #selector(setStyle(_:)))
                entry.tag = index
                entry.state = store.current?.paperStyle == style ? .on : .off
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

        @objc private func newPaper() { store.newPaper() }
        @objc private func nextPaper() { store.nextPaper() }
        @objc private func previousPaper() { store.previousPaper() }
        @objc private func deletePaper() { store.deleteCurrentPaper() }
        @objc private func setStyle(_ sender: NSMenuItem) {
            store.setStyle(PaperStyle.allCases[sender.tag])
        }
    }
}
#endif
