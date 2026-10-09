import SwiftUI
import SwiftData

@main
struct PaperApp: App {
    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            ContentView()
                .frame(minWidth: 500, minHeight: 400)
                .background(TransparentWindow())
        }
        .modelContainer(for: Document.self)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 680, height: 860)
        #else
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: Document.self)
        #endif
    }
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
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif
