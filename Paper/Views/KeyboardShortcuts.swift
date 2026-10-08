import SwiftUI

struct KeyboardShortcutsModifier: ViewModifier {
    var onNewDocument: () -> Void

    func body(content: Content) -> some View {
        content
            .keyboardShortcut("n", modifiers: .command)
    }
}
