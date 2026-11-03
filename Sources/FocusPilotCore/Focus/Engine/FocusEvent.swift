import Foundation

/// What the owner asked for when starting a session.
///
/// The caller supplies the ID so the engine stays deterministic.
public struct SessionRequest: Equatable, Sendable {
    public var id: UUID
    public var taskID: Int64
    public var action: String
    public var mode: SessionMode
    public var duration: TimeInterval

    public init(id: UUID, taskID: Int64, action: String, mode: SessionMode, duration: TimeInterval) {
        self.id = id
        self.taskID = taskID
        self.action = action
        self.mode = mode
        self.duration = duration
    }
}

/// Everything that can move a focus session forward.
///
/// Exception grants (#14) will arrive as further cases; their expiries then
/// join `FocusSession.nextDeadline` and the published policy.
public enum FocusEvent: Equatable, Sendable {
    case start(SessionRequest)
    case pause
    case resume
    case startBreak(duration: TimeInterval)
    case endBreak
    /// "+10 min": moves the planned end later by the interval, while
    /// running, paused or on a break (owner request, 2026-11-02).
    case extend(by: TimeInterval)
    case complete
    /// Time passed: a timer fired, the Mac woke, or the app launched with a
    /// persisted session. Applies any deadline the clock has crossed.
    case reconcile
}
