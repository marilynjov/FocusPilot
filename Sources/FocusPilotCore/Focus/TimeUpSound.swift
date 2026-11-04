import Foundation

/// The short sound for time running out (owner request, 2026-11-03):
/// notifications are provisional, so they are quiet, and an owner in
/// another app would otherwise get no sign.
///
/// It sounds for the same events as the notices `sessionReachedPlannedEnd`,
/// `breakEnded`, `quickTimerAlmostUp` and `quickTimerUp`, read from two
/// snapshots in a row, so each event sounds once however many surfaces show
/// it. Ends older than `freshness` are no longer news: a launch or wake into
/// a session that ended long ago is silent, as the raccoon is.
public enum TimeUpSound: Int, Comparable, Sendable {
    /// Soft: the end warning and a quick timer's 2 minutes left.
    case soon
    /// Normal: a session, a break or a quick timer is up.
    case up

    public static let freshness: TimeInterval = 60

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The sound due going from `old` to `new` at `now`, the louder one if
    /// both are.
    public static func due(from old: FocusSnapshot, to new: FocusSnapshot, at now: Date) -> TimeUpSound? {
        [session(from: old.session, to: new.session, at: now),
         quickTimer(from: old.quickTimer, to: new.quickTimer, at: now)].compactMap(\.self).max()
    }

    private static func session(from old: FocusSession?, to new: FocusSession?, at now: Date) -> TimeUpSound? {
        guard let old, !old.hasEnded else { return nil }
        guard let new, new.id == old.id else {
            // The next plan block started at once: its predecessor's end
            // still counts, if that is what happened.
            return isFresh(old.plannedEnd, now) ? .up : nil
        }
        switch new.phase {
        case .ended(let at, .reachedPlannedEnd):
            return isFresh(at, now) ? .up : nil
        case .running, .paused:
            // A break that ran out, not one the owner ended early.
            guard case .onBreak(let until, _) = old.phase else { return nil }
            return isFresh(until, now) ? .up : nil
        case .onBreak, .ended:
            return nil
        }
    }

    private static func quickTimer(from old: QuickTimer?, to new: QuickTimer?, at now: Date) -> TimeUpSound? {
        guard let old, let new, old.id == new.id, new.notified > old.notified else { return nil }
        switch new.notified {
        case .up: return new.outcome != .expired && isFresh(new.plannedEnd, now) ? .up : nil
        case .almostUp: return .soon
        case .none: return nil
        }
    }

    private static func isFresh(_ instant: Date, _ now: Date) -> Bool {
        let age = now.timeIntervalSince(instant)
        return age >= 0 && age <= freshness
    }
}
