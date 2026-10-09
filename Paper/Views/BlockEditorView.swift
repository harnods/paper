import SwiftUI

struct BlockEditorView: View {
    @Binding var document: Document
    @State private var blocks: [Block] = []
    @FocusState private var focusedBlockID: UUID?
    @State private var needsFocusBlock: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Untitled", text: $document.title, axis: .vertical)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Color.primary)
                .opacity(0.85)
                .textFieldStyle(.plain)
                .padding(.bottom, 20)
                .onSubmit {
                    if let first = blocks.first {
                        focusedBlockID = first.id
                    }
                }
                .onChange(of: document.title) { _, _ in
                    document.updatedAt = Date()
                }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                        BlockRowView(
                            block: bindingForBlock(at: index),
                            isFocused: focusedBlockID == block.id,
                            onReturn: { extraText in
                                insertBlock(after: index, content: extraText)
                            },
                            onBackspaceEmpty: {
                                deleteBlock(at: index)
                            },
                            onTypeChange: { newType in
                                blocks[index].type = newType
                                saveBlocks()
                            }
                        )
                        .focused($focusedBlockID, equals: block.id)
                        .id(block.id)
                    }
                }
            }
        }
        .onAppear {
            blocks = document.blocks
            if blocks.isEmpty {
                blocks = [Block()]
            }
        }
        .onChange(of: focusedBlockID) { _, _ in }
        .onChange(of: needsFocusBlock) { _, newValue in
            if let id = newValue {
                focusedBlockID = id
                needsFocusBlock = nil
            }
        }
    }

    private func bindingForBlock(at index: Int) -> Binding<Block> {
        Binding(
            get: { blocks[index] },
            set: { newValue in
                blocks[index] = newValue
                saveBlocks()
            }
        )
    }

    private func insertBlock(after index: Int, content: String) {
        let newBlock = Block(content: content)
        blocks.insert(newBlock, at: index + 1)
        saveBlocks()
        DispatchQueue.main.async {
            needsFocusBlock = newBlock.id
        }
    }

    private func deleteBlock(at index: Int) {
        guard blocks.count > 1, index > 0 else { return }
        let prevBlock = blocks[index - 1]
        blocks.remove(at: index)
        saveBlocks()
        DispatchQueue.main.async {
            needsFocusBlock = prevBlock.id
        }
    }

    private func saveBlocks() {
        document.blocks = blocks
        document.updatedAt = Date()
    }
}
