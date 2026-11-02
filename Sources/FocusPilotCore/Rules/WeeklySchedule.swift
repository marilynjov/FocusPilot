import Foundation

public enum Weekday: String, CaseIterable, Codable, Sendable, Comparable {
    case mon, tue, wed, thu, fri, sat, sun

    /// `Calendar` numbering: 1 is Sunday.
    init(calendarWeekday: Int) {
        self = Self.allCases[(calendarWeekday + 5) % 7]
    }

    var previous: Weekday {
        Self.allCases[(Self.allCases.firstIndex(of: self)! + 6) % 7]
    }

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// A wall-clock time, written "HH:mm" in policies.
public struct ClockTime: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var hour: Int
    public var minute: Int

    public init(_ hour: Int, _ minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    /// Minutes since midnight.
    public var minutes: Int { hour * 60 + minute }

    /// The time `minutes` after midnight, which must fall within one day.
    public init(minutes: Int) {
        self.init(minutes / 60, minutes % 60)
    }

    /// Only the exact form "HH:mm", as written by `description`.
    public init?(_ text: String) {
        guard let match = text.wholeMatch(of: /([0-9]{2}):([0-9]{2})/),
              let hour = Int(match.1), let minute = Int(match.2), hour < 24, minute < 60 else { return nil }
        self.init(hour, minute)
    }

    public var description: String { String(format: "%02d:%02d", hour, minute) }

    public static func < (lhs: ClockTime, rhs: ClockTime) -> Bool { lhs.minutes < rhs.minutes }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad time \(text)"))
        }
        self.init(parts[0], parts[1])
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Weekly windows in a fixed time zone, such as Mon–Fri 08:00–18:00 in
/// Bogotá. A window whose end is not after its start runs past midnight and
/// belongs to the day it starts. Extensions evaluate it against their own
/// clock, so it needs no session and no app.
public struct WeeklySchedule: Hashable, Sendable, Codable {
    public var days: Set<Weekday>
    public var start: ClockTime
    public var end: ClockTime
    public var timeZone: TimeZone

    public init(days: Set<Weekday>, from start: ClockTime, to end: ClockTime, timeZone: TimeZone) {
        self.days = days
        self.start = start
        self.end = end
        self.timeZone = timeZone
    }

    public var isValid: Bool { !days.isEmpty && start != end }

    var crossesMidnight: Bool { end < start }

    public func contains(_ instant: Date) -> Bool {
        let calendar = Calendar.gregorian(in: timeZone)
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: instant)
        let day = Weekday(calendarWeekday: parts.weekday!)
        let now = ClockTime(parts.hour!, parts.minute!)
        if crossesMidnight {
            return (days.contains(day) && now >= start) || (days.contains(day.previous) && now < end)
        }
        return days.contains(day) && now >= start && now < end
    }

    /// The first instant after `instant` at which `contains` changes.
    public func nextChange(after instant: Date) -> Date? {
        let calendar = Calendar.gregorian(in: timeZone)
        let today = calendar.startOfDay(for: instant)
        let current = contains(instant)
        let boundaries = (-1...8).flatMap { offset -> [Date] in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return [] }
            return [start, end].compactMap { calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: day) }
        }
        return boundaries.filter { $0 > instant }.sorted().first { contains($0) != current }
    }

    private enum CodingKeys: String, CodingKey {
        case days, start, end, timeZone
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let identifier = try container.decode(String.self, forKey: .timeZone)
        guard let timeZone = TimeZone(identifier: identifier) else {
            throw DecodingError.dataCorruptedError(forKey: .timeZone, in: container, debugDescription: "Unknown time zone \(identifier)")
        }
        self.init(days: Set(try container.decode([Weekday].self, forKey: .days)),
                  from: try container.decode(ClockTime.self, forKey: .start),
                  to: try container.decode(ClockTime.self, forKey: .end), timeZone: timeZone)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(days.sorted(), forKey: .days)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(timeZone.identifier, forKey: .timeZone)
    }
}
