import SwiftUI
import SwiftData

@main
struct PaperApp: App {
    private let container = PaperData.container
    @State private var store = PaperData.store

    var body: some Scene {
        #if os(macOS)
        WindowGroup("Paper", id: PaperWindowID.main, for: PersistentIdentifier.self) { $paperID in
            ContentView(store: store, paperID: $paperID)
                .background(TransparentWindow())
        }
        .modelContainer(container)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands { PaperCommands(store: store) }

        Window("All papers", id: PaperWindowID.allPapers) {
            AllPapersView(store: store)
        }
        .modelContainer(container)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.top)

        MenuBarExtra("Paper", image: "MenuBarIcon") {
            PaperMenuBarMenu(store: store)
        }
        #else
        WindowGroup(for: PersistentIdentifier.self) { $paperID in
            ContentView(store: store, paperID: $paperID)
        }
        .modelContainer(container)
        #endif
    }
}

#if os(macOS)
struct PaperCommands: Commands {
    let store: PaperStore
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.paperDocument) private var focusedPaper

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New paper") {
                openWindow(value: store.newPaper(style: focusedPaper?.paperStyle ?? .dotted))
            }
            .keyboardShortcut("n")
        }

        CommandMenu("Paper") {
            Button("View all papers") { openWindow(id: PaperWindowID.allPapers) }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Divider()
            Button("Plain") { setStyle(.plain) }
                .keyboardShortcut("1")
            Button("Dotted") { setStyle(.dotted) }
                .keyboardShortcut("2")
            Button("Ruled") { setStyle(.lines) }
                .keyboardShortcut("3")
            Divider()
            Button("Delete paper") {
                if let focusedPaper { store.delete(focusedPaper) }
            }
            .disabled(focusedPaper == nil)
        }

        CommandMenu("Format") {
            Button("Bold") { send(#selector(PaperTextView.toggleBoldMarkdown(_:))) }
                .keyboardShortcut("b")
            Button("Italic") { send(#selector(PaperTextView.toggleItalicMarkdown(_:))) }
                .keyboardShortcut("i")
            Button("Strikethrough") { send(#selector(PaperTextView.toggleStrikeMarkdown(_:))) }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Inline code") { send(#selector(PaperTextView.toggleCodeMarkdown(_:))) }
                .keyboardShortcut("e")
            Button("Highlight") { send(#selector(PaperTextView.toggleHighlightMarkdown(_:))) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            Button("Text") { send(#selector(PaperTextView.setLineText(_:))) }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Button("Heading 1") { send(#selector(PaperTextView.setLineHeading1(_:))) }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("Heading 2") { send(#selector(PaperTextView.setLineHeading2(_:))) }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("Heading 3") { send(#selector(PaperTextView.setLineHeading3(_:))) }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Button("Bullet list") { send(#selector(PaperTextView.setLineBullet(_:))) }
                .keyboardShortcut("8", modifiers: [.command, .shift])
            Button("Numbered list") { send(#selector(PaperTextView.setLineNumbered(_:))) }
                .keyboardShortcut("7", modifiers: [.command, .shift])
            Button("Quote") { send(#selector(PaperTextView.setLineQuote(_:))) }
                .keyboardShortcut("9", modifiers: [.command, .shift])
            Button("Callout") { send(#selector(PaperTextView.setLineCallout(_:))) }
            Divider()
            Button("Move block up") { send(#selector(PaperTextView.moveBlockUp(_:))) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .control])
            Button("Move block down") { send(#selector(PaperTextView.moveBlockDown(_:))) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .control])
        }
    }

    private func setStyle(_ style: PaperStyle) {
        if let focusedPaper { store.setStyle(style, for: focusedPaper) }
    }

    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
}

struct TransparentWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.appearance = NSAppearance(named: .aqua)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.styleMask.remove(.resizable)
            window.tabbingMode = .disallowed
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
            // Every paper opens in the middle of the screen, new or reopened.
            window.center()
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
