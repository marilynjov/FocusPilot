import Foundation

/// A timer the owner starts by hand, "this won't take more than 20 minutes"
/// (D2, decision 0004). It is separate from the day plan and from focus
/// sessions: it changes no block rules. Its end is absolute, so sleeping
/// the Mac or closing the window does not move it, and each timer is kept
/// with its planned and actual length for stats (D6).
public struct QuickTimer: Equatable, Sendable, Identifiable {
    /// How a timer ended.
    public enum Outcome: String, Sendable {
        /// The owner pressed Finish: the thing was done.
        case finished
        /// The owner stopped it without finishing.
        case stopped
        /// Nobody finished or stopped it within `unattendedLimit` of its end.
        /// It is closed at that instant, so its actual length is only a lower
        /// bound, not the time the work took.
        case expired
    }

    /// The notices already delivered, in order; none is repeated.
    public enum Notified: Int, Comparable, Sendable {
        case none, almostUp, up

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Proposed presets (decision 0004).
    public static let presetMinutes = [10, 20, 30, 45]
    /// Lengths a custom timer may have.
    public static let minutesRange = 1...240
    /// The "2 minutes left" notice. A timer this short or shorter has none.
    public static let warning: TimeInterval = 2 * 60
    /// A timer still running this long after its end is closed as `expired`,
    /// so a timer forgotten overnight does not count as hours of work.
    public static let unattendedLimit: TimeInterval = 60 * 60

    public var id: Int64
    /// What it is for, if the owner said.
    public var label: String?
    public var startedAt: Date
    public var plannedEnd: Date
    public var endedAt: Date?
    public var outcome: Outcome?
    public var notified: Notified

    public init(id: Int64, label: String?, startedAt: Date, plannedEnd: Date, endedAt: Date? = nil,
                outcome: Outcome? = nil, notified: Notified = .none) {
        self.id = id
        self.label = label
        self.startedAt = startedAt
        self.plannedEnd = plannedEnd
        self.endedAt = endedAt
        self.outcome = outcome
        self.notified = notified
    }

    public var isRunning: Bool { endedAt == nil }

    public var plannedLength: TimeInterval { plannedEnd.timeIntervalSince(startedAt) }

    /// From start to Finish or Stop; `nil` while running and for an
    /// `expired` timer, whose real length nobody saw.
    public var actualLength: TimeInterval? {
        outcome == .expired ? nil : endedAt.map { $0.timeIntervalSince(startedAt) }
    }

    /// Time to the planned end; negative once it is past.
    public func remaining(at now: Date) -> TimeInterval {
        plannedEnd.timeIntervalSince(now)
    }

    /// When the timer next needs a reconcile: a notice or the unattended
    /// close. `nil` once it has ended.
    public var nextDeadline: Date? {
        guard isRunning else { return nil }
        if notified < .almostUp, plannedLength > Self.warning { return plannedEnd.addingTimeInterval(-Self.warning) }
        if notified < .up { return plannedEnd }
        return plannedEnd.addingTimeInterval(Self.unattendedLimit)
    }

    /// The timer at `now` and the notices due. After a sleep past the end,
    /// only the end is announced; "2 minutes left" is no longer news. Past
    /// the unattended limit the timer is closed with no notice at all:
    /// "Time's up" the next morning would be about something long over.
    public func reconciled(at now: Date) -> (QuickTimer, [FocusNotice]) {
        guard isRunning else { return (self, []) }
        var timer = self
        var notices: [FocusNotice] = []
        let cutoff = plannedEnd.addingTimeInterval(Self.unattendedLimit)
        if now >= cutoff {
            timer.notified = .up
            timer.endedAt = cutoff
            timer.outcome = .expired
        } else if now >= plannedEnd {
            if notified < .up { notices.append(.quickTimerUp(label: label)) }
            timer.notified = .up
        } else if notified < .almostUp, plannedLength > Self.warning, now >= plannedEnd.addingTimeInterval(-Self.warning) {
            notices.append(.quickTimerAlmostUp(label: label))
            timer.notified = .almostUp
        }
        return (timer, notices)
    }

    /// The label as stored: trimmed, and `nil` when empty.
    public static func cleanLabel(_ label: String?) -> String? {
        guard let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// The words the Today card, the menu bar panel and notices show for a
/// quick timer.
public enum QuickTimerText {
    /// The owner's label, or "Quick timer".
    public static func title(_ timer: QuickTimer) -> String {
        timer.label ?? "Quick timer"
    }

    /// "12:34 left" or, past the end, "Time’s up · 3 min over".
    public static func status(_ timer: QuickTimer, at now: Date) -> String {
        let remaining = timer.remaining(at: now)
        if remaining > 0 { return MenuBarStatus.format(remaining: remaining) + " left" }
        let over = Int(-remaining / 60)
        return over == 0 ? "Time’s up" : "Time’s up · \(over) min over"
    }

    /// "13 min left", rounded up, for Reduce Motion: it changes once a minute.
    public static func minutesStatus(_ timer: QuickTimer, at now: Date) -> String {
        let remaining = timer.remaining(at: now)
        guard remaining > 0 else { return status(timer, at: now) }
        return "\(Int((remaining / 60).rounded(.up))) min left"
    }

    /// "20-minute timer", for the line under the title.
    public static func planned(_ timer: QuickTimer) -> String {
        "\(Int((timer.plannedLength / 60).rounded()))-minute timer"
    }

    /// A notice's title and body; `nil` for notices that are not about a
    /// quick timer.
    public static func notice(_ notice: FocusNotice) -> (title: String, body: String)? {
        switch notice {
        case .quickTimerAlmostUp(let label):
            ("2 minutes left", label.map { "Quick timer: \($0)" } ?? "Your quick timer is almost up.")
        case .quickTimerUp(let label):
            ("Time’s up", label.map { "Quick timer: \($0)" } ?? "Your quick timer has ended.")
        default:
            nil
        }
    }
}

public enum QuickTimerError: Error, Equatable {
    /// One quick timer runs at a time.
    case alreadyRunning
    /// The timer was already finished, stopped or closed.
    case notRunning
    /// Outside `QuickTimer.minutesRange`.
    case invalidLength
}
