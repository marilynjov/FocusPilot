import Foundation

/// Something the raccoon peeks in for (D12, decision 0004): the peek, how
/// long it stays, and an identity, so each moment shows once.
public struct RaccoonMoment: Equatable, Sendable {
    /// Lowest priority first: when several are due the last one shows, and
    /// a peek on screen gives way only to a later kind.
    public enum Kind: Int, CaseIterable, Comparable, Hashable, Sendable {
        case nextBlock, blockedVisit, breakSoon, quickTimerWarning, endWarning, breakOver, breakStarted, breakEnding,
             finished,
             quickTimerUp, timesUp

        public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// A kind and what it is about: a session, a break, a block or a visit.
    public struct ID: Hashable, Sendable {
        public var kind: Kind
        public var key: String

        public init(_ kind: Kind, _ key: String) {
            self.kind = kind
            self.key = key
        }
    }

    public var id: ID
    public var peek: RaccoonPeek
    public var duration: TimeInterval
    /// The session the moment is about; the app withdraws it once another
    /// session is the latest, so "Keep going" never acts on the wrong one.
    public var sessionID: UUID?

    public var kind: Kind { id.kind }

    /// Without a `duration`, a peek stays 8 seconds, or 20 with buttons,
    /// so there is time to choose.
    public init(id: ID, peek: RaccoonPeek, duration: TimeInterval? = nil, sessionID: UUID? = nil) {
        self.id = id
        self.peek = peek
        self.duration = duration ?? (peek.actions.isEmpty ? RaccoonMoments.peekDuration : RaccoonMoments.choiceDuration)
        self.sessionID = sessionID
    }
}

/// Which moment the raccoon peeks in for, as a pure function of the latest
/// session, today's plan and its runs, the last blocked visit, what was
/// already shown and the instant (D12, owner request 2026-11-02).
///
/// Every message encourages and none shames. Each moment shows once
/// (`shown`); a cheer after a blocked visit waits `blockedCooldown` after
/// the last one. Ends and visits older than `freshness` are no longer news,
/// so waking the Mac long after a session ended shows nothing. Nothing
/// warns while paused, and nothing shows in Off mode.
public enum RaccoonMoments {
    /// How long a peek stays unless a moment says otherwise.
    public static let peekDuration: TimeInterval = 8
    /// A peek with buttons.
    public static let choiceDuration: TimeInterval = 20
    /// "Nice work!" and "You got this".
    public static let cheerDuration: TimeInterval = 6
    /// "Time's up!" stays up to a minute, or until a button is pressed.
    public static let timesUpDuration: TimeInterval = 60
    /// What "+10 min" and "Keep going" add.
    public static let extraMinutes = 10
    /// The break the end warning offers (owner request, 2026-11-03).
    public static let warningBreakMinutes = 5
    /// What "Take a Break" offers.
    public static let breakChoices = [5, 10, 15]

    /// A break the owner took that ran out, as the app saw it end.
    public struct EndedBreak: Equatable, Sendable {
        public var sessionID: UUID
        public var until: Date

        public init(sessionID: UUID, until: Date) {
            self.sessionID = sessionID
            self.until = until
        }
    }
    public static let blockedCooldown: TimeInterval = 10 * 60

    /// The end warning comes 10 minutes before the end, or 2 minutes before
    /// it for a session planned shorter than 15 minutes (owner request,
    /// 2026-11-02: a 15-minute task is warned after 5 minutes).
    static let warning: TimeInterval = 10 * 60
    static let shortWarning: TimeInterval = 2 * 60
    static let shortSession: TimeInterval = 15 * 60
    /// Closer to the end than this, a warning is no use: time's up is next.
    static let warningTooLate: TimeInterval = 30
    static let breakNotice: TimeInterval = 2 * 60
    /// "1 minute left of your break" (owner request, 2026-11-03).
    static let breakEndingNotice: TimeInterval = 60
    /// Closer to a break's end than this, its reminder is no use.
    static let breakEndingTooLate: TimeInterval = 10
    static let nextBlockNotice: TimeInterval = 10 * 60
    static let freshness: TimeInterval = 60
    static let timesUpPose = "playbow"

    /// After "+10 min" or "Keep going", the raccoon looks tired for a moment
    /// before it goes back to work (owner request, 2026-11-02).
    public static func moreTime(minutes: Int) -> RaccoonPeek {
        RaccoonPeek(poseID: "lying", message: "\(minutes) more minutes. You’ve got this.")
    }
    public static let moreTimeDuration: TimeInterval = 10

