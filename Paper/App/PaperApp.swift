import SwiftUI
import SwiftData

@main
struct PaperApp: App {
    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            ContentView()
                .background(TransparentWindow())
        }
        .modelContainer(for: Document.self)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 680, height: 860)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New paper") {
                    NotificationCenter.default.post(name: .createNewPaper, object: nil)
                }
                .keyboardShortcut("n")
            }
        }
        #else
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: Document.self)
        #endif
    }
}

extension Notification.Name {
    static let createNewPaper = Notification.Name("createNewPaper")
}

#if os(macOS)
struct TransparentWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.setContentSize(NSSize(width: 680, height: 860))
            window.styleMask.remove(.resizable)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
