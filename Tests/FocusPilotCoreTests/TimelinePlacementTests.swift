import Testing
@testable import FocusPilotCore

@Suite("Timeline placement")
struct TimelinePlacementTests {
    private let hours = TimeSpan(ClockTime(9, 0), ClockTime(17, 0))

    private func block(_ start: (Int, Int), _ end: (Int, Int)) -> DayBlock {
        DayBlock(id: 1, kind: .task, start: ClockTime(start.0, start.1), end: ClockTime(end.0, end.1))
    }

    @Test func snapsToTheNearestQuarterHour() {
        #expect(TimelinePlacement.snapped(0) == 0)
        #expect(TimelinePlacement.snapped(7) == 0)
        #expect(TimelinePlacement.snapped(7.5) == 15)
        #expect(TimelinePlacement.snapped(22) == 15)
        #expect(TimelinePlacement.snapped(-8) == -15)
        #expect(TimelinePlacement.snapped(600.4) == 600)
    }

    @Test func aMoveFollowsThePointerWithinWorkingHours() {
        let morning = block((10, 0), (11, 0))
        #expect(TimelinePlacement.clampedMove(morning, by: 13.3, within: hours) == 13.3)
        #expect(TimelinePlacement.clampedMove(morning, by: -200, within: hours) == -60)
        #expect(TimelinePlacement.clampedMove(morning, by: 500, within: hours) == 360)
    }

    @Test func aMoveSnapsItsStartAndKeepsItsLength() {
        let morning = block((10, 0), (11, 0))
        #expect(TimelinePlacement.moved(morning, by: 8, within: hours).span == TimeSpan(ClockTime(10, 15), ClockTime(11, 15)))
        #expect(TimelinePlacement.moved(morning, by: 7, within: hours) == morning)
        #expect(TimelinePlacement.moved(morning, by: -500, within: hours).span == TimeSpan(ClockTime(9, 0), ClockTime(10, 0)))
        #expect(TimelinePlacement.moved(morning, by: 500, within: hours).span == TimeSpan(ClockTime(16, 0), ClockTime(17, 0)))
        // An off-grid block lands on the grid.
        let offGrid = block((10, 10), (10, 50))
        #expect(TimelinePlacement.moved(offGrid, by: 20, within: hours).span == TimeSpan(ClockTime(10, 30), ClockTime(11, 10)))
    }

    @Test func aResizeSnapsTheEndAndKeepsAQuarterHourAtLeast() {
        let morning = block((10, 0), (11, 0))
        #expect(TimelinePlacement.resized(morning, by: 37, within: hours).end == ClockTime(11, 30))
        #expect(TimelinePlacement.resized(morning, by: -200, within: hours).end == ClockTime(10, 15))
        #expect(TimelinePlacement.resized(morning, by: 900, within: hours).end == ClockTime(17, 0))
        #expect(TimelinePlacement.clampedResize(morning, by: -200, within: hours) == -45)
        #expect(TimelinePlacement.clampedResize(morning, by: 10.5, within: hours) == 10.5)
    }

    @Test func aDroppedTaskGetsAnHourAtTheSnappedDropTime() {
        let dropped = TimelinePlacement.dropped(taskID: 7, at: 10 * 60 + 38, within: hours)
        #expect(dropped == DayBlock(kind: .task, start: ClockTime(10, 45), end: ClockTime(11, 45), taskID: 7))
        #expect(dropped.id == nil)
    }

    @Test func aDropNearTheEdgesStaysWithinWorkingHours() {
        #expect(TimelinePlacement.dropped(taskID: 7, at: 8 * 60, within: hours).span
                == TimeSpan(ClockTime(9, 0), ClockTime(10, 0)))
        #expect(TimelinePlacement.dropped(taskID: 7, at: 16 * 60 + 40, within: hours).span
                == TimeSpan(ClockTime(16, 0), ClockTime(17, 0)))
        let short = TimeSpan(ClockTime(9, 0), ClockTime(9, 45))
        #expect(TimelinePlacement.dropped(taskID: 7, at: 9 * 60 + 30, within: short).span == short)
    }

    @Test func theScaleTurnsHeightIntoMinutesAndBack() {
        let scale = TimelineScale(gridStart: 9 * 60, pointsPerMinute: 1.5)
        #expect(scale.minutes(atY: 0) == 540)
        #expect(scale.minutes(atY: 120) == 620)
        #expect(scale.y(620) == 120)
        let dropped = TimelinePlacement.dropped(taskID: 1, at: scale.minutes(atY: 117), within: hours)
        #expect(dropped.start == ClockTime(10, 15))
    }

    @Test func onlyATaskDragPayloadNamesATask() {
        #expect(PlanTaskDrag.taskID(from: PlanTaskDrag.payload(for: 42)) == 42)
        #expect(PlanTaskDrag.taskID(from: "42") == nil)
        #expect(PlanTaskDrag.taskID(from: "focuspilot-task:abc") == nil)
        #expect(PlanTaskDrag.taskID(from: "Write the essay") == nil)
    }
}