    /// When the next time-based moment falls due after `now`: the end
    /// warning, a break coming up, or the next block coming up. The app
    /// looks again then, so a moment shows on time instead of up to a
    /// polling interval late. Nil when none is ahead.
    public static func nextDue(session: FocusSession?, quickTimer: QuickTimer? = nil, plan: DayPlan?, runs: [PlanRun],
                               at now: Date, timeZone: TimeZone) -> Date? {
        var times: [Date] = []
        if let quickTimer, quickTimer.isRunning {
            times += [quickTimer.plannedEnd.addingTimeInterval(-QuickTimer.warning), quickTimer.plannedEnd]
        }
        if let session, case .onBreak(let until, _) = session.phase {
            times += [until.addingTimeInterval(-breakEndingNotice), until]
        }
        if let session, session.phase == .running {
            let length = session.plannedEnd.timeIntervalSince(session.startedAt)
            let threshold = length < shortSession ? shortWarning : warning
            if length > threshold { times.append(session.plannedEnd.addingTimeInterval(-threshold)) }
            if let plan, let (block, _) = plannedBlock(of: session, plan: plan, runs: runs, timeZone: timeZone) {
                times += block.breaks.map { $0.start.addingTimeInterval(-breakNotice) }
                times += block.breaks.map(\.start)
            }
        }
        if session?.hasEnded != false, let plan, plan.state == .approved {
            let ran = Set(runs.map(\.blockID))
            for block in PlanSessions.sessions(in: plan, timeZone: timeZone) where !ran.contains(block.blockID) {
                times.append(block.start.addingTimeInterval(-nextBlockNotice))
            }
        }
        return times.filter { $0 > now }.min()
    }

    /// The moment to show now, if any. `session` is the latest one, which
    /// may have ended; `extended` is the time "+10 min" has added to it;
    /// `endedBreak` is the last owner break that ran out; `quickTimer` is
    /// the quick timer still running, if any; `shown` maps each moment shown
    /// to when it was.
    public static func next(mode: RaccoonCompanionMode, session: FocusSession?, extended: TimeInterval = 0,
                            endedBreak: EndedBreak? = nil, quickTimer: QuickTimer? = nil, plan: DayPlan?,
                            runs: [PlanRun], blockedVisitAt: Date?, shown: [RaccoonMoment.ID: Date], at now: Date,
                            timeZone: TimeZone, locale: Locale = .autoupdatingCurrent) -> RaccoonMoment? {
        guard mode != .off else { return nil }
        var due: [RaccoonMoment] = []
        if let quickTimer, let moment = quickTimerMoment(quickTimer, at: now) {
            due.append(moment)
        }
        if let session {
            due += sessionMoments(session, extended: extended, plan: plan, runs: runs, at: now, timeZone: timeZone)
        }
        if let session, let moment = breakOver(endedBreak, session: session, at: now) {
            due.append(moment)
        }
        if session?.hasEnded != false, let plan,
           let moment = nextBlock(plan, runs: runs, at: now, timeZone: timeZone, locale: locale) {
            due.append(moment)
        }
        if let moment = blockedVisit(at: blockedVisitAt, shown: shown, now: now) {
            due.append(moment)
        }
        return due.filter { shown[$0.id] == nil }.max { $0.kind < $1.kind }
    }

    /// Whether the session is on a break that is the plan's lunch, so the
    /// raccoon naps through it.
    public static func isOnLunch(_ session: FocusSession?, plan: DayPlan?, runs: [PlanRun], at now: Date,
                                 timeZone: TimeZone) -> Bool {
        guard let session, case .onBreak(_, false) = session.phase, let plan,
              let current = currentBreak(of: session, plan: plan, runs: runs, at: now, timeZone: timeZone)
        else { return false }
        return isLunch(current, in: plan)
    }

    /// With no session under way, the break or lunch of an approved plan
    /// the clock is in, if any, so the raccoon has coffee or naps between
    /// task blocks too. Only fixed breaks and lunch count, as inside blocks.
    public static func planBreak(_ plan: DayPlan?, at now: Date, timeZone: TimeZone) -> RaccoonActivity? {
        guard let plan, plan.state == .approved else { return nil }
        let block = plan.blocks.first { block in
            guard block.isFixed, block.kind == .break || block.kind == .lunch else { return false }
            return PlanSessions.instant(block.start, on: plan.date, in: timeZone) <= now
                && now < PlanSessions.instant(block.end, on: plan.date, in: timeZone)
        }
        return block.map { $0.kind == .lunch ? .onLunch : .onBreak }
    }

    // MARK: Moments

