import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Document.updatedAt, order: .reverse) private var documents: [Document]
    @State private var selectedDocument: Document?
    @State private var showDocumentList = false

    var body: some View {
        ZStack {
            WallpaperView()

            if documents.isEmpty {
                emptyState
            } else {
                paperStack
            }
        }
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(.secondary)
            Text("No papers yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            Button("New paper") {
                createNewDocument()
            }
            .buttonStyle(.bordered)
        }
    }

    private var paperStack: some View {
        ZStack {
            ForEach(Array(documents.prefix(3).enumerated().reversed()), id: \.element.id) { index, doc in
                if index > 0 {
                    PaperView(
                        document: .constant(doc),
                        isActive: false
                    )
                    .offset(y: CGFloat(index) * 6)
                    .scaleEffect(1.0 - CGFloat(index) * 0.02)
                    .opacity(1.0 - Double(index) * 0.15)
                    .allowsHitTesting(false)
                }
            }

            if let selected = selectedDocument ?? documents.first {
                PaperView(
                    document: binding(for: selected),
                    isActive: true
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: selectedDocument?.id)
    }

    private var controlsOverlay: some View {
        HStack(spacing: 12) {
            if let doc = selectedDocument {
                PaperStylePicker(style: Binding(
                    get: { doc.paperStyle },
                    set: { doc.paperStyle = $0 }
                ))
            }

            Button(action: createNewDocument) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(24)
    }

    private var documentListButton: some View {
        Group {
            if documents.count > 1 {
                Button(action: { showDocumentList = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 13, weight: .medium))
                        Text("\(documents.count)")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(24)
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
