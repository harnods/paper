#if os(macOS)
import AppKit
import SwiftData
import SwiftUI

enum PaperWindowID {
    static let main = "paper"
    static let allPapers = "all-papers"
}

/// Menu bar dropdown.
struct PaperMenuBarMenu: View {
    let store: PaperStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("View all papers") {
            NSApp.activate()
            openWindow(id: PaperWindowID.allPapers)
        }
        .keyboardShortcut("a", modifiers: [.command, .shift])

        Button("New paper") {
            NSApp.activate()
            openWindow(value: store.newPaper())
        }
        .keyboardShortcut("n")

        Button("Show Paper") {
            NSApp.activate()
            openWindow(value: store.defaultPaperID())
        }

        Divider()

        Button("Quit Paper") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Floating strip of paper thumbnails, like the macOS screenshot history.
struct AllPapersView: View {
    let store: PaperStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var hovered: PersistentIdentifierBox?

    static let cardSize = CGSize(width: 150, height: 190)
    static let spacing: CGFloat = 28
    static let height: CGFloat = 300

    static func width(for count: Int) -> CGFloat {
        let screen = NSScreen.main?.visibleFrame.width ?? 1440
        let content = CGFloat(count) * cardSize.width + CGFloat(max(count - 1, 0)) * spacing + 80
        return min(max(content, 420), screen - 80)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: Self.spacing) {
                ForEach(store.documents) { doc in
                    card(for: doc)
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
        }
        .frame(width: Self.width(for: store.documents.count), height: Self.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08))
        )
        .background(FloatingPanelConfigurator())
        .focusable()
        .focusEffectDisabled()
        .onExitCommand { dismissWindow(id: PaperWindowID.allPapers) }
        .preferredColorScheme(.light)
    }

    private func card(for doc: Document) -> some View {
        let id = PersistentIdentifierBox(doc.persistentModelID)
        let isHovered = hovered == id

        return VStack(spacing: 10) {
            PaperThumbnail(document: doc)
                .frame(width: Self.cardSize.width, height: Self.cardSize.height)
                .scaleEffect(isHovered ? 1.03 : 1)
                .shadow(color: .black.opacity(isHovered ? 0.18 : 0.1), radius: isHovered ? 10 : 5, y: 3)

            VStack(spacing: 2) {
                Text(doc.title.isEmpty ? "Untitled" : doc.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.black)
                    .lineLimit(1)
                Text(doc.updatedAt, format: .relative(presentation: .named))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.black.opacity(0.5))
            }
            .frame(width: Self.cardSize.width)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onTapGesture { open(doc) }
        .contextMenu {
            Button("Open") { open(doc) }
            Button("Delete paper", role: .destructive) { store.delete(doc) }
        }
    }

    private func open(_ doc: Document) {
        dismissWindow(id: PaperWindowID.allPapers)
        NSApp.activate()
        openWindow(value: doc.persistentModelID)
    }
}

/// `PersistentIdentifier` wrapper so hover state can compare cards.
struct PersistentIdentifierBox: Hashable {
    let id: PersistentIdentifier
    init(_ id: PersistentIdentifier) { self.id = id }
}

/// A small, read-only rendering of a paper.
struct PaperThumbnail: View {
    let document: Document

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white)

            pattern

            VStack(alignment: .leading, spacing: 5) {
                Text(document.title.isEmpty ? "Untitled" : document.title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.black.opacity(document.title.isEmpty ? 0.3 : 1))
                    .lineLimit(2)
                Text(previewText)
                    .font(.system(size: 7))
                    .foregroundStyle(Color.black.opacity(0.8))
                    .lineSpacing(1.5)
                    .lineLimit(16)
            }
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var pattern: some View {
        switch document.paperStyle {
        case .plain:
            EmptyView()
        case .dotted:
            Canvas { context, size in
                let spacing: CGFloat = 8
                var y = spacing
                while y < size.height {
                    var x = spacing
                    while x < size.width {
                        context.fill(Circle().path(in: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2)),
                                     with: .color(.black.opacity(0.2)))
                        x += spacing
                    }
                    y += spacing
                }
            }
        case .lines:
            Canvas { context, size in
                let spacing: CGFloat = 9
                var y = spacing
                while y < size.height {
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)),
                                 with: .color(Color(red: 0.35, green: 0.55, blue: 0.85).opacity(0.3)))
                    y += spacing
                }
            }
        }
    }

    private var previewText: String {
        document.markdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .dropFirst()
            .prefix(20)
            .map { line -> String in
                let text = String(line)
                let info = MarkdownStyler.parse(text, isFirst: false)
                if info.kind == .divider { return "—" }
                var body = String((text as NSString).substring(from: min(info.markerLength, (text as NSString).length)))
                for marker in ["**", "~~", "==", "`", "*"] {
                    body = body.replacingOccurrences(of: marker, with: "")
                }
                switch info.kind {
                case .bullet: return "• " + body
                case .numbered(let n): return "\(n). " + body
                default: return body
                }
            }
            .joined(separator: "\n")
    }
}

/// Makes the strip a borderless floating panel at the top of the screen that closes when you click away.
struct FloatingPanelConfigurator: NSViewRepresentable {
    final class Coordinator {
        var observer: NSObjectProtocol?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .floating
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = false
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.styleMask.remove(.resizable)
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            Self.position(window)
            window.makeKeyAndOrderFront(nil)

            context.coordinator.observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak window] _ in
                window?.close()
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window { Self.position(window) }
        }
    }

    private static func position(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 12))
    }
}
#endif
