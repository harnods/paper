import SwiftUI

struct PaperView: View {
    @Binding var document: Document
    let isActive: Bool

    private let cornerRadius: CGFloat = 16
    private let paperPadding: CGFloat = 40

    var body: some View {
        ZStack {
            paperBackground(document.paperStyle)

            if isActive {
                BlockEditorView(document: $document)
                    .padding(paperPadding)
                    #if os(macOS)
                    .padding(.top, 12)
                    #endif
            } else {
                VStack(alignment: .leading) {
                    Text(document.title.isEmpty ? " " : document.title)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .opacity(0.8)
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

            PaperTexture()

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

struct PaperTexture: View {
    var body: some View {
        Canvas { context, size in
            for _ in 0..<1500 {
                let x = CGFloat.random(in: 0..<size.width)
                let y = CGFloat.random(in: 0..<size.height)
                let opacity = Double.random(in: 0.01...0.025)
                let dotSize = CGFloat.random(in: 0.5...1.5)
                let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
                context.fill(
                    Rectangle().path(in: rect),
                    with: .color(Color.black.opacity(opacity))
                )
            }
        }
    }
}

struct DotPattern: View {
    let spacing: CGFloat = 24
    let dotSize: CGFloat = 2.5

    var body: some View {
        Canvas { context, size in
            let color = Color.black.opacity(0.15)
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
            let color = Color.black.opacity(0.12)
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
