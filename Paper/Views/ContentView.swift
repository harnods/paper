import SwiftUI
import SwiftData

enum PaperLayout {
    static let windowSize = CGSize(width: 720, height: 890)
    static let paperSize = CGSize(width: 660, height: 830)
    static let cornerRadius: CGFloat = 28
}

struct ContentView: View {
    let store: PaperStore

    var body: some View {
        #if os(macOS)
        ZStack {
            RoundedRectangle(cornerRadius: PaperLayout.cornerRadius, style: .continuous)
                .fill(Color.white)
                .frame(width: PaperLayout.paperSize.width, height: PaperLayout.paperSize.height)
                .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
                .shadow(color: .black.opacity(0.06), radius: 2, x: 0, y: 1)

            if let doc = store.current {
                MarkdownEditor(document: doc, style: doc.paperStyle, store: store)
                    .id(doc.persistentModelID)
                    .frame(width: PaperLayout.paperSize.width, height: PaperLayout.paperSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: PaperLayout.cornerRadius, style: .continuous))
            }
        }
        .frame(width: PaperLayout.windowSize.width, height: PaperLayout.windowSize.height)
        .preferredColorScheme(.light)
        #else
        if let doc = store.current {
            SimpleEditor(document: doc)
                .id(doc.persistentModelID)
        }
        #endif
    }
}

#if os(iOS)
struct SimpleEditor: View {
    @Bindable var document: Document
    @State private var text = ""

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 17))
            .foregroundStyle(Color.black)
            .scrollContentBackground(.hidden)
            .padding(24)
            .background(Color.white)
            .onAppear { text = document.markdown }
            .onChange(of: text) { _, newValue in document.markdown = newValue }
    }
}
#endif
