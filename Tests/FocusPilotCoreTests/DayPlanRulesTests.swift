import Foundation
import Testing
@testable import FocusPilotCore

@Suite("Day plan rules")
struct DayPlanRulesTests {
    private let hours = TimeSpan(ClockTime(9, 0), ClockTime(17, 0))
    private let lunch = DayBlock(id: 1, kind: .lunch, start: ClockTime(12, 0), end: ClockTime(13, 0), isFixed: true)
    private let writing = DayBlock(id: 2, kind: .task, start: ClockTime(9, 0), end: ClockTime(10, 30), taskID: 7)

    private func block(_ start: (Int, Int), _ end: (Int, Int), id: Int64? = nil) -> DayBlock {
        DayBlock(id: id, kind: .task, start: ClockTime(start.0, start.1), end: ClockTime(end.0, end.1))
    }

    private func check(_ candidate: DayBlock) -> DayBlockCheck {
        DayPlanRules.check(candidate, among: [writing, lunch], workingHours: hours)
    }

    @Test func aBlockInAFreeSlotFits() {
        #expect(check(block((10, 30), (12, 0))) == .fits)
        #expect(check(block((13, 0), (17, 0))) == .fits)
    }

    @Test(arguments: [((11, 0), (11, 0)), ((11, 0), (10, 0))])
    func aBlockHasToEndAfterItStarts(start: (Int, Int), end: (Int, Int)) {
        let candidate = block(start, end)
        #expect(check(candidate) == .invalid(.endNotAfterStart(candidate)))
    }

    @Test(arguments: [((8, 0), (9, 30)), ((16, 30), (17, 30)), ((7, 0), (8, 0))])
    func aBlockStaysWithinWorkingHours(start: (Int, Int), end: (Int, Int)) {
        let candidate = block(start, end)
        #expect(check(candidate) == .invalid(.outsideWorkingHours(candidate, hours)))
    }

    @Test func aBlockCannotOverlapAnotherOrdinaryBlock() {
        let candidate = block((10, 0), (11, 0))
        #expect(check(candidate) == .invalid(.overlap(candidate, writing)))
    }

    @Test func landingOnAFixedBlockNeedsConfirmation() {
        #expect(check(block((11, 30), (12, 30))) == .needsConfirmation([lunch]))
    }

    @Test func movingLunchForTodayOntoATaskNeedsConfirmation() {
        var moved = lunch
        moved.span = TimeSpan(ClockTime(10, 0), ClockTime(11, 0))
        #expect(check(moved) == .needsConfirmation([writing]))
    }

    @Test func fixedBlocksCannotOverlapEachOther() {
        let coffee = DayBlock(id: 3, kind: .break, start: ClockTime(15, 0), end: ClockTime(15, 15), isFixed: true)
        var moved = coffee
        moved.span = TimeSpan(ClockTime(12, 45), ClockTime(13, 0))
        #expect(DayPlanRules.check(moved, among: [lunch, coffee], workingHours: hours) == .invalid(.overlap(moved, lunch)))
    }

    @Test func anOrdinaryOverlapOutranksAFixedOne() {
        let candidate = block((10, 0), (12, 30))
        #expect(check(candidate) == .invalid(.overlap(candidate, writing)))
    }

    @Test func movingABlockIgnoresWhereItWas() {
        var moved = writing
        moved.span = TimeSpan(ClockTime(9, 30), ClockTime(11, 0))
        #expect(check(moved) == .fits)
    }

    @Test func blocksThatOnlyTouchDoNotOverlap() {
        #expect(check(block((10, 30), (12, 0))) == .fits)
        #expect(check(block((13, 0), (14, 0))) == .fits)
    }

    @Test func aPlanListsEveryProblemButNotConfirmedFixedOverlaps() {
        let early = block((8, 0), (9, 0), id: 3)
        let clash = block((10, 0), (11, 0), id: 4)
        let overLunch = block((12, 30), (13, 30), id: 5)
        let plan = DayPlan(date: LocalDate(year: 2026, month: 11, day: 2), workingHours: hours,
                           blocks: [early, writing, clash, lunch, overLunch])

        #expect(DayPlanRules.problems(in: plan) == [.outsideWorkingHours(early, hours), .overlap(writing, clash)])
    }

