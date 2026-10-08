import SwiftUI

struct MarkdownEditorView: View {
    @Binding var title: String
    @Binding var content: String
    var onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Untitled", text: $title, axis: .vertical)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .textFieldStyle(.plain)
                .onChange(of: title) { onEdit() }

            #if os(macOS)
            MacEditorView(text: $content, onEdit: onEdit)
            #else
            TextEditor(text: $content)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.primary.opacity(0.75))
                .scrollContentBackground(.hidden)
                .onChange(of: content) { onEdit() }
            #endif
        }
    }
}

#if os(macOS)
struct MacEditorView: NSViewRepresentable {
    @Binding var text: String
    var onEdit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.isRichText = false
        textView.font = .systemFont(ofSize: 15, weight: .regular)
        textView.textColor = NSColor.labelColor.withAlphaComponent(0.75)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = .zero
        textView.delegate = context.coordinator

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        textView.string = text

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selection
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MacEditorView

        init(_ parent: MacEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onEdit()
        }
    }
}
#endif
