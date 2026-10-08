import SwiftUI
import SwiftData

@main
struct PaperApp: App {
    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .modelContainer(for: Document.self)
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 800)
        #else
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: Document.self)
        #endif
    }
}
