import Foundation

/// A task block of an approved plan as instants: the focus session it runs
/// and the breaks inside it (lunch or a break the owner placed on it).
public struct PlannedSession: Hashable, Sendable {
    public var blockID: Int64
    public var taskID: Int64
    public var title: String
    public var start: Date
    public var end: Date
    /// Fixed blocks overlapping this one, cut to it, in start order.
    public var breaks: [PlannedBreak]
}

public struct PlannedBreak: Hashable, Sendable {
    public var blockID: Int64
    public var start: Date
    public var end: Date
}

/// What happened to one task block: the session it started and what the
/// owner said about it. Stored, so a block runs at most once even after a
/// relaunch, and kept as history for replanning (D10) and stats.
public struct PlanRun: Hashable, Sendable {
    public var blockID: Int64
    public var sessionID: UUID
    public var startedAt: Date
    /// The owner said "Done early": the block and its session ended then.
    public var endedEarlyAt: Date?
    /// The owner said "I need more time". Recorded only; replanning is D10.
    public var moreTimeRequestedAt: Date?
    /// Breaks inside the block already started as session breaks, so a break
    /// the owner ends early is not started again.
    public var breaksStarted: Set<Int64>

    public init(blockID: Int64, sessionID: UUID, startedAt: Date, endedEarlyAt: Date? = nil,
                moreTimeRequestedAt: Date? = nil, breaksStarted: Set<Int64> = []) {
        self.blockID = blockID
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedEarlyAt = endedEarlyAt
        self.moreTimeRequestedAt = moreTimeRequestedAt
        self.breaksStarted = breaksStarted
    }
}

/// What following the plan asks for next.
public enum PlanStep: Hashable, Sendable {
    /// Start a normal session for the block, ending at the block's end.
    case startSession(PlannedSession)
    /// The block's session reached a break inside the block: lift its
    /// session-only rules until the break's end.
    case startBreak(PlannedBreak, sessionID: UUID)
}

/// Following an approved day plan (D3, decision 0004), as pure functions of
/// the plan, its stored runs, the latest session, the instant and the time
/// zone. The coordinator performs the steps through `FocusEngine`, so plan
/// blocks are ordinary focus sessions.
///
/// - A task block runs once: a session starts when the clock is inside it,
///   no other session is active and it has no run yet, and ends at the
///   block's end. A block already over never starts, so catching up after a
///   launch starts only the block in progress, for the time left.
/// - Blocks without a task, and drafts, start nothing.
/// - Breaks and lunch between blocks have no session, so session-only rules
///   are lifted and always-on and scheduled rules keep blocking. A break
///   inside a task block becomes a session break, which lifts session-only
///   rules for a normal session (decision 0003, 2026-10-14).
public enum PlanSessions {
    /// The task blocks of `plan` as sessions, in start order; none for a draft.
    public static func sessions(in plan: DayPlan, timeZone: TimeZone) -> [PlannedSession] {
        guard plan.state == .approved else { return [] }
        let fixed = plan.blocks.filter { $0.isFixed && ($0.kind == .break || $0.kind == .lunch) }
        return plan.blocks.compactMap { block -> PlannedSession? in
            guard block.kind == .task, let blockID = block.id, let taskID = block.taskID else { return nil }
            let start = instant(block.start, on: plan.date, in: timeZone)
            let end = instant(block.end, on: plan.date, in: timeZone)
            // A block wholly inside a spring-forward gap does not happen that day.
            guard start < end else { return nil }
            let breaks = fixed.compactMap { other -> PlannedBreak? in
                guard let otherID = other.id else { return nil }
                let breakStart = max(start, instant(other.start, on: plan.date, in: timeZone))
                let breakEnd = min(end, instant(other.end, on: plan.date, in: timeZone))
                return breakStart < breakEnd ? PlannedBreak(blockID: otherID, start: breakStart, end: breakEnd) : nil
            }
            return PlannedSession(blockID: blockID, taskID: taskID, title: plan.title(of: block),
                                  start: start, end: end, breaks: breaks)
        }
    }

    /// The next step at `now`, or nil when the plan asks for nothing.
    public static func step(plan: DayPlan, runs: [PlanRun], session: FocusSession?, at now: Date,
                            timeZone: TimeZone) -> PlanStep? {
        let planned = sessions(in: plan, timeZone: timeZone)
        if let active = session, !active.hasEnded {
            // Only the block's own session takes its breaks; any other
            // session, strict or not, is left exactly as it is.
            guard active.phase == .running, let run = runs.first(where: { $0.sessionID == active.id }),
                  let block = planned.first(where: { $0.blockID == run.blockID }),
                  let due = block.breaks.first(where: { $0.start <= now && now < $0.end && !run.breaksStarted.contains($0.blockID) })
            else { return nil }
            return .startBreak(due, sessionID: active.id)
        }
        let ran = Set(runs.map(\.blockID))
        return planned.first { $0.start <= now && now < $0.end && !ran.contains($0.blockID) }.map(PlanStep.startSession)
    }

    /// When the plan may next ask for a step after `now`: the next block
    /// start or break start. The coordinator reconciles then.
    public static func nextDeadline(plan: DayPlan, runs: [PlanRun], at now: Date, timeZone: TimeZone) -> Date? {
        let ran = Dictionary(runs.map { ($0.blockID, $0) }, uniquingKeysWith: { first, _ in first })
        return sessions(in: plan, timeZone: timeZone).flatMap { block -> [Date] in
            guard let run = ran[block.blockID] else { return [block.start] }
            guard run.endedEarlyAt == nil else { return [] }
            return block.breaks.filter { !run.breaksStarted.contains($0.blockID) }.map(\.start)
        }
        .filter { $0 > now }.min()
    }

    /// The instant the wall clock in `timeZone` shows `time` on `date`.
    ///
    /// Daylight saving time makes this ambiguous twice a year: a time in the
    /// spring-forward gap does not exist, and becomes the instant the gap
    /// ends (02:30 becomes 03:00), so a block keeps its end and only loses
    /// the skipped part; a time in the autumn overlap happens twice, and the
    /// first one counts, so a block starts when the clock first shows its time.
    public static func instant(_ time: ClockTime, on date: LocalDate, in timeZone: TimeZone) -> Date {
        // The wall time read as if it were UTC.
        let wall = date.start(in: .gmt).addingTimeInterval(TimeInterval(time.minutes * 60))
        // Offsets around the wall time: one, or two across a transition.
        let offsets = Set([-86_400.0, 0, 86_400].map { timeZone.secondsFromGMT(for: wall.addingTimeInterval($0)) })
        let matches = offsets.map { wall.addingTimeInterval(-TimeInterval($0)) }
            .filter { timeZone.secondsFromGMT(for: $0) == Int(wall.timeIntervalSince($0)) }
        if let first = matches.min() { return first }
        // In the gap: the clock jumps past this time at the transition.
        let beforeGap = wall.addingTimeInterval(-TimeInterval(offsets.max()!))
        return timeZone.nextDaylightSavingTimeTransition(after: beforeGap)
            ?? wall.addingTimeInterval(-TimeInterval(offsets.min()!))
    }
}
