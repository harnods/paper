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
        .contextMenu {
            Button("New paper") {
                createNewDocument()
            }

            Divider()

            if let doc = selectedDocument {
                Menu("Paper style") {
                    ForEach(PaperStyle.allCases) { style in
                        Button(action: { doc.paperStyle = style }) {
                            HStack {
                                Text(style.label)
                                if doc.paperStyle == style {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }

            if documents.count > 1 {
                Divider()

                Menu("Switch paper") {
                    ForEach(documents) { doc in
                        Button(action: { selectedDocument = doc }) {
                            HStack {
                                Text(doc.title.isEmpty ? "Untitled" : doc.title)
                                if selectedDocument?.id == doc.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if documents.isEmpty {
                createNewDocument()
            } else {
                selectedDocument = documents.first
            }
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: .createNewPaper)) { _ in
            createNewDocument()
        }
        #endif
        .sheet(isPresented: $showDocumentList) {
            DocumentListView(
                documents: documents,
                selectedDocument: $selectedDocument,
                onNew: createNewDocument,
                onDelete: deleteDocument
            )
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
