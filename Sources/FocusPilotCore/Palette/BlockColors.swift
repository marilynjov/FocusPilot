import Foundation

/// The palette roles a day plan block is drawn in (#25): a background and
/// the text drawn on it. Every pair here is held to 4.5:1 by a test.
public struct BlockColors: Hashable, Sendable {
    public let background: PaletteRole
    public let text: PaletteRole

    public init(background: PaletteRole, text: PaletteRole) {
        self.background = background
        self.text = text
    }

    /// Task 1, 2 and 3, used in turn by the plan's tasks.
    public static let tasks = [
        BlockColors(background: .t1bg, text: .t1fg),
        BlockColors(background: .t2bg, text: .t2fg),
        BlockColors(background: .t3bg, text: .t3fg),
    ]
    public static let lunch = BlockColors(background: .lunchbg, text: .lunchfg)
    /// Breaks and the wrap-up.
    public static let rest = BlockColors(background: .breakbg, text: .breakfg)

    /// Every pair a block can be drawn in.
    public static let all = tasks + [lunch, rest]
}

extension DayPlan {
    /// A task block's colors follow the order in which its task first
    /// appears in the plan, cycling through Task 1–3, so every block of one
    /// task shares a color. Task blocks with no task picked share one color
    /// too. Lunch has its own; breaks and the wrap-up share the break colors.
    public func colors(of block: DayBlock) -> BlockColors {
        switch block.kind {
        case .lunch: return .lunch
        case .break, .wrapUp: return .rest
        case .task:
            var order: [Int64?] = []
            for planned in blocks where planned.kind == .task && !order.contains(planned.taskID) {
                order.append(planned.taskID)
            }
            let index = order.firstIndex(of: block.taskID) ?? order.count
            return BlockColors.tasks[index % BlockColors.tasks.count]
        }
    }
}
