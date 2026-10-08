import SwiftUI

struct DocumentListView: View {
    let documents: [Document]
    @Binding var selectedDocument: Document?
    var onNew: () -> Void
    var onDelete: (Document) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(documents) { doc in
                    Button(action: {
                        selectedDocument = doc
                        dismiss()
                    }) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(doc.title.isEmpty ? "Untitled" : doc.title)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(doc.updatedAt.formatted(.relative(presentation: .named)))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        selectedDocument?.id == doc.id
                            ? Color.accentColor.opacity(0.1)
                            : Color.clear
                    )
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        onDelete(documents[index])
                    }
                }
            }
            .navigationTitle("Papers")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: {
                        onNew()
                        dismiss()
                    }) {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 320, height: 400)
        #endif
    }
}
