import SwiftUI

struct PaperStylePicker: View {
    @Binding var style: PaperStyle
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PaperStyle.allCases) { paperStyle in
                Button(action: { style = paperStyle }) {
                    Image(systemName: paperStyle.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(style == paperStyle ? .primary.opacity(0.5) : .tertiary)
                        .frame(width: 24, height: 24)
                        .background(
                            style == paperStyle
                                ? AnyShapeStyle(.quaternary.opacity(0.5))
                                : AnyShapeStyle(.clear),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .help(paperStyle.label)
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.3), in: Capsule())
        .opacity(isHovering ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.2), value: isHovering)
        .onHover { isHovering = $0 }
    }
}
