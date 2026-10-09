#if os(macOS)
import AppKit
import SwiftData
import SwiftUI

enum PaperWindowID {
    static let main = "paper"
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
            AllPapersOverlay.show(store: store) { openWindow(value: $0) }
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

/// Shows the all-papers overview in a borderless panel that covers the whole screen, menu bar
/// included (a regular window can't go over the menu bar).
@MainActor
enum AllPapersOverlay {
    private final class OverlayPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private static var panel: NSPanel?
    private static var resignObserver: NSObjectProtocol?

    static func show(store: PaperStore, openPaper: @escaping (PersistentIdentifier) -> Void) {
        NSApp.activate()
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        guard let screen = NSScreen.main else { return }
        let panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)

        let view = AllPapersView(
            store: store,
            onOpenPaper: { id in
                openPaper(id)
                Task { @MainActor in
                    // A new window can take a moment to appear; keep trying for up to half a second.
                    for _ in 0..<10 {
                        try? await Task.sleep(for: .milliseconds(50))
                        if PaperWindowRegistry.bringToFront(id) { break }
                    }
                    hide()
                }
            },
            onClose: { hide() }
        )
        panel.contentView = NSHostingView(rootView: view.modelContainer(PaperData.container))
        panel.setFrame(screen.frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { _ in
            MainActor.assumeIsolated { hide() }
        }
    }

    static func hide() {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

/// One card in the overview: a folder or a paper.
private enum OverviewItem: Identifiable {
    case folder(Folder)
    case paper(Document)

    var id: String {
        switch self {
        case .folder(let folder): "folder-" + folder.folderID
        case .paper(let paper): "paper-" + String(describing: paper.persistentModelID.hashValue)
        }
    }
}

/// Dark overview: search on top, folders and papers in a Cover Flow carousel. Folders open into
/// their own carousel, with Back to go up.
struct AllPapersView: View {
    let store: PaperStore
    let onOpenPaper: (PersistentIdentifier) -> Void
    let onClose: () -> Void

    @State private var query = ""
    @State private var selected = 0
    @State private var dragProgress: CGFloat = 0
    @State private var currentFolderID: String?
    @State private var renaming: Folder?
    @State private var renameText = ""
    @FocusState private var searchFocused: Bool
    @FocusState private var renameFocused: Bool

    static let cardSize = CGSize(width: 264, height: 332)
    /// Horizontal distance from the centre card to its neighbours.
    private static let step: CGFloat = 230

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var items: [OverviewItem] {
        let text = query.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            return store.documents
                .filter { $0.title.localizedCaseInsensitiveContains(text) || $0.markdown.localizedCaseInsensitiveContains(text) }
                .map(OverviewItem.paper)
        }
        return store.folders(in: currentFolderID).map(OverviewItem.folder)
            + store.papers(in: currentFolderID).map(OverviewItem.paper)
    }

    var body: some View {
        let items = items
        let index = min(selected, max(items.count - 1, 0))

        ZStack {
            Color.black
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { renaming == nil ? goUpOrClose() : cancelRename() }

            VStack(spacing: 0) {
                topBar
                    .padding(.top, 64)
                Spacer()
                if items.isEmpty {
                    Text(emptyMessage)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.white.opacity(0.6))
                } else {
                    carousel(items, index: index)
                    caption(for: items[index])
                        .padding(.top, 8)
                }
                Spacer()
            }

            if renaming != nil {
                renameCard
            }
        }
        .background(KeyMonitor { key in handle(key, items: items) })
        .onAppear { searchFocused = true }
        .onChange(of: query) { _, _ in selected = 0 }
        .preferredColorScheme(.dark)
    }

    private var emptyMessage: String {
        if isSearching { return "No papers match \u{201C}\(query)\u{201D}" }
        return currentFolderID == nil ? "No papers yet" : "This folder is empty"
    }

    // MARK: Top bar