    @Test func theStandardPreferencesAreNineToFiveWithLunchAtNoon() {
        let standard = DayPreferences.standard
        #expect(standard.workingHours == hours)
        #expect(standard.dayBlocks == [DayBlock(kind: .lunch, start: ClockTime(12, 0), end: ClockTime(13, 0), isFixed: true)])
        #expect(standard.problem == nil)
    }

    @Test func preferencesNeedOrderedHoursAndFixedBlocksInsideThemThatDoNotOverlap() {
        var preferences = DayPreferences.standard
        preferences.workingHours = TimeSpan(ClockTime(17, 0), ClockTime(9, 0))
        #expect(preferences.problem == .workingHoursEndNotAfterStart)

        preferences = .standard
        preferences.fixedBlocks.append(.init(kind: .break, start: ClockTime(17, 0), end: ClockTime(17, 15)))
        #expect(preferences.problem == .outsideWorkingHours(
            DayBlock(kind: .break, start: ClockTime(17, 0), end: ClockTime(17, 15)), preferences.workingHours))

        preferences = .standard
        preferences.fixedBlocks.append(.init(kind: .break, start: ClockTime(12, 45), end: ClockTime(13, 15)))
        #expect(preferences.problem == .overlap(DayBlock(kind: .lunch, start: ClockTime(12, 0), end: ClockTime(13, 0)),
                                                DayBlock(kind: .break, start: ClockTime(12, 45), end: ClockTime(13, 15))))

        preferences = .standard
        preferences.fixedBlocks.append(.init(kind: .task, start: ClockTime(15, 0), end: ClockTime(16, 0)))
        #expect(preferences.problem == .notAFixedKind(.task))
    }

    private let twentyFourHour = Locale(identifier: "en_GB")
    private let twelveHour = Locale(identifier: "en_US")

    @Test func messagesNameTheBlocksAndTimes() {
        let candidate = block((10, 0), (11, 0))
        #expect(DayPlanText.message(.overlap(candidate, lunch), locale: twentyFourHour)
                == "Task 10:00–11:00 overlaps Lunch 12:00–13:00.")
        #expect(DayPlanText.message(.outsideWorkingHours(candidate, TimeSpan(ClockTime(11, 0), ClockTime(17, 0))),
                                    locale: twentyFourHour)
                == "Task 10:00–11:00 is outside your working hours (11:00–17:00).")
        #expect(DayPlanText.confirmation([lunch], locale: twentyFourHour) == "This overlaps Lunch 12:00–13:00. Place it anyway?")
    }

    /// The formatter may put a narrow no-break space before AM and PM.
    private func plainSpaces(_ text: String) -> String {
        text.replacing("\u{202F}", with: " ")
    }

    @Test func timesFollowTheTwelveOrTwentyFourHourClock() {
        #expect(plainSpaces(DayPlanText.time(ClockTime(9, 0), locale: twelveHour)) == "9:00 AM")
        #expect(plainSpaces(DayPlanText.times(lunch.span, locale: twelveHour)) == "12:00 PM–1:00 PM")
        #expect(DayPlanText.time(ClockTime(9, 0), locale: twentyFourHour) == "9:00")
        #expect(DayPlanText.time(ClockTime(13, 30), locale: twentyFourHour) == "13:30")
    }

    @Test func theMidnightThatEndsTheDayHasALabel() {
        #expect(DayPlanText.time(minutesAfterMidnight: 24 * 60, locale: twentyFourHour) == "0:00")
        #expect(plainSpaces(DayPlanText.time(minutesAfterMidnight: 24 * 60, locale: twelveHour)) == "12:00 AM")
    }

    @Test func clockTimesReadOnlyTheStoredForm() {
        #expect(ClockTime("09:05") == ClockTime(9, 5))
        #expect(ClockTime("9:05") == nil)
        #expect(ClockTime("24:00") == nil)
        #expect(ClockTime(minutes: 12 * 60 + 30) == ClockTime(12, 30))
    }
}
