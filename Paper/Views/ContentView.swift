import SwiftUI
import SwiftData

enum PaperLayout {
    static let windowSize = CGSize(width: 720, height: 900)
    static let paperSize = CGSize(width: 660, height: 830)
    static let cornerRadius: CGFloat = 28
}

struct ContentView: View {
    let store: PaperStore

    var body: some View {
        #if os(macOS)
        ZStack(alignment: .top) {
            StackedSheets(count: min(store.papersBehind, 2))

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
        .padding(.top, 20)
        .frame(width: PaperLayout.windowSize.width, height: PaperLayout.windowSize.height, alignment: .top)
        .preferredColorScheme(.light)
        #else
        if let doc = store.current {
            SimpleEditor(document: doc)
                .id(doc.persistentModelID)
        }
        #endif
    }
}

#if os(macOS)
/// Papers peeking out below the current one.
struct StackedSheets: View {
    let count: Int

    var body: some View {
        ZStack(alignment: .top) {
            ForEach((0..<count).reversed(), id: \.self) { index in
                let depth = CGFloat(index + 1)
                RoundedRectangle(cornerRadius: PaperLayout.cornerRadius, style: .continuous)
                    .fill(Color(white: 1 - 0.025 * Double(index + 1)))
                    .frame(width: PaperLayout.paperSize.width - 18 * depth,
                           height: PaperLayout.paperSize.height)
                    .rotationEffect(.degrees(index == 0 ? -0.8 : 1.1))
                    .offset(y: 9 * depth)
                    .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
            }
        }
        .animation(.easeOut(duration: 0.2), value: count)
    }
}
#else
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
