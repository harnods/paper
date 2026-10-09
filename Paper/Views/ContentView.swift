import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Document.updatedAt, order: .reverse) private var documents: [Document]
    @State private var selectedDocument: Document?
    @State private var showDocumentList = false

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
        }
        .ignoresSafeArea()
        .onAppear {
            if documents.isEmpty {
                createNewDocument()
            } else {
                selectedDocument = documents.first
            }
        }
        .overlay(alignment: .topTrailing) {
            controlsOverlay
        }
        .overlay(alignment: .topLeading) {
            documentListButton
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

    private var controlsOverlay: some View {
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
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, height: 28)
                    .background(.quaternary.opacity(0.5), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    private var documentListButton: some View {
        Group {
            if documents.count > 1 {
                Button(action: { showDocumentList = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                        Text("\(documents.count)")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(16)
            }
        }
    }

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
