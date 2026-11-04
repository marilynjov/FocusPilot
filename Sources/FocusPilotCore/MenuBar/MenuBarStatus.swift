import Foundation

/// What the menu bar item shows for a snapshot at a given instant.
public struct MenuBarStatus: Equatable, Sendable {
    public var glyph: MenuBarGlyph
    /// Time left in the session, or `nil` when the owner keeps it hidden or
    /// no session is active.
    public var timeText: String?
    /// The logo design dims the time while paused; breaks share the paused glyph.
    public var isTimeDimmed: Bool
    public var accessibilityLabel: String

    /// With `reducesMotion` (Reduce Motion) the time reads in whole minutes,
    /// "25 min", so it changes once a minute instead of every second.
    public init(snapshot: FocusSnapshot, now: Date, showsTime: Bool, reducesMotion: Bool = false) {
        let session = snapshot.activeSession
        glyph = Self.glyph(phase: session?.phase, isObserveOnly: snapshot.isObserveOnly)
        timeText = session.flatMap { session in
            guard showsTime else { return nil }
            let remaining = session.remaining(at: now)
            return reducesMotion ? "\(Int((max(0, remaining) / 60).rounded(.up))) min" : Self.format(remaining: remaining)
        }
        isTimeDimmed = glyph == .paused

        let state = Self.spokenState(phase: session?.phase, isObserveOnly: snapshot.isObserveOnly, status: snapshot.statusText)
        accessibilityLabel = ["FocusPilot: \(state)", timeText.map { "\($0) left" }].compactMap(\.self).joined(separator: ", ")
    }

    /// A session's phase wins over observe-only: while a session is active the
    /// glyph says what the owner is doing, and protection health belongs in
    /// the menu, never in the glyph (logo design 2c).
    static func glyph(phase: SessionPhase?, isObserveOnly: Bool) -> MenuBarGlyph {
        switch phase {
        case .running: .focusing
        // A break is a planned pause; the design has no separate glyph for it.
        case .paused, .onBreak: .paused
        case .ended, nil: isObserveOnly ? .observing : .idle
        }
    }

    private static func spokenState(phase: SessionPhase?, isObserveOnly: Bool, status: String) -> String {
        switch phase {
        case .running: "Focusing on \(status)"
        case .paused: "Paused, \(status)"
        case .onBreak: "On a break, \(status)"
        case .ended, nil: isObserveOnly ? "Observe only, \(status)" : status
        }
    }

    /// `m:ss` under an hour, `h:mm:ss` from an hour on; never negative.
    static func format(remaining: TimeInterval) -> String {
        let total = max(0, Int(remaining.rounded(.down)))
        let (hours, minutes, seconds) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}