    private var topBar: some View {
        ZStack {
            HStack {
                if let folder = store.folder(for: currentFolderID), !isSearching {
                    Button { goUp() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                            Text(store.folder(for: folder.parentID)?.name ?? "All papers")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(Color.white.opacity(0.1), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                }
                Spacer()
            }
            .padding(.horizontal, 40)

            HStack(spacing: 10) {
                searchField
                Button { createFolder() } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("New folder")
                .pointingHandCursor()
            }
        }
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
                .onSubmit { activateCenter() }
        }
        .padding(.horizontal, 14)
        .frame(width: 420, height: 40)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
    }

    // MARK: Carousel

    private func carousel(_ items: [OverviewItem], index: Int) -> some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { position, item in
                let offset = CGFloat(position - index) + dragProgress
                if abs(offset) <= 6 {
                    card(item, offset: offset)
                        .allowsHitTesting(false)
                }
            }
            hitLayer(items, index: index)
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
                    selected = min(max(index + steps, 0), items.count - 1)
                }
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.86), value: index)
        .animation(.interactiveSpring(), value: dragProgress)
    }

    /// Flat click targets over the 3D cards, which don't hit-test reliably: the centre opens,
    /// either side moves to the previous or next card.
    private func hitLayer(_ items: [OverviewItem], index: Int) -> some View {
        let center = items[index]
        return HStack(spacing: 0) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { move(-1, count: items.count) }
            Color.clear
                .contentShape(Rectangle())
                .frame(width: Self.cardSize.width)
                .onTapGesture { activate(center) }
                .contextMenu { contextMenu(for: center) }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { move(1, count: items.count) }
        }
        .frame(height: Self.cardSize.height)
        .offset(y: -Self.cardSize.height * 0.15)
    }

    @ViewBuilder
    private func contextMenu(for item: OverviewItem) -> some View {
        switch item {
        case .folder(let folder):
            Button("Open") { activate(item) }
            Button("Rename") { startRename(folder) }
            Divider()
            Button("Delete folder", role: .destructive) { store.delete(folder) }
        case .paper(let paper):
            Button("Open") { activate(item) }
            Menu("Move to") {
                if paper.folderID != nil {
                    Button("All papers") { store.move(paper, to: nil) }
                }
                ForEach(store.folders.filter { $0.folderID != paper.folderID }, id: \.folderID) { folder in
                    Button(folder.name) { store.move(paper, to: folder.folderID) }
                }
            }
            Divider()
            Button("Delete paper", role: .destructive) { store.delete(paper) }
        }
    }

    /// Cover Flow: the centre card faces you; the rest turn away and tuck in on either side.
    private func card(_ item: OverviewItem, offset: CGFloat) -> some View {
        let distance = abs(offset)
        let side: CGFloat = offset < 0 ? -1 : 1
        let x = distance < 1 ? offset * Self.step : side * (Self.step + (distance - 1) * 70)
        let angle = distance < 1 ? Double(-offset) * 55 : Double(-side) * 55
        let scale = distance < 1 ? 1 - 0.15 * distance : 0.85
        let size = Self.cardSize

        return VStack(spacing: 6) {
            cardFace(item, tilt: angle)
                .frame(width: size.width, height: size.height)
            // Reflection on the "floor".
            cardFace(item, tilt: angle)
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

    @ViewBuilder
    private func cardFace(_ item: OverviewItem, tilt: Double) -> some View {
        switch item {
        case .folder(let folder):
            FolderCard(isEmpty: store.itemCount(in: folder) == 0, tilt: tilt)
        case .paper(let paper):
            PaperThumbnail(document: paper)
                .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        }
    }

    private func caption(for item: OverviewItem) -> some View {
        let title: String
        let detail: Text
        switch item {
        case .folder(let folder):
            title = folder.name
            let count = store.itemCount(in: folder)
            detail = Text(count == 0 ? "Empty" : count == 1 ? "1 item" : "\(count) items")
        case .paper(let paper):
            title = paper.title.isEmpty ? "Untitled" : paper.title
            detail = Text(paper.updatedAt, format: .relative(presentation: .named))
        }
        return VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(1)
            detail
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.55))
        }
        .frame(width: 420)
    }

    // MARK: Rename

    private var renameCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Folder name")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.7))
            TextField("Folder name", text: $renameText)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .focused($renameFocused)
                .onSubmit { commitRename() }
            HStack {
                Spacer()
                Button("Cancel") { cancelRename() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commitRename() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
    }

    private func createFolder() {
        let folder = store.newFolder(in: currentFolderID)
        query = ""
        selected = 0
        startRename(folder)
    }

    private func startRename(_ folder: Folder) {
        renameText = folder.name
        renaming = folder
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        if let folder = renaming { store.rename(folder, to: renameText) }
        renaming = nil
        searchFocused = true
    }

    private func cancelRename() {
        renaming = nil
        searchFocused = true
    }

    // MARK: Actions

    private func handle(_ key: KeyMonitor.Key, items: [OverviewItem]) -> Bool {
        if renaming != nil {
            if key == .escape { cancelRename(); return true }
            return false
        }
        switch key {
        case .left: move(-1, count: items.count)
        case .right: move(1, count: items.count)
        case .scroll(let step): move(step, count: items.count)
        case .escape: goUpOrClose()
        }
        return true
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selected = min(max(min(selected, count - 1) + delta, 0), count - 1)
    }

    private func activateCenter() {
        let items = items
        guard !items.isEmpty else { return }
        activate(items[min(selected, items.count - 1)])
    }

    private func activate(_ item: OverviewItem) {
        switch item {
        case .folder(let folder):
            query = ""
            currentFolderID = folder.folderID
            selected = 0
        case .paper(let paper):
            onOpenPaper(paper.persistentModelID)
        }
    }

    private func goUp() {
        let parent = store.folder(for: currentFolderID)?.parentID
        let leaving = currentFolderID
        currentFolderID = parent
        // Land on the folder we just came out of.
        let siblings = store.folders(in: parent)
        selected = siblings.firstIndex { $0.folderID == leaving } ?? 0
    }

    private func goUpOrClose() {
        if isSearching {
            query = ""
        } else if currentFolderID != nil {
            goUp()
        } else {
            onClose()
        }
    }
}

