#if os(macOS)
import AppKit
import SwiftData
import SwiftUI

enum PaperWindowID {
    static let main = "paper"
    static let allPapers = "all-papers"
}

/// Remembers each paper's window so it can be brought to the very front.
enum PaperWindowRegistry {
    private static var windows: [PersistentIdentifier: WeakWindow] = [:]

    private struct WeakWindow { weak var window: NSWindow? }

    static func register(_ window: NSWindow, for id: PersistentIdentifier) {
        windows[id] = WeakWindow(window: window)
    }

    /// Returns false while the paper's window hasn't appeared yet.
    @discardableResult
    static func bringToFront(_ id: PersistentIdentifier) -> Bool {
        guard let window = windows[id]?.window else { return false }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        return true
    }
}

/// Registers the window it lives in for a paper.
struct PaperWindowRegistrar: NSViewRepresentable {
    let paperID: PersistentIdentifier?

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard let paperID else { return }
        DispatchQueue.main.async {
            if let window = view.window { PaperWindowRegistry.register(window, for: paperID) }
        }
    }
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

/// Full-screen dark overlay: a search field on top and the papers in a Cover Flow carousel.
struct AllPapersView: View {
    let store: PaperStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var query = ""
    @State private var selected = 0
    @State private var dragProgress: CGFloat = 0
    @FocusState private var searchFocused: Bool

    static let cardSize = CGSize(width: 264, height: 332)
    /// Horizontal distance from the centre card to its neighbours.
    private static let step: CGFloat = 230

    private var screenSize: CGSize {
        NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
    }