    private static func sessionMoments(_ session: FocusSession, extended: TimeInterval, plan: DayPlan?, runs: [PlanRun],
                                       at now: Date, timeZone: TimeZone) -> [RaccoonMoment] {
        let id = session.id.uuidString
        switch session.phase {
        case .ended(let at, let reason):
            let age = now.timeIntervalSince(at)
            guard age >= 0, age <= freshness else { return [] }
            switch reason {
            case .completed:
                return [RaccoonMoment(id: .init(.finished, id), peek: RaccoonPeek(poseID: "excited", message: "Nice work!"),
                                      duration: cheerDuration, sessionID: session.id)]
            case .reachedPlannedEnd:
                // A plan block starting now takes over at once; there is no
                // time to keep going on this one.
                if let plan, case .startSession = PlanSessions.step(plan: plan, runs: runs, session: session, at: now,
                                                                   timeZone: timeZone) {
                    return []
                }
                // Its own pose, so time's up is told apart from "Nice work!"
                // after Complete (owner request, 2026-11-02).
                let peek = RaccoonPeek(poseID: timesUpPose, message: "Time's up! Nice work.",
                                       actions: [.keepGoing(minutes: extraMinutes), .done])
                return [RaccoonMoment(id: .init(.timesUp, id), peek: peek, duration: timesUpDuration, sessionID: session.id)]
            }
        case .onBreak(let until, let movesEnd):
            // A break the owner took is never the plan's, even inside one.
            let current = movesEnd ? nil
                : plan.flatMap { currentBreak(of: session, plan: $0, runs: runs, at: now, timeZone: timeZone) }
            let key = "\(id)-\(current.map { String($0.blockID) } ?? String(until.timeIntervalSinceReferenceDate))"
            let lunch = if let current, let plan { isLunch(current, in: plan) } else { false }
            let peek = lunch ? RaccoonPeek(poseID: RaccoonPresence.lunchPose, message: "Lunch time")
                : RaccoonPeek(poseID: RaccoonPresence.breakPose, message: "Enjoy your break", actions: [.backToTask])
            // In its last minute a break is ending, not starting.
            let left = until.timeIntervalSince(now)
            guard left <= breakEndingNotice else {
                return [RaccoonMoment(id: .init(.breakStarted, key), peek: peek, sessionID: session.id)]
            }
            var moments: [RaccoonMoment] = []
            // A minute before any break ends, owner's or plan's, once.
            if left > breakEndingTooLate {
                let ending = RaccoonPeek(poseID: lunch ? RaccoonPresence.lunchPose : RaccoonPresence.breakPose,
                                         message: "1 minute left of your break", actions: [.backToTask])
                moments.append(RaccoonMoment(id: .init(.breakEnding, "\(id)-\(until.timeIntervalSinceReferenceDate)"),
                                             peek: ending, sessionID: session.id))
            }
            return moments
        case .running:
            var moments: [RaccoonMoment] = []
            let length = session.plannedEnd.timeIntervalSince(session.startedAt)
            let threshold = length < shortSession ? shortWarning : warning
            let remaining = session.remaining(at: now)
            if length > threshold, remaining <= threshold, remaining > warningTooLate {
                let peek = RaccoonPeek(poseID: "peek", message: "\(minutes(remaining)) left",
                                       actions: [.gotIt, .extend(minutes: extraMinutes),
                                                 .takeBreak(minutes: warningBreakMinutes)])
                // Once per end: "+10 min" makes a new end, warned again
                // before it. A pause also moves the planned end, but leaves
                // the time left as it was, so it must not warn again;
                // keying on the time added tells the two apart.
                let key = "\(id)-\(Int(extended))"
                moments.append(RaccoonMoment(id: .init(.endWarning, key), peek: peek, sessionID: session.id))
            }
            if let plan, let (block, run) = plannedBlock(of: session, plan: plan, runs: runs, timeZone: timeZone),
               let soon = block.breaks.first(where: { planned in
                   let wait = planned.start.timeIntervalSince(now)
                   return wait > 0 && wait <= breakNotice && !run.breaksStarted.contains(planned.blockID)
               }) {
                let peek = RaccoonPeek(poseID: "walk", message: "Break in \(minutes(soon.start.timeIntervalSince(now)))",
                                       actions: [.gotIt])
                moments.append(RaccoonMoment(id: .init(.breakSoon, "\(id)-\(soon.blockID)"), peek: peek,
                                             sessionID: session.id))
            }
            return moments
        case .paused:
            return []
        }
    }

