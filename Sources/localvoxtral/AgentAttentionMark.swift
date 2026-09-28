/// The orange mark the menu bar mic gets while an agent needs you (#717).
/// Each is drawn in cells of the mic's own pixel grid, right of the mic head,
/// so it neither covers the mic nor breaks its pixel art.
enum AgentAttentionMark: String, CaseIterable, Identifiable {
    case dot
    case square
    case exclamation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dot: "Dot"
        case .square: "Square"
        case .exclamation: "Exclamation mark"
        }
    }

    /// The lit cells, as (column, row) from the top left of the icon's
    /// 22 × 22 grid. The mic head spans columns 7–13, rows 1–7.
    var cells: [(x: Int, y: Int)] {
        switch self {
        case .dot:
            Self.cells(originX: 16, originY: 1, rows: [".##.", "####", "####", ".##."])
        case .square:
            Self.cells(originX: 17, originY: 1, rows: ["###", "###", "###"])
        case .exclamation:
            Self.cells(originX: 18, originY: 1, rows: ["##", "##", "##", "##", "..", "##"])
        }
    }

    private static func cells(originX: Int, originY: Int, rows: [String]) -> [(x: Int, y: Int)] {
        rows.enumerated().flatMap { dy, row in
            row.enumerated().compactMap { dx, cell in
                cell == "#" ? (x: originX + dx, y: originY + dy) : nil
            }
        }
    }
}
