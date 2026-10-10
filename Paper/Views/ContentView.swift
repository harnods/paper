import SwiftUI
import SwiftData
import UniformTypeIdentifiers

enum PaperLayout {
    /// The window is exactly the paper, so system highlights (Mission Control, App Exposé) hug it;
    /// the shadow comes from the window itself, which follows the paper's rounded shape.
    static let paperSize = CGSize(width: 660, height: 830)
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

    var body: some View {
        #if os(macOS)
        ZStack {
            if let doc = store.document(for: paperID) {
                RoundedRectangle(cornerRadius: PaperLayout.cornerRadius, style: .continuous)
                    .fill(Color.white)

                MarkdownEditor(document: doc, style: doc.paperStyle, store: store, actions: actions(for: doc))
                    .id(doc.persistentModelID)
                    .clipShape(RoundedRectangle(cornerRadius: PaperLayout.cornerRadius, style: .continuous))
                    .focusedSceneValue(\.paperDocument, doc)

                // Hairline on the paper's edge.
                RoundedRectangle(cornerRadius: PaperLayout.cornerRadius, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.35), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        // Fill the whole window, title bar area included; AppKit sizes the window to the paper.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
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
        PaperLibraryView(store: store)
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
/// iPhone: connect the iCloud Drive "Paper" folder once, then browse folders and papers.
struct PaperLibraryView: View {
    let store: PaperStore
    @State private var choosingFolder = false

    var body: some View {
        Group {
            if store.folderURL == nil {
                connectFolder
            } else {
                NavigationStack {
                    PaperListView(store: store, folderID: nil)
                }
            }
        }
        .preferredColorScheme(.light)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { store.chooseFolder(url) }
        }
    }

    private var connectFolder: some View {
        VStack(spacing: 16) {
            Text("Connect your papers")
                .font(.system(size: 24, weight: .semibold))
            Text("Open Paper on your Mac first. It makes a folder called Paper in iCloud Drive. Then choose that folder here.")
                .font(.system(size: 16))
                .foregroundStyle(Color.black.opacity(0.6))
                .multilineTextAlignment(.center)
            Button("Choose Paper folder") { choosingFolder = true }
                .buttonStyle(.borderedProminent)
                .tint(.black)
                .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
    }
}

struct PaperListView: View {
    let store: PaperStore
    let folderID: String?
    @State private var newPaper: Document?

    var body: some View {
        List {
            ForEach(store.folders(in: folderID), id: \.folderID) { folder in
                NavigationLink {
                    PaperListView(store: store, folderID: folder.folderID)
                } label: {
                    Label(folder.name, systemImage: "folder")
                }
            }
            ForEach(store.papers(in: folderID), id: \.persistentModelID) { paper in
                NavigationLink {
                    PaperEditorScreen(document: paper, store: store)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(paper.title.isEmpty ? "Untitled" : paper.title)
                        Text(paper.updatedAt, format: .relative(presentation: .named))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                let papers = store.papers(in: folderID)
                for index in offsets { store.delete(papers[index]) }
            }
        }
        .navigationTitle(store.folder(for: folderID)?.name ?? "All papers")
        .refreshable { store.syncFiles() }
        .toolbar {
            Button("New paper", systemImage: "square.and.pencil") {
                let id = store.newPaper()
                if let paper = store.document(for: id) {
                    store.move(paper, to: folderID)
                    newPaper = paper
                }
            }
        }
        .navigationDestination(item: $newPaper) { paper in
            PaperEditorScreen(document: paper, store: store)
        }
    }
}

/// One paper, full screen, with the same editor as the Mac.
struct PaperEditorScreen: View {
    let document: Document
    let store: PaperStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PaperEditorView(document: document, store: store)
            .id(document.persistentModelID)
            .ignoresSafeArea(.container, edges: .bottom)
            .background(Color.white)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.white, for: .navigationBar)
            .toolbar {
                Menu {
                    Picker("Paper style", selection: Binding(
                        get: { document.paperStyle },
                        set: { store.setStyle($0, for: document) }
                    )) {
                        ForEach(PaperStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    Button("Delete paper", systemImage: "trash", role: .destructive) {
                        dismiss()
                        // Let the editor close (and save) before the paper goes away.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { store.delete(document) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .tint(.black)
            }
    }
}
#endif
