import SwiftUI

struct PaperView: View {
    @Binding var document: Document
    let isActive: Bool

    @FocusState private var editorFocused: Bool

    private let cornerRadius: CGFloat = 16
    private let paperPadding: CGFloat = 40

    var body: some View {
        ZStack {
            paperBackground(document.paperStyle)

            VStack(alignment: .leading, spacing: 0) {
                if isActive {
                    MarkdownEditorView(
                        title: $document.title,
                        content: $document.content,
                        onEdit: { document.updatedAt = Date() }
                    )
                    .focused($editorFocused)
                    .padding(paperPadding)
                    #if os(macOS)
                    .padding(.top, 12)
                    #endif
                } else {
                    Text(document.title.isEmpty ? " " : document.title)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.8))
                        .padding(paperPadding)
                    Spacer()
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        #if os(macOS)
        .shadow(color: .black.opacity(0.15), radius: 30, x: 0, y: 10)
        .shadow(color: .black.opacity(0.05), radius: 6, x: 0, y: 2)
        #endif
    }

    @ViewBuilder
    private func paperBackground(_ style: PaperStyle) -> some View {
        ZStack {
            Color.white

            switch style {
            case .plain:
                EmptyView()
            case .dotted:
                DotPattern()
            case .lines:
                LinePattern()
            }
        }
    }
}

struct DotPattern: View {
    let spacing: CGFloat = 24
    let dotSize: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            let color = Color.black.opacity(0.06)
            let startX = spacing
            let startY = spacing * 3

            var y = startY
            while y < size.height - spacing {
                var x = startX
                while x < size.width - spacing {
                    let rect = CGRect(
                        x: x - dotSize / 2,
                        y: y - dotSize / 2,
                        width: dotSize,
                        height: dotSize
                    )
                    context.fill(Circle().path(in: rect), with: .color(color))
                    x += spacing
                }
                y += spacing
            }
        }
    }
}

struct LinePattern: View {
    let spacing: CGFloat = 32
    let lineWidth: CGFloat = 0.5

    var body: some View {
        Canvas { context, size in
            let color = Color.black.opacity(0.06)
            let startY = spacing * 3

            var y = startY
            while y < size.height - spacing {
                let path = Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(color), lineWidth: lineWidth)
                y += spacing
            }
        }
    }
}
