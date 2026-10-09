import Foundation

enum PaperStyle: String, CaseIterable, Identifiable {
    case plain
    case dotted
    case lines

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plain: "Plain"
        case .dotted: "Dotted"
        case .lines: "Ruled"
        }
    }
}
