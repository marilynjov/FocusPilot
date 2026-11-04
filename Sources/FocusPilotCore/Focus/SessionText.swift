import Foundation

/// The words the menu bar popover, the focus panel and the Start focus sheet
/// show for a session.
public struct SessionText: Sendable {
    /// How times are written: "15:33" or "3:33 PM".
    public enum Clock: Sendable {
        case twentyFourHour, twelveHour

        /// The Mac's setting.
        public static var system: Clock {
            switch Locale.current.hourCycle {
            case .oneToTwelve, .zeroToEleven: .twelveHour
            default: .twentyFourHour
            }
        }
    }

    public var session: FocusSession

    public init(_ session: FocusSession) {
        self.session = session
    }

    public var phase: String {
        switch session.phase {
        case .running: "Focusing"
        case .paused: "Paused"
        case .onBreak: "On a break"
        case .ended: "Ended"
        }
    }

    /// "24:08" of focus time left; it stands still while paused.
    public func timeLeft(at now: Date) -> String {
        MenuBarStatus.format(remaining: session.remaining(at: now))
    }

    /// "24 min left", rounded up, for Reduce Motion: it changes once a minute.
    public func minutesLeft(at now: Date) -> String {
        let seconds = max(0, session.remaining(at: now))
        return "\(Int((seconds / 60).rounded(.up))) min left"
    }

    /// "Ends at 15:33 · Bogotá" for a session starting at `start`, or
    /// "Ends tomorrow at …" when it crosses midnight.
    public static func endsAt(_ end: Date, from start: Date, timeZone: TimeZone, clock: Clock = .system) -> String {
        let time = formatter(clock == .twentyFourHour ? "HH:mm" : "h:mm a", timeZone).string(from: end)
        let day = Calendar.gregorian(in: timeZone).isDate(end, inSameDayAs: start) ? "" : "tomorrow "
        return "Ends \(day)at \(time) · \(formatter("VVV", timeZone).string(from: end))"
    }

    private static func formatter(_ pattern: String, _ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter
    }

    /// "You can end it in 0:42" while a strict early end waits.
    public static func earlyEnd(availableAt: Date, now: Date) -> String {
        now >= availableAt ? "You can end it now" : "You can end it in " + MenuBarStatus.format(remaining: availableAt.timeIntervalSince(now))
    }
}