/// A blue folder with volume. Empty folders are just the folder; folders with something in them
/// show a sheet in the pocket and are thicker. When the carousel turns it (`tilt`, in degrees), the
/// back panel separates from the pocket and a shaded side wall fills the gap, so it reads as a solid
/// object; lighting on the pocket shifts with the turn.
struct FolderCard: View {
    let isEmpty: Bool
    var tilt: Double = 0

    private static let backBlue = Color(red: 0.20, green: 0.47, blue: 0.84)
    private static let pocketTop = Color(red: 0.45, green: 0.75, blue: 1.0)
    private static let pocketBottom = Color(red: 0.22, green: 0.52, blue: 0.90)
    private static let wallLight = Color(red: 0.16, green: 0.38, blue: 0.72)
    private static let wallDark = Color(red: 0.09, green: 0.25, blue: 0.52)
    private static let baseBlue = Color(red: 0.12, green: 0.32, blue: 0.64)

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width * 0.9
            let height = width * 0.8
            let pocketTopY = height * 0.3
            let pocketHeight = height - pocketTopY
            // Positive for cards on the left (their right side faces the middle), negative on the right.
            let turn = CGFloat(sin(tilt * .pi / 180))
            // How far apart the back and the pocket appear; a full folder is thicker.
            let depth = (isEmpty ? 26 : 40) * turn
            let pocketShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

            ZStack(alignment: .topLeading) {
                // Back panel, pushed toward the side that faces the viewer.
                FolderBackShape(tabWidth: width * 0.4, tabHeight: height * 0.12, radius: 16)
                    .fill(LinearGradient(colors: [Self.backBlue, Self.backBlue.opacity(0.85)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: width, height: height)
                    .offset(x: depth / 2)

                // Inside the folder: darker toward the bottom, where the pocket shades it.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [.clear, .black.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                    .frame(width: width * 0.96, height: height * 0.62)
                    .offset(x: width * 0.02 + depth / 2, y: height * 0.36)

                if !isEmpty {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: [.white, Color(white: 0.86)], startPoint: .top, endPoint: .bottom))
                        .frame(width: width * 0.86, height: height * 0.42)
                        .offset(x: width * 0.07 + depth * 0.15, y: height * 0.18)
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 2)
                }

                // Side wall joining the pocket to the back panel.
                if abs(depth) > 1 {
                    FolderSideWall(depth: depth, pocketTop: pocketTopY, inset: 18)
                        .fill(LinearGradient(colors: [Self.wallLight, Self.wallDark],
                                             startPoint: depth > 0 ? .leading : .trailing,
                                             endPoint: depth > 0 ? .trailing : .leading))
                        .frame(width: width, height: height)
                        .offset(x: -depth / 2)
                }

                // Base thickness under the pocket.
                pocketShape
                    .fill(Self.baseBlue)
                    .frame(width: width, height: pocketHeight)
                    .offset(x: -depth / 2, y: pocketTopY + 5)

