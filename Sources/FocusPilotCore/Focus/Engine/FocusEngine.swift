import Foundation

/// The deterministic focus engine: a pure function of the current session, an
/// event and the current instant. It performs no I/O and never reads the
/// system clock; the coordinator supplies `now` and performs the effects.
public enum FocusEngine {
    public static func handle(
        _ event: FocusEvent, session: FocusSession?, at now: Date
    ) throws(FocusEngineError) -> FocusTransition {
        if case .start(let request) = event {
            return try start(request, replacing: session, at: now)
        }
        if event == .reconcile {
            return reconcile(session, at: now)
        }
        guard let persisted = session, !persisted.hasEnded else { throw .noActiveSession }
        // Owner commands act on the session as it stands now, so deadlines the
        // coordinator has not applied yet are applied first.
        var session = elapse(persisted, until: now).0
        if session.hasEnded {
            // Completing after the planned end records the planned end; any
            // other command has no session left to act on.
            guard event == .complete else { throw .noActiveSession }
            return reconcile(persisted, at: now)
        }

        // A pause stops the countdown (owner decision, 2026-11-02): resuming
        // moves the planned end later by the pause. So does a break the owner
        // takes (2026-11-03): it moves the end later by its length, and ending
        // it early gives back the part not taken. Plan breaks come from the
        // day plan, which already set their time aside, so they move nothing.
        switch (event, session.phase) {
        case (.pause, .running):
            session.phase = .paused(since: now)
        case (.resume, .paused(let since)):
            session.plannedEnd += now.timeIntervalSince(since)
            session.phase = .running
        case (.startBreak(let duration, let movesEnd), .running):
            guard duration > 0 else { throw .nonPositiveDuration }
            session.phase = .onBreak(until: now.addingTimeInterval(duration), movesEnd: movesEnd)
            if movesEnd { session.plannedEnd += duration }
        case (.endBreak, .onBreak(let until, let movesEnd)):
            if movesEnd {
                session.plannedEnd = max(now, session.plannedEnd - max(0, until.timeIntervalSince(now)))
            }
            session.phase = .running
        case (.extend(let interval), .running), (.extend(let interval), .paused), (.extend(let interval), .onBreak):
            guard interval > 0 else { throw .nonPositiveDuration }
            session.plannedEnd += interval
        case (.endBreak, .running) where persisted.phase != session.phase:
            // The break ran out before the owner ended it; report that instead.
            return reconcile(persisted, at: now)
        case (.complete, _):
            session.phase = .ended(at: now, reason: .completed)
        default:
            throw .notAllowed(event, in: session.phase)
        }
        return changed(to: session)
    }

    private static func start(
        _ request: SessionRequest, replacing current: FocusSession?, at now: Date
    ) throws(FocusEngineError) -> FocusTransition {
        if let current, !current.hasEnded { throw .sessionAlreadyActive }
        guard request.duration > 0 else { throw .nonPositiveDuration }
        let started = FocusSession(
            id: request.id, taskID: request.taskID, action: request.action, mode: request.mode,
            startedAt: now, plannedEnd: now.addingTimeInterval(request.duration), phase: .running
        )
        return changed(to: started)
    }

    private static func reconcile(_ session: FocusSession?, at now: Date) -> FocusTransition {
        guard let session else { return FocusTransition(session: nil, effects: [.publishPolicy(nil)]) }
        let (elapsed, notices) = elapse(session, until: now)
        // Republished even when unchanged: after launch or wake the extensions
        // may hold a stale policy, and a strict session waits for this confirmation.
        var effects: [FocusEffect] = elapsed == session ? [] : [.persist(elapsed)]
        effects.append(.publishPolicy(policy(for: elapsed)))
        effects += notices.map(FocusEffect.notify)
        return FocusTransition(session: elapsed, effects: effects)
    }

    /// Applies, in time order, every deadline between the session's last
    /// state and `now`.
    ///
    /// Ends are recorded at the planned instant, not at `now`, so a Mac that
    /// slept through the end does not stretch the session. Once the session
    /// has ended, earlier notices (a break running out) are no longer news.
    private static func elapse(_ session: FocusSession, until now: Date) -> (FocusSession, [FocusNotice]) {
        var session = session
        var notices: [FocusNotice] = []
        while let deadline = session.nextDeadline, deadline <= now {
            if deadline >= session.plannedEnd {
                session.phase = .ended(at: session.plannedEnd, reason: .reachedPlannedEnd)
                return (session, [.sessionReachedPlannedEnd])
            }
            // Until exceptions (#14) add deadlines, only a break ends earlier.
            session.phase = .running
            notices.append(.breakEnded)
        }
        return (session, notices)
    }

    private static func changed(to session: FocusSession) -> FocusTransition {
        FocusTransition(session: session, effects: [.persist(session), .publishPolicy(policy(for: session))])
    }

    /// Session rules apply while the session runs. Strict sessions keep them
    /// through pauses and breaks (owner decision, 2026-10-14). Normal sessions
    /// lift them: a break carries its end so extensions resume blocking alone,
    /// while a pause has no end and publishes no session rules.
    static func policy(for session: FocusSession) -> SessionPolicy? {
        let resumesAt: Date?
        switch (session.phase, session.mode) {
        case (.running, _), (.paused, .strict), (.onBreak, .strict): resumesAt = nil
        case (.onBreak(let until, _), .normal): resumesAt = until
        case (.paused, .normal), (.ended, _): return nil
        }
        let pausedSince: Date? = if case .paused(let since) = session.phase { since } else { nil }
        return SessionPolicy(sessionID: session.id, mode: session.mode, end: session.plannedEnd, resumesAt: resumesAt,
                             pausedSince: pausedSince)
    }
}
