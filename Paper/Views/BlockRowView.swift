import SwiftUI

struct BlockRowView: View {
    @Binding var block: Block
    let isFocused: Bool
    var onReturn: (String) -> Void
    var onBackspaceEmpty: () -> Void
    var onTypeChange: (BlockType) -> Void

    #if os(macOS)
    @State private var isHovering = false
    #endif

    var body: some View {
        if block.type == .divider {
            dividerView
        } else {
            HStack(alignment: .top, spacing: 0) {
                blockLeading

                blockTextField
                    .onChange(of: block.content) { oldValue, newValue in
                        handleTextChange(old: oldValue, new: newValue)
                    }
            }
            .padding(.vertical, blockVerticalPadding)
            #if os(macOS)
            .onHover { isHovering = $0 }
            #endif
            .contextMenu { blockContextMenu }
        }
    }

    @ViewBuilder
    private var blockLeading: some View {
        switch block.type {
        case .bulletList:
            Text("\u{2022}")
                .font(.system(size: blockFontSize, weight: .regular))
                .foregroundStyle(Color.primary)
                .opacity(0.4)
                .frame(width: 20, alignment: .center)
                .padding(.top, leadingTopPadding)
        case .numberedList:
            Text("1.")
                .font(.system(size: blockFontSize - 1, weight: .medium))
                .foregroundStyle(Color.primary)
                .opacity(0.4)
                .frame(width: 24, alignment: .trailing)
                .padding(.trailing, 4)
                .padding(.top, leadingTopPadding)
        case .quote:
            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(width: 3)
                .padding(.trailing, 12)
        case .callout:
            Text("\u{1F4A1}")
                .font(.system(size: 14))
                .frame(width: 24)
                .padding(.top, leadingTopPadding)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var blockTextField: some View {
        let fontWeight: Font.Weight = block.type == .heading1 ? .bold :
            block.type == .heading2 ? .semibold :
            block.type == .heading3 ? .semibold : .regular

        let opacity: Double = block.type == .quote ? 0.6 :
            block.type == .callout ? 0.7 : 0.75

        TextField(placeholder, text: $block.content, axis: .vertical)
            .font(.system(size: blockFontSize, weight: fontWeight))
            .foregroundStyle(Color.primary)
            .opacity(opacity)
            .italic(block.type == .quote)
            .textFieldStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dividerView: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.vertical, 12)
            .contextMenu { blockContextMenu }
    }

    @ViewBuilder
    private var blockContextMenu: some View {
        Menu("Turn into") {
            ForEach(BlockType.allCases) { type in
                Button(action: { onTypeChange(type) }) {
                    Label(type.label, systemImage: type.icon)
                }
            }
        }
        Divider()
        Button(role: .destructive, action: onBackspaceEmpty) {
            Label("Delete", systemImage: "trash")
        }
    }

    private var blockFontSize: CGFloat {
        switch block.type {
        case .heading1: 28
        case .heading2: 22
        case .heading3: 18
        case .callout: 14
        default: 15
        }
    }

    private var blockVerticalPadding: CGFloat {
        switch block.type {
        case .heading1: 8
        case .heading2: 6
        case .heading3: 4
        case .quote: 4
        case .callout: 8
        default: 2
        }
    }

    private var leadingTopPadding: CGFloat {
        switch block.type {
        case .heading1: 6
        case .heading2: 4
        default: 2
        }
    }

    private var placeholder: String {
        switch block.type {
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .quote: "Quote"
        case .callout: "Callout"
        default: "Type '/' for commands"
        }
    }

    private func handleTextChange(old: String, new: String) {
        if let newlineRange = new.rangeOfCharacter(from: .newlines) {
            let before = String(new[new.startIndex..<newlineRange.lowerBound])
            let after = String(new[newlineRange.upperBound...])
            block.content = before
            onReturn(after)
            return
        }

        if block.type == .paragraph, let (newType, remaining) = Block.detectShortcut(in: new) {
            block.content = remaining
            onTypeChange(newType)
        }
    }
}
