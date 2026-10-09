import SwiftUI
import SwiftData

@main
struct PaperApp: App {
    private let container: ModelContainer
    @State private var store: PaperStore

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Document.self)
        } catch {
            fatalError("Could not open the paper store: \(error)")
        }
        self.container = container
        _store = State(initialValue: PaperStore(context: container.mainContext))
    }

    var body: some Scene {
        #if os(macOS)
        Window("Paper", id: "paper") {
            ContentView(store: store)
                .background(TransparentWindow())
        }
        .modelContainer(container)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands { PaperCommands(store: store) }
        #else
        WindowGroup {
            ContentView(store: store)
        }
        .modelContainer(container)
        #endif
    }
}

#if os(macOS)
struct PaperCommands: Commands {
    let store: PaperStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New paper") { store.newPaper() }
                .keyboardShortcut("n")
        }

        CommandMenu("Paper") {
            Button("Next paper") { store.nextPaper() }
                .keyboardShortcut("]")
            Button("Previous paper") { store.previousPaper() }
                .keyboardShortcut("[")
            Divider()
            Button("Plain") { store.setStyle(.plain) }
                .keyboardShortcut("1")
            Button("Dotted") { store.setStyle(.dotted) }
                .keyboardShortcut("2")
            Button("Ruled") { store.setStyle(.lines) }
                .keyboardShortcut("3")
            Divider()
            Button("Delete paper") { store.deleteCurrentPaper() }
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
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
