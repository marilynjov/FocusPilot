import Foundation

/// The owner's working hours and the blocks that repeat every day, such as
/// lunch. Stored in the owner database and copied into each new day's plan.
public struct DayPreferences: Hashable, Sendable {
    /// A block placed on every new day, such as lunch 12:00–13:00.
    public struct FixedBlock: Hashable, Sendable, Codable {
        public var kind: DayBlock.Kind
        public var start: ClockTime
        public var end: ClockTime

        public init(kind: DayBlock.Kind, start: ClockTime, end: ClockTime) {
            self.kind = kind
            self.start = start
            self.end = end
        }

        /// The kinds a fixed block can be; tasks and the wrap-up are planned per day.
        public static let kinds: [DayBlock.Kind] = [.lunch, .break]
    }

    public var workingHours: TimeSpan
    public var fixedBlocks: [FixedBlock]

    public init(workingHours: TimeSpan, fixedBlocks: [FixedBlock]) {
        self.workingHours = workingHours
        self.fixedBlocks = fixedBlocks
    }

    /// Until the owner changes them: 9:00 to 17:00, with lunch from 12:00 to 13:00.
    public static let standard = DayPreferences(
        workingHours: TimeSpan(ClockTime(9, 0), ClockTime(17, 0)),
        fixedBlocks: [FixedBlock(kind: .lunch, start: ClockTime(12, 0), end: ClockTime(13, 0))]
    )

    /// The blocks a new day starts with, in start order.
    public var dayBlocks: [DayBlock] {
        fixedBlocks.map { DayBlock(kind: $0.kind, start: $0.start, end: $0.end, isFixed: true) }
            .sorted { $0.start < $1.start }
    }

    /// The first reason these preferences cannot be saved, if any. Fixed
    /// blocks must lie within working hours and not overlap one another.
    public var problem: DayPlanProblem? {
        guard workingHours.start < workingHours.end else { return .workingHoursEndNotAfterStart }
        if let blockKind = fixedBlocks.first(where: { !Self.FixedBlock.kinds.contains($0.kind) })?.kind {
            return .notAFixedKind(blockKind)
        }
        // Checked as ordinary blocks, so overlaps between them count.
        let blocks = dayBlocks.map { DayBlock(kind: $0.kind, start: $0.start, end: $0.end) }
        return DayPlanRules.problems(in: blocks, workingHours: workingHours).first
    }
}
