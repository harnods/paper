import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Document.updatedAt, order: .reverse) private var documents: [Document]
    @State private var selectedDocument: Document?
    @State private var showDocumentList = false
    #if os(macOS)
    @State private var isHovering = false
    #endif

    var body: some View {
        ZStack {
            #if os(macOS)
            Color.clear
            #else
            Color(.systemBackground)
            #endif

            if let selected = selectedDocument ?? documents.first {
                PaperView(
                    document: binding(for: selected),
                    isActive: true
                )
            }

            #if os(macOS)
            controlsOverlay
            #endif
        }
        .ignoresSafeArea()
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
        .onAppear {
            if documents.isEmpty {
                createNewDocument()
            } else {
                selectedDocument = documents.first
            }
        }
        .sheet(isPresented: $showDocumentList) {
            DocumentListView(
                documents: documents,
                selectedDocument: $selectedDocument,
                onNew: createNewDocument,
                onDelete: deleteDocument
            )
        }
    }

    #if os(macOS)
    private var controlsOverlay: some View {
        VStack {
            HStack {
                if documents.count > 1 {
                    Button(action: { showDocumentList = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12, weight: .medium))
                            Text("\(documents.count)")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(Color.secondary)
                        .opacity(0.5)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.04), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                HStack(spacing: 8) {
                    if let doc = selectedDocument {
                        PaperStylePicker(style: Binding(
                            get: { doc.paperStyle },
                            set: { doc.paperStyle = $0 }
                        ))
                    }

                    Button(action: createNewDocument) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.secondary)
                            .opacity(0.4)
                            .frame(width: 28, height: 28)
                            .background(Color.black.opacity(0.04), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)

            Spacer()
        }
        .opacity(isHovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.25), value: isHovering)
    }
    #endif

    private func binding(for document: Document) -> Binding<Document> {
        Binding(
            get: { document },
            set: { _ in }
        )
    }

    private func createNewDocument() {
        let doc = Document(title: "", content: "")
        modelContext.insert(doc)
        selectedDocument = doc
    }

    private func deleteDocument(_ doc: Document) {
        if selectedDocument?.id == doc.id {
            selectedDocument = documents.first(where: { $0.id != doc.id })
        }
        modelContext.delete(doc)
    }
}
