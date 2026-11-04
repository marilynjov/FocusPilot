import Foundation

/// Where a block lands when the owner drags it on the Today's plan timeline,
/// or drops a task there (#29). While dragging, the block follows the pointer
/// continuously, kept within working hours; these work out the 15-minute
/// times it snaps to on release, which the timeline also shows while
/// dragging. The plan's rules (`DayPlanRules`) still decide on save.
public enum TimelinePlacement {
    public static let snapMinutes = 15
    /// How long a block for a task dropped on the timeline starts out.
    public static let droppedTaskMinutes = 60

    /// The nearest multiple of 15 minutes; halfway rounds up.
    public static func snapped(_ minutes: Double) -> Int {
        Int((minutes / Double(snapMinutes)).rounded(.toNearestOrAwayFromZero)) * snapMinutes
    }

    /// The pointer's move, in minutes, limited so the block stays within
    /// working hours. Continuous: this is what the block shows mid-drag.
    public static func clampedMove(_ block: DayBlock, by minutes: Double, within hours: TimeSpan) -> Double {
        let earliest = Double(hours.start.minutes - block.start.minutes)
        let latest = Double(hours.end.minutes - block.end.minutes)
        guard earliest <= latest else { return 0 }
        return min(max(minutes, earliest), latest)
    }

    /// The pointer's resize of the end, in minutes, limited so the block
    /// stays at least 15 minutes long and ends within working hours.
    public static func clampedResize(_ block: DayBlock, by minutes: Double, within hours: TimeSpan) -> Double {
        let shortest = Double(snapMinutes - block.span.minutes)
        let longest = Double(hours.end.minutes - block.end.minutes)
        guard shortest <= longest else { return 0 }
        return min(max(minutes, shortest), longest)
    }

    /// The block moved by `minutes`, its start snapped to the 15-minute grid,
    /// keeping its length and staying within working hours.
    public static func moved(_ block: DayBlock, by minutes: Double, within hours: TimeSpan) -> DayBlock {
        let length = block.span.minutes
        let start = Double(block.start.minutes) + clampedMove(block, by: minutes, within: hours)
        let snappedStart = max(min(max(snapped(start), hours.start.minutes), hours.end.minutes - length), 0)
        var moved = block
        moved.span = TimeSpan(ClockTime(minutes: snappedStart), ClockTime(minutes: snappedStart + length))
        return moved
    }

    /// The block with its end moved by `minutes` and snapped, at least
    /// 15 minutes long and ending within working hours.
    public static func resized(_ block: DayBlock, by minutes: Double, within hours: TimeSpan) -> DayBlock {
        let end = Double(block.end.minutes) + clampedResize(block, by: minutes, within: hours)
        let snappedEnd = min(max(snapped(end), block.start.minutes + snapMinutes), hours.end.minutes)
        var resized = block
        resized.end = ClockTime(minutes: max(snappedEnd, block.start.minutes + 1))
        return resized
    }

    /// A new task block for a task dropped at `minutes` after midnight: an
    /// hour long (or all of shorter working hours), starting at the snapped
    /// drop time and moved earlier if it would run past the end of working
    /// hours.
    public static func dropped(taskID: Int64?, at minutes: Double, within hours: TimeSpan) -> DayBlock {
        let length = min(droppedTaskMinutes, hours.minutes)
        let start = min(max(snapped(minutes), hours.start.minutes), hours.end.minutes - length)
        return DayBlock(kind: .task, start: ClockTime(minutes: start), end: ClockTime(minutes: start + length),
                        taskID: taskID)
    }
}

/// The text a task carries while dragged from the plan page's task list to
/// the timeline. Any other dropped text is ignored.
public enum PlanTaskDrag {
    private static let prefix = "focuspilot-task:"

    public static func payload(for taskID: Int64) -> String {
        "\(prefix)\(taskID)"
    }

    public static func taskID(from payload: String) -> Int64? {
        guard payload.hasPrefix(prefix) else { return nil }
        return Int64(payload.dropFirst(prefix.count))
    }
}

/// The timeline's vertical scale: a whole hour at the top, then a fixed
/// number of points per minute.
public struct TimelineScale: Hashable, Sendable {
    /// Minutes after midnight at the top of the grid.
    public var gridStart: Int
    public var pointsPerMinute: Double

    public init(gridStart: Int, pointsPerMinute: Double) {
        self.gridStart = gridStart
        self.pointsPerMinute = pointsPerMinute
    }

    public func y(_ minutes: Double) -> Double {
        (minutes - Double(gridStart)) * pointsPerMinute
    }

    /// Minutes after midnight at height `y` on the grid; unsnapped.
    public func minutes(atY y: Double) -> Double {
        Double(gridStart) + y / pointsPerMinute
    }
}