                // Front pocket with a lit lip on top and shading that follows the turn.
                pocketShape
                    .fill(LinearGradient(colors: [Self.pocketTop, Self.pocketBottom], startPoint: .top, endPoint: .bottom))
                    .overlay(
                        pocketShape.fill(LinearGradient(
                            colors: [.clear, .black.opacity(Double(abs(turn)) * 0.22)],
                            startPoint: turn > 0 ? .leading : .trailing,
                            endPoint: turn > 0 ? .trailing : .leading))
                    )
                    .overlay(
                        pocketShape
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.05)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
                    )
                    .frame(width: width, height: pocketHeight)
                    .offset(x: -depth / 2, y: pocketTopY)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: -2)
            }
            .frame(width: width, height: height + 5)
            .shadow(color: .black.opacity(0.55), radius: 22, y: 12)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// The side wall of a turned folder: a band from the pocket's edge to the back panel's edge on the
/// side facing the viewer, slightly foreshortened at top and bottom.
struct FolderSideWall: Shape {
    /// Signed distance between the pocket and the back; positive means the wall is on the right.
    let depth: CGFloat
    let pocketTop: CGFloat
    let inset: CGFloat

    func path(in rect: CGRect) -> Path {
        let edge = depth > 0 ? rect.maxX - 1 : rect.minX + 1
        let far = edge + depth
        let squeeze = abs(depth) * 0.12
        var path = Path()
        path.move(to: CGPoint(x: edge, y: rect.minY + pocketTop + inset))
        path.addLine(to: CGPoint(x: far, y: rect.minY + pocketTop + inset - squeeze))
        path.addLine(to: CGPoint(x: far, y: rect.maxY - inset - squeeze))
        path.addLine(to: CGPoint(x: edge, y: rect.maxY - inset))
        path.closeSubpath()
        return path
    }
}

/// The back of a folder: one outline with the tab on the top left and a smooth slope down to the body.
struct FolderBackShape: Shape {
    let tabWidth: CGFloat
    let tabHeight: CGFloat
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = radius
        let slope = tabHeight * 1.2
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + tabWidth - slope * 0.5, y: rect.minY))
        path.addCurve(to: CGPoint(x: rect.minX + tabWidth + slope * 0.5, y: rect.minY + tabHeight),
                      control1: CGPoint(x: rect.minX + tabWidth, y: rect.minY),
                      control2: CGPoint(x: rect.minX + tabWidth, y: rect.minY + tabHeight))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY + tabHeight))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + tabHeight + r),
                          control: CGPoint(x: rect.maxX, y: rect.minY + tabHeight))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Watches keys and scroll events in the overview's window while it's key, so ← → Esc and
/// trackpad or mouse-wheel swipes work even while a text field has focus. The handler returns
/// false to let an event through.
struct KeyMonitor: NSViewRepresentable {
    enum Key: Equatable {
        case left, right, escape
        case scroll(Int)
    }

    var handler: (Key) -> Bool

    final class Coordinator {
        var monitor: Any?
        var handler: ((Key) -> Bool)?
        var scrollAccumulator: CGFloat = 0

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        /// Trackpads send many small deltas; step once per ~40pt of swipe. A mouse wheel steps per notch.
        func scrollStep(_ event: NSEvent) -> Int? {
            let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            let delta = horizontal ? event.scrollingDeltaX : event.scrollingDeltaY
            guard delta != 0 else { return nil }
            if !event.hasPreciseScrollingDeltas { return delta < 0 ? 1 : -1 }
            if event.phase == .began { scrollAccumulator = 0 }
            scrollAccumulator += delta
            guard abs(scrollAccumulator) >= 40 else { return nil }
            defer { scrollAccumulator = 0 }
            return scrollAccumulator < 0 ? 1 : -1
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.handler = handler
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak view, weak coordinator] event in
            guard let coordinator, let handler = coordinator.handler, event.window === view?.window else { return event }
            let key: Key?
            if event.type == .scrollWheel {
                guard let step = coordinator.scrollStep(event) else { return nil }
                key = .scroll(step)
            } else {
                switch event.keyCode {
                case 123: key = .left
                case 124: key = .right
                case 53: key = .escape
                default: key = nil
                }
            }
            guard let key else { return event }
            return handler(key) ? nil : event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = handler
    }
}

private extension View {
    func pointingHandCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
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
                case .todo(let checked): return (checked ? "\u{2611} " : "\u{2610} ") + body
                case .numbered(let n): return "\(n). " + body
                default: return body
                }
            }
            .joined(separator: "\n")
    }
}

#endif
