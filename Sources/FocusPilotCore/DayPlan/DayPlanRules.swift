import Foundation

/// Why a block, a plan or the day preferences cannot be saved as they are.
public enum DayPlanProblem: Error, Hashable, Sendable {
    case endNotAfterStart(DayBlock)
    case outsideWorkingHours(DayBlock, TimeSpan)
    case overlap(DayBlock, DayBlock)
    case workingHoursEndNotAfterStart
    /// Only lunch and breaks repeat every day.
    case notAFixedKind(DayBlock.Kind)
}

/// Where a new or edited block would land.
public enum DayBlockCheck: Hashable, Sendable {
    case fits
    /// It lands on fixed blocks such as lunch. The owner may place it there
    /// anyway, but only after confirming.
    case overlapsFixed([DayBlock])
    case invalid(DayPlanProblem)
}

/// The rules every day plan follows, as pure functions so the timeline,
/// Settings and storage agree: a block ends after it starts, lies within
/// working hours, and overlaps no other block except a fixed one the owner
/// confirmed. Blocks that only touch do not overlap.
public enum DayPlanRules {
    /// Checks `block` placed among `blocks`. When `block` has an ID, the
    /// stored block with that ID is the one being moved and is left out.
    public static func check(_ block: DayBlock, among blocks: [DayBlock], workingHours: TimeSpan) -> DayBlockCheck {
        if let problem = problem(of: block, workingHours: workingHours) {
            return .invalid(problem)
        }
        let overlapping = blocks.filter { (block.id == nil || $0.id != block.id) && $0.span.overlaps(block.span) }
        if let ordinary = overlapping.first(where: { !$0.isFixed }) {
            return .invalid(.overlap(block, ordinary))
        }
        return overlapping.isEmpty ? .fits : .overlapsFixed(overlapping)
    }

    /// Every problem in a whole plan, in block order. An ordinary block on a
    /// fixed one is not a problem: the owner confirmed it when placing it.
    public static func problems(in plan: DayPlan) -> [DayPlanProblem] {
        problems(in: plan.blocks, workingHours: plan.workingHours)
    }

    public static func problems(in blocks: [DayBlock], workingHours: TimeSpan) -> [DayPlanProblem] {
        var problems = blocks.compactMap { problem(of: $0, workingHours: workingHours) }
        for (index, block) in blocks.enumerated() {
            for later in blocks[(index + 1)...] where block.isFixed == later.isFixed && block.span.overlaps(later.span) {
                problems.append(.overlap(block, later))
            }
        }
        return problems
    }

    private static func problem(of block: DayBlock, workingHours: TimeSpan) -> DayPlanProblem? {
        if block.end <= block.start { return .endNotAfterStart(block) }
        if !workingHours.contains(block.span) { return .outsideWorkingHours(block, workingHours) }
        return nil
    }
}

public enum DayPlanText {
    /// "Lunch 12:00–13:00".
    public static func name(_ block: DayBlock, in plan: DayPlan? = nil) -> String {
        "\(plan?.title(of: block) ?? block.kind.title) \(times(block.span))"
    }

    /// "12:00–13:00".
    public static func times(_ span: TimeSpan) -> String {
        "\(span.start)–\(span.end)"
    }

    public static func message(_ problem: DayPlanProblem, in plan: DayPlan? = nil) -> String {
        switch problem {
        case .endNotAfterStart: "A block has to end after it starts."
        case .outsideWorkingHours(let block, let hours):
            "\(name(block, in: plan)) is outside your working hours (\(times(hours)))."
        case .overlap(let block, let other): "\(name(block, in: plan)) overlaps \(name(other, in: plan))."
        case .workingHoursEndNotAfterStart: "Working hours have to end after they start."
        case .notAFixedKind(let kind): "\(kind.title) can't repeat every day. Use lunch or a break."
        }
    }

    /// The question asked before a block lands on fixed blocks.
    public static func confirmation(_ overlapping: [DayBlock]) -> String {
        let names = overlapping.map { name($0) }.formatted(.list(type: .and))
        return "This overlaps \(names). Place it anyway?"
    }
}
