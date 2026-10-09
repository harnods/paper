import SwiftUI

struct PaperStylePicker: View {
    @Binding var style: PaperStyle
    #if os(macOS)
    @State private var isHovering = false
    #endif

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PaperStyle.allCases) { paperStyle in
                Button(action: { style = paperStyle }) {
                    let isSelected = style == paperStyle
                    Image(systemName: paperStyle.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .opacity(isSelected ? 0.5 : 0.4)
                        .frame(width: 24, height: 24)
                        .background(
                            isSelected
                                ? Color.black.opacity(0.05)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .help(paperStyle.label)
                #endif
            }
        }
        .padding(3)
        .background(Color.black.opacity(0.04), in: Capsule())
        #if os(macOS)
        .opacity(isHovering ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.2), value: isHovering)
        .onHover { isHovering = $0 }
        #endif
    }
}
