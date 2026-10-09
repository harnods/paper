import SwiftUI
import SwiftData

enum PaperLayout {
    static let paperSize = CGSize(width: 660, height: 830)
    /// The window is exactly the paper, so system highlights (Mission Control, App Exposé) hug it;
    /// the shadow comes from the window itself, which follows the paper's rounded shape.
    static let windowSize = paperSize
    static let cornerRadius: CGFloat = 28
}

struct PaperDocumentKey: FocusedValueKey {
    typealias Value = Document
}

extension FocusedValues {
    /// The paper in the key window, for menu commands.
    var paperDocument: Document? {
        get { self[PaperDocumentKey.self] }
        set { self[PaperDocumentKey.self] = newValue }
    }
}

/// Window-level actions the editor's right-click menu can trigger.
struct PaperActions {
    var newPaper: () -> Void
    var viewAllPapers: () -> Void
    var delete: () -> Void
}

/// One window showing one paper.
struct ContentView: View {
    let store: PaperStore
    @Binding var paperID: PersistentIdentifier?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @State private var titlebarHeight: CGFloat = 0
    #endif

    var body: some View {
        #if os(macOS)
        ZStack {
            if let doc = store.document(for: paperID) {
                RoundedRectangle(cornerRadius: PaperLayout.cornerRadius, style: .continuous)
                    .fill(Color.white)
                    .frame(width: PaperLayout.paperSize.width, height: PaperLayout.paperSize.height)

                MarkdownEditor(document: doc, style: doc.paperStyle, store: store, actions: actions(for: doc))
                    .id(doc.persistentModelID)
                    .frame(width: PaperLayout.paperSize.width, height: PaperLayout.paperSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: PaperLayout.cornerRadius, style: .continuous))
                    .focusedSceneValue(\.paperDocument, doc)

                // Hairline on the paper's edge.
                RoundedRectangle(cornerRadius: PaperLayout.cornerRadius, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.1), lineWidth: 1)
                    .frame(width: PaperLayout.paperSize.width, height: PaperLayout.paperSize.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: PaperLayout.windowSize.width, height: PaperLayout.windowSize.height - titlebarHeight)
        .ignoresSafeArea()
        .background(TitlebarHeightReader(height: $titlebarHeight))
        .background(PaperWindowRegistrar(paperID: paperID))
        .preferredColorScheme(.light)
        .onAppear {
            if paperID == nil { paperID = store.defaultPaperID() }
        }
        .onChange(of: store.documents.count) { _, _ in
            if paperID != nil, store.document(for: paperID) == nil { dismiss() }
        }
        .onChange(of: store.pendingOpen) { _, id in
            guard let id else { return }
            store.pendingOpen = nil
            openWindow(value: id)
        }
        #else
        if let doc = store.document(for: paperID) ?? store.documents.first {
            SimpleEditor(document: doc)
                .id(doc.persistentModelID)
        } else {
            Color.white.onAppear { paperID = store.defaultPaperID() }
        }
        #endif
    }

    #if os(macOS)
    private func actions(for doc: Document) -> PaperActions {
        PaperActions(
            newPaper: { openWindow(value: store.newPaper(style: doc.paperStyle)) },
            viewAllPapers: { AllPapersOverlay.show(store: store) { openWindow(value: $0) } },
            delete: { store.delete(doc) }
        )
    }
    #endif
}

#if os(iOS)
struct SimpleEditor: View {
    let document: Document
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
