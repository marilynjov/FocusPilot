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
    /// An ordinary block lands on fixed blocks such as lunch, or a fixed
    /// block moved for one day lands on ordinary ones. Allowed, but only
    /// once the owner confirms.
    case needsConfirmation([DayBlock])
    case invalid(DayPlanProblem)
}

/// The rules every day plan follows, as pure functions so the timeline,
/// Settings and storage agree: a block ends after it starts, lies within
/// working hours, and overlaps no other block, except that an ordinary block
/// and a fixed one may overlap once the owner confirms. Blocks that only
/// touch do not overlap.
public enum DayPlanRules {
    /// Checks `block` placed among `blocks`. When `block` has an ID, the
    /// stored block with that ID is the one being moved and is left out.
    public static func check(_ block: DayBlock, among blocks: [DayBlock], workingHours: TimeSpan) -> DayBlockCheck {
        if let problem = problem(of: block, workingHours: workingHours) {
            return .invalid(problem)
        }
        let overlapping = blocks.filter { (block.id == nil || $0.id != block.id) && $0.span.overlaps(block.span) }
        if let sameKind = overlapping.first(where: { $0.isFixed == block.isFixed }) {
            return .invalid(.overlap(block, sameKind))
        }
        return overlapping.isEmpty ? .fits : .needsConfirmation(overlapping)
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

/// Day plan text. Times follow the Mac's 12- or 24-hour clock setting
/// through `locale` ("9:00 AM" or "09:00"); tests pass a fixed locale.
public enum DayPlanText {
    /// "Lunch 12:00 PM–1:00 PM".
    public static func name(_ block: DayBlock, in plan: DayPlan? = nil, locale: Locale = .autoupdatingCurrent) -> String {
        "\(plan?.title(of: block) ?? block.kind.title) \(times(block.span, locale: locale))"
    }

    /// "12:00 PM–1:00 PM".
    public static func times(_ span: TimeSpan, locale: Locale = .autoupdatingCurrent) -> String {
        "\(time(span.start, locale: locale))–\(time(span.end, locale: locale))"
    }

    public static func time(_ time: ClockTime, locale: Locale = .autoupdatingCurrent) -> String {
        self.time(minutesAfterMidnight: time.minutes, locale: locale)
    }

    /// Also takes 1440, the midnight that ends the day, for timeline labels.
    public static func time(minutesAfterMidnight minutes: Int, locale: Locale = .autoupdatingCurrent) -> String {
        // Wall-clock formatting only: a day in GMT has no DST gap to skip a time.
        let instant = Date(timeIntervalSinceReferenceDate: TimeInterval(minutes * 60))
        return instant.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                           calendar: .gregorian(in: .gmt), timeZone: .gmt))
    }

    public static func message(_ problem: DayPlanProblem, in plan: DayPlan? = nil,
                               locale: Locale = .autoupdatingCurrent) -> String {
        switch problem {
        case .endNotAfterStart: "A block has to end after it starts."
        case .outsideWorkingHours(let block, let hours):
            "\(name(block, in: plan, locale: locale)) is outside your working hours (\(times(hours, locale: locale)))."
        case .overlap(let block, let other):
            "\(name(block, in: plan, locale: locale)) overlaps \(name(other, in: plan, locale: locale))."
        case .workingHoursEndNotAfterStart: "Working hours have to end after they start."
        case .notAFixedKind(let kind): "\(kind.title) can't repeat every day. Use lunch or a break."
        }
    }

    public static func message(_ error: DayPlanError, in plan: DayPlan? = nil) -> String {
        switch error {
        case .planNotFound: "This day’s plan wasn’t found. Open Today’s plan again."
        case .blockNotFound: "That block is no longer in the plan."
        case .taskNotFound: "That task no longer exists. Pick another one."
        case .invalid(let problem): message(problem, in: plan)
        }
    }

    /// The question asked before blocks overlap across the fixed line.
    public static func confirmation(_ overlapping: [DayBlock], in plan: DayPlan? = nil,
                                    locale: Locale = .autoupdatingCurrent) -> String {
        let names = overlapping.map { name($0, in: plan, locale: locale) }.formatted(.list(type: .and).locale(locale))
        return "This overlaps \(names). Place it anyway?"
    }
}