    /// A quick timer (D2): "2 minutes left" as its notice says, then
    /// "Time's up!" for the first minute after its end, once per timer.
    private static func quickTimerMoment(_ timer: QuickTimer, at now: Date) -> RaccoonMoment? {
        guard timer.isRunning else { return nil }
        let remaining = timer.remaining(at: now)
        let key = String(timer.id)
        if remaining <= 0 {
            guard -remaining <= freshness else { return nil }
            let peek = RaccoonPeek(poseID: timesUpPose, message: "Time's up!", actions: [.gotIt])
            return RaccoonMoment(id: .init(.quickTimerUp, key), peek: peek)
        }
        guard timer.plannedLength > QuickTimer.warning, remaining <= QuickTimer.warning, remaining > warningTooLate
        else { return nil }
        let peek = RaccoonPeek(poseID: "peek", message: "2 minutes left", actions: [.gotIt])
        return RaccoonMoment(id: .init(.quickTimerWarning, key), peek: peek)
    }

    /// "Break's over" once, when a break the owner took ran out and the
    /// session runs again. Ended early with Back to Task, it was the owner's
    /// own choice, so the app reports no ended break.
    private static func breakOver(_ ended: EndedBreak?, session: FocusSession, at now: Date) -> RaccoonMoment? {
        guard let ended, ended.sessionID == session.id, session.phase == .running else { return nil }
        let age = now.timeIntervalSince(ended.until)
        guard age >= 0, age <= freshness else { return nil }
        let peek = RaccoonPeek(poseID: "backpack", message: "Break's over. Back to it!", actions: [.gotIt])
        return RaccoonMoment(id: .init(.breakOver, "\(session.id.uuidString)-\(ended.until.timeIntervalSinceReferenceDate)"),
                             peek: peek, sessionID: session.id)
    }

    /// The next task block of an approved plan, starting within 10 minutes,
    /// while no session is under way.
    private static func nextBlock(_ plan: DayPlan, runs: [PlanRun], at now: Date, timeZone: TimeZone,
                                  locale: Locale) -> RaccoonMoment? {
        let ran = Set(runs.map(\.blockID))
        guard let block = PlanSessions.sessions(in: plan, timeZone: timeZone).first(where: {
            let wait = $0.start.timeIntervalSince(now)
            return wait > 0 && wait <= nextBlockNotice && !ran.contains($0.blockID)
        }) else { return nil }
        let time = block.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale,
                                                          timeZone: timeZone))
        let peek = RaccoonPeek(poseID: "backpack", message: "Next: \(block.title) at \(time)", actions: [.gotIt])
        return RaccoonMoment(id: .init(.nextBlock, String(block.blockID)), peek: peek)
    }

    /// "You got this" for a blocked app hidden or Chrome's blocked page,
    /// at most once every `blockedCooldown`.
    private static func blockedVisit(at visit: Date?, shown: [RaccoonMoment.ID: Date], now: Date) -> RaccoonMoment? {
        guard let visit else { return nil }
        let age = now.timeIntervalSince(visit)
        guard age >= 0, age <= freshness else { return nil }
        if let last = shown.filter({ $0.key.kind == .blockedVisit }).values.max(),
           visit <= last || now.timeIntervalSince(last) < blockedCooldown {
            return nil
        }
        return RaccoonMoment(id: .init(.blockedVisit, String(visit.timeIntervalSinceReferenceDate)),
                             peek: RaccoonPeek(poseID: "sign", message: "You got this"), duration: cheerDuration)
    }

    // MARK: Plan

    private static func plannedBlock(of session: FocusSession, plan: DayPlan, runs: [PlanRun],
                                     timeZone: TimeZone) -> (PlannedSession, PlanRun)? {
        guard let run = runs.first(where: { $0.sessionID == session.id }),
              let block = PlanSessions.sessions(in: plan, timeZone: timeZone).first(where: { $0.blockID == run.blockID })
        else { return nil }
        return (block, run)
    }

    private static func currentBreak(of session: FocusSession, plan: DayPlan, runs: [PlanRun], at now: Date,
                                     timeZone: TimeZone) -> PlannedBreak? {
        plannedBlock(of: session, plan: plan, runs: runs, timeZone: timeZone)?.0.breaks
            .first { $0.start <= now && now < $0.end }
    }

    private static func isLunch(_ planned: PlannedBreak, in plan: DayPlan) -> Bool {
        plan.blocks.first { $0.id == planned.blockID }?.kind == .lunch
    }

    /// Whole minutes, rounded up: "10 minutes", "1 minute".
    static func minutes(_ interval: TimeInterval) -> String {
        let count = max(1, Int((interval / 60).rounded(.up)))
        return count == 1 ? "1 minute" : "\(count) minutes"
    }
}
