import Foundation

/// How blocking behaves when the app cannot update the policy (owner decision,
/// 2026-10-13, ARCHITECTURE.md "Enforcement ownership").
public enum SessionMode: String, Codable, Sendable {
    /// Extensions stop blocking at the planned end on their own.
    case normal = "normal"
    /// Extensions keep blocking past the planned end until the app confirms the end.
    case strict = "strict"
}

/// Why a session stopped.
public enum EndReason: String, Codable, Sendable {
    case completed = "completed"
    case reachedPlannedEnd = "reachedPlannedEnd"
}

/// Persisted with explicit keys; see `SessionPhase+Codable.swift`.
public enum SessionPhase: Equatable, Sendable {
    case running
    case paused(since: Date)
    /// `movesEnd` marks a break the owner took ("Take a Break"), which
    /// stops the countdown; a plan break keeps the planned end.
    case onBreak(until: Date, movesEnd: Bool = false)
    case ended(at: Date, reason: EndReason)
}

/// A focus session as the engine sees it and the coordinator persists it.
///
/// Every time is an absolute instant, so a session restored after a crash or
/// sleep is judged against the wall clock rather than a timer that stopped.
public struct FocusSession: Codable, Equatable, Sendable {
    public var id: UUID
    public var taskID: Int64
    public var action: String
    public var mode: SessionMode
    public var startedAt: Date
    public var plannedEnd: Date
    public var phase: SessionPhase

    public init(
        id: UUID, taskID: Int64, action: String, mode: SessionMode,
        startedAt: Date, plannedEnd: Date, phase: SessionPhase
    ) {
        self.id = id
        self.taskID = taskID
        self.action = action
        self.mode = mode
        self.startedAt = startedAt
        self.plannedEnd = plannedEnd
        self.phase = phase
    }

    // Spelled out so renaming a property cannot silently change stored JSON.
    enum CodingKeys: String, CodingKey {
        case id, taskID, action, mode, startedAt, plannedEnd, phase
    }

    public var hasEnded: Bool {
        if case .ended = phase { true } else { false }
    }

    /// When the coordinator should next send `.reconcile`, or `nil` if nothing is pending.
    ///
    /// Exception expiries (#14) will join this as further deadlines.
    public var nextDeadline: Date? {
        switch phase {
        case .running: plannedEnd
        // The countdown is stopped: nothing is due until the owner resumes.
        case .paused: nil
        case .onBreak(let until, _): min(until, plannedEnd)
        case .ended: nil
        }
    }

    /// Focus time left at `now`. It stands still while paused, since
    /// resuming moves `plannedEnd` later (owner decision, 2026-11-02), and
    /// through a break the owner took, which already moved it later
    /// (2026-11-03). A plan break's time was set aside by the plan, so the
    /// countdown runs on through it.
    public func remaining(at now: Date) -> TimeInterval {
        switch phase {
        case .running: plannedEnd.timeIntervalSince(now)
        case .paused(let since): plannedEnd.timeIntervalSince(since)
        case .onBreak(let until, true): plannedEnd.timeIntervalSince(max(until, now))
        case .onBreak: plannedEnd.timeIntervalSince(now)
        case .ended: 0
        }
    }
}