    private var results: [Document] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return store.documents }
        return store.documents.filter {
            $0.title.localizedCaseInsensitiveContains(text) || $0.markdown.localizedCaseInsensitiveContains(text)
        }
    }

    var body: some View {
        let papers = results
        let index = min(selected, max(papers.count - 1, 0))

        ZStack {
            Color.black
                .contentShape(Rectangle())
                .onTapGesture { close() }

            VStack(spacing: 0) {
                searchField
                    .padding(.top, 72)
                Spacer()
                if papers.isEmpty {
                    Text(query.isEmpty ? "No papers yet" : "No papers match \u{201C}\(query)\u{201D}")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.white.opacity(0.6))
                } else {
                    carousel(papers, index: index)
                    caption(for: papers[index])
                        .padding(.top, 8)
                }
                Spacer()
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .background(OverlayWindowConfigurator(
            onLeft: { move(-1, in: papers) },
            onRight: { move(1, in: papers) },
            onEscape: { close() },
            onScroll: { move($0, in: papers) }
        ))
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in selected = 0 }
        .preferredColorScheme(.dark)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.6))
            TextField("Search papers", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(Color.white)
                .focused($searchFocused)
                .onSubmit {
                    let papers = results
                    guard !papers.isEmpty else { return }
                    open(papers[min(selected, papers.count - 1)])
                }
        }
        .padding(.horizontal, 14)
        .frame(width: 420, height: 40)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
    }

    private func carousel(_ papers: [Document], index: Int) -> some View {
        ZStack {
            ForEach(Array(papers.enumerated()), id: \.element.persistentModelID) { position, doc in
                let offset = CGFloat(position - index) + dragProgress
                if abs(offset) <= 6 {
                    card(doc, offset: offset)
                        .allowsHitTesting(false)
                }
            }
            hitLayer(papers, index: index)
                .zIndex(100)
        }
        .frame(height: Self.cardSize.height * 1.35)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in dragProgress = value.translation.width / Self.step }
                .onEnded { value in
                    let steps = Int((-value.translation.width / Self.step).rounded())
                    dragProgress = 0
                    selected = min(max(index + steps, 0), papers.count - 1)
                }
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: index)
        .animation(.interactiveSpring(), value: dragProgress)
    }

    /// Flat click targets over the 3D cards, which don't hit-test reliably: the centre opens the
    /// paper, either side moves to the previous or next one.
    private func hitLayer(_ papers: [Document], index: Int) -> some View {
        let center = papers[index]
        return HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { move(-1, in: papers) }
            Color.clear
                .contentShape(Rectangle())
                .frame(width: Self.cardSize.width)
                .onTapGesture { open(center) }
                .contextMenu {
                    Button("Open") { open(center) }
                    Button("Delete paper", role: .destructive) { store.delete(center) }
                }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { move(1, in: papers) }
        }
        .frame(height: Self.cardSize.height)
        .offset(y: -Self.cardSize.height * 0.15)
    }

    /// Cover Flow: the centre card faces you; the rest turn away and tuck in on either side.
    private func card(_ doc: Document, offset: CGFloat) -> some View {
        let distance = abs(offset)
        let side: CGFloat = offset < 0 ? -1 : 1
        let x = distance < 1 ? offset * Self.step : side * (Self.step + (distance - 1) * 70)
        let angle = distance < 1 ? Double(-offset) * 55 : Double(-side) * 55
        let scale = distance < 1 ? 1 - 0.15 * distance : 0.85
        let size = Self.cardSize

        return VStack(spacing: 6) {
            PaperThumbnail(document: doc)
                .frame(width: size.width, height: size.height)
                .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
            // Reflection on the "floor".
            PaperThumbnail(document: doc)
                .frame(width: size.width, height: size.height)
                .scaleEffect(x: 1, y: -1)
                .frame(height: size.height * 0.3, alignment: .top)
                .clipped()
                .mask(LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
        .scaleEffect(scale)
        .offset(x: x)
        .zIndex(-Double(distance))
    }

    private func caption(for doc: Document) -> some View {
        VStack(spacing: 4) {
            Text(doc.title.isEmpty ? "Untitled" : doc.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
            Text(doc.updatedAt, format: .relative(presentation: .named))
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .frame(width: 420)
    }

    private func move(_ delta: Int, in papers: [Document]) {
        guard !papers.isEmpty else { return }
        selected = min(max(min(selected, papers.count - 1) + delta, 0), papers.count - 1)
    }

    private func close() {
        dismissWindow(id: PaperWindowID.allPapers)
    }

    /// Opens the paper on top of everything, then closes the overlay.
    private func open(_ doc: Document) {
        let id = doc.persistentModelID
        NSApp.activate()
        openWindow(value: id)
        Task { @MainActor in
            // A new window can take a moment to appear; keep trying for up to half a second.
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(50))
                if PaperWindowRegistry.bringToFront(id) { break }
            }
            close()
        }
    }
}

/// A small, read-only rendering of a paper.
struct PaperThumbnail: View {
    let document: Document

    var body: some View {
        GeometryReader { geometry in
            // Laid out for a 150pt-wide card and scaled to whatever size it's shown at.
            let k = geometry.size.width / 150
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10 * k, style: .continuous)
                    .fill(Color.white)

                pattern(scale: k)

                VStack(alignment: .leading, spacing: 5 * k) {
                    Text(document.title.isEmpty ? "Untitled" : document.title)
                        .font(.system(size: 11 * k, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(document.title.isEmpty ? 0.3 : 1))
                        .lineLimit(2)
                    Text(previewText)
                        .font(.system(size: 7 * k))
                        .foregroundStyle(Color.black.opacity(0.8))
                        .lineSpacing(1.5 * k)
                        .lineLimit(16)
                }
                .padding(12 * k)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10 * k, style: .continuous))
        }
    }

    @ViewBuilder
    private func pattern(scale k: CGFloat) -> some View {
        switch document.paperStyle {
        case .plain:
            EmptyView()
        case .dotted:
            Canvas { context, size in
                let spacing: CGFloat = 8 * k
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

/// Turns the "All papers" window into a borderless overlay covering the whole screen. It closes
/// when you click away, and passes ← → and Esc to the view even while the search field has focus.
struct OverlayWindowConfigurator: NSViewRepresentable {
    var onLeft: () -> Void
    var onRight: () -> Void
    var onEscape: () -> Void
    /// Called with -1 or 1 for each step of trackpad swipe or mouse wheel.
    var onScroll: (Int) -> Void

    final class Coordinator {
        var observer: NSObjectProtocol?
        var monitor: Any?
        var parent: OverlayWindowConfigurator?
        var scrollAccumulator: CGFloat = 0

        /// Trackpads send many small deltas; step once per ~40pt of swipe. A mouse wheel steps per notch.
        func handleScroll(_ event: NSEvent) {
            let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
            guard delta != 0 else { return }
            if !event.hasPreciseScrollingDeltas {
                parent?.onScroll(delta < 0 ? 1 : -1)
                return
            }
            if event.phase == .began { scrollAccumulator = 0 }
            scrollAccumulator += delta
            if abs(scrollAccumulator) >= 40 {
                parent?.onScroll(scrollAccumulator < 0 ? 1 : -1)
                scrollAccumulator = 0
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.parent = self
        DispatchQueue.main.async {
            guard let window = view.window, let screen = window.screen ?? NSScreen.main else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .statusBar
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = false
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.styleMask.remove(.resizable)
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)

            coordinator.observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak window] _ in
                window?.close()
            }
            coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak window, weak coordinator] event in
                guard event.window === window, let coordinator, let parent = coordinator.parent else { return event }
                if event.type == .scrollWheel {
                    coordinator.handleScroll(event)
                    return nil
                }
                switch event.keyCode {
                case 123: parent.onLeft(); return nil
                case 124: parent.onRight(); return nil
                case 53: parent.onEscape(); return nil
                default: return event
                }
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
    }
}
#endif
