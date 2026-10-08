import SwiftUI

struct WallpaperView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.55, green: 0.70, blue: 0.82),
                    Color(red: 0.72, green: 0.75, blue: 0.78),
                    Color(red: 0.78, green: 0.72, blue: 0.65),
                    Color(red: 0.82, green: 0.76, blue: 0.68),
                    Color(red: 0.85, green: 0.80, blue: 0.72),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // Subtle noise texture overlay
            Canvas { context, size in
                for _ in 0..<800 {
                    let x = CGFloat.random(in: 0..<size.width)
                    let y = CGFloat.random(in: 0..<size.height)
                    let opacity = Double.random(in: 0.01...0.03)
                    let rect = CGRect(x: x, y: y, width: 1, height: 1)
                    context.fill(
                        Rectangle().path(in: rect),
                        with: .color(.white.opacity(opacity))
                    )
                }
            }
        }
        .ignoresSafeArea()
    }
}
