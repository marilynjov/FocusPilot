import Foundation

/// Part of one day between two wall-clock times, such as working hours
/// 09:00–17:00. Unlike a `WeeklySchedule` window, it never runs past
/// midnight: an end that is not after the start is a mistake, not tomorrow.
public struct TimeSpan: Hashable, Sendable, Codable {
    public var start: ClockTime
    public var end: ClockTime

    public init(_ start: ClockTime, _ end: ClockTime) {
        self.start = start
        self.end = end
    }

    public var minutes: Int { end.minutes - start.minutes }

    /// Spans that only touch, such as 11:00–12:00 and 12:00–13:00, do not overlap.
    public func overlaps(_ other: TimeSpan) -> Bool {
        start < other.end && other.start < end
    }

    public func contains(_ other: TimeSpan) -> Bool {
        start <= other.start && other.end <= end
    }
}

/// One block of a day plan (decision 0004): a task, a break, lunch or the
/// end-of-day wrap-up, between two wall-clock times of the plan's date.
///
/// The times are never turned into instants here. `PlanSessions.instant`
/// does that when blocks run as sessions (D3), handling DST: a time in a
/// spring-forward gap does not exist that day, and one in an autumn overlap
/// happens twice.
public struct DayBlock: Hashable, Sendable, Identifiable {
    public enum Kind: String, CaseIterable, Codable, Sendable {
        case task, `break`, lunch, wrapUp

        public var title: String {
            switch self {
            case .task: "Task"
            case .break: "Break"
            case .lunch: "Lunch"
            case .wrapUp: "Wrap-up"
            }
        }
    }

    /// Nil until stored.
    public var id: Int64?
    public var kind: Kind
    public var start: ClockTime
    public var end: ClockTime
    /// The task a task block is for, if the owner picked one. Other kinds have none.
    public var taskID: Int64?
    /// Copied from the owner's fixed daily blocks when the plan was created.
    /// The owner may move or remove it on one day's plan; that changes only
    /// that day, never Settings.
    public var isFixed: Bool

    public init(id: Int64? = nil, kind: Kind, start: ClockTime, end: ClockTime, taskID: Int64? = nil, isFixed: Bool = false) {
        self.id = id
        self.kind = kind
        self.start = start
        self.end = end
        self.taskID = taskID
        self.isFixed = isFixed
    }

    public var span: TimeSpan {
        get { TimeSpan(start, end) }
        set { (start, end) = (newValue.start, newValue.end) }
    }
}

/// The plan for one local date: its blocks in time order. Nothing runs from
/// a plan until the owner approves it, and any edit after that makes it a
/// draft again, so an approved plan is always one the owner saw as it is.
public struct DayPlan: Hashable, Sendable {
    public enum State: String, Sendable {
        case draft, approved
    }

    public var date: LocalDate
    public var state: State
    /// The owner's working hours when this day's plan was created. Changing
    /// them in Settings applies to days not planned yet.
    public var workingHours: TimeSpan
    /// In start order.
    public var blocks: [DayBlock]
    /// Titles of the tasks the blocks name, for display.
    public var taskTitles: [Int64: String]

    public init(date: LocalDate, state: State = .draft, workingHours: TimeSpan, blocks: [DayBlock] = [],
                taskTitles: [Int64: String] = [:]) {
        self.date = date
        self.state = state
        self.workingHours = workingHours
        self.blocks = blocks
        self.taskTitles = taskTitles
    }

    /// What the timeline calls a block: its task's title, or its kind.
    public func title(of block: DayBlock) -> String {
        block.taskID.flatMap { taskTitles[$0] } ?? block.kind.title
    }
}
