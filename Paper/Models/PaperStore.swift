import Foundation
import SwiftData
import Observation

@Observable
@MainActor
final class PaperStore {
    private let context: ModelContext
    private(set) var documents: [Document] = []
    var currentID: PersistentIdentifier?

    init(context: ModelContext) {
        self.context = context
        reload()
        if documents.isEmpty {
            newPaper()
        } else {
            currentID = documents.first?.persistentModelID
        }
    }

    var current: Document? {
        documents.first { $0.persistentModelID == currentID } ?? documents.first
    }

    /// Papers stacked behind the current one, nearest first.
    var papersBehind: Int {
        max(documents.count - 1, 0)
    }

    func newPaper() {
        let doc = Document(paperStyle: current?.paperStyle ?? .dotted)
        context.insert(doc)
        try? context.save()
        reload()
        currentID = doc.persistentModelID
    }

    func nextPaper() { step(by: 1) }
    func previousPaper() { step(by: -1) }

    func setStyle(_ style: PaperStyle) {
        current?.paperStyle = style
        try? context.save()
    }

    func deleteCurrentPaper() {
        guard let doc = current else { return }
        let index = documents.firstIndex { $0.persistentModelID == doc.persistentModelID } ?? 0
        context.delete(doc)
        try? context.save()
        reload()
        if documents.isEmpty {
            newPaper()
        } else {
            currentID = documents[min(index, documents.count - 1)].persistentModelID
        }
    }

    private func step(by offset: Int) {
        guard documents.count > 1, let doc = current,
              let index = documents.firstIndex(where: { $0.persistentModelID == doc.persistentModelID })
        else { return }
        let next = (index + offset + documents.count) % documents.count
        currentID = documents[next].persistentModelID
    }

    private func reload() {
        let descriptor = FetchDescriptor<Document>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        documents = (try? context.fetch(descriptor)) ?? []
    }
}
