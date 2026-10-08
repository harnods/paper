import SwiftUI

struct PaperStylePicker: View {
    @Binding var style: PaperStyle

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PaperStyle.allCases) { paperStyle in
                Button(action: { style = paperStyle }) {
                    Image(systemName: paperStyle.icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(style == paperStyle ? .primary : .secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            style == paperStyle
                                ? AnyShapeStyle(.thinMaterial)
                                : AnyShapeStyle(.clear)
                            ,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .help(paperStyle.label)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
