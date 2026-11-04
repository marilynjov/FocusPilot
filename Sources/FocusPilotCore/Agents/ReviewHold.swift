import Foundation

/// Results from reported agents wait for the next break while a day plan
/// block is running (D8, decision 0004): they are in the Review queue but
/// not shown or counted until the block breaks, pauses for a break or ends.
/// "Needs you" is not held; it comes at once (owner, 2026-11-03).
public enum ReviewHold {
    /// `planSession` is whether the session runs a block of today's plan.
    public static func isHeld(_ item: ReviewItem, session: FocusSession?, planSession: Bool) -> Bool {
        guard item.reportedAgentID != nil || item.source != nil, planSession, let session else { return false }
        switch session.phase {
        case .running, .paused: return item.occurredAt >= session.startedAt
        case .onBreak, .ended: return false
        }
    }
}
