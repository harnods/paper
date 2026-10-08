import SwiftUI

enum PaperStyle: String, CaseIterable, Identifiable {
    case plain
    case dotted
    case lines

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plain: "Plain"
        case .dotted: "Dotted"
        case .lines: "Lines"
        }
    }

    var icon: String {
        switch self {
        case .plain: "doc"
        case .dotted: "circle.grid.3x3"
        case .lines: "line.3.horizontal"
        }
    }
}
