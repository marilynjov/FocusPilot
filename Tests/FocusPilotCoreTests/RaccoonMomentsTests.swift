import Foundation
import Testing
@testable import FocusPilotCore

/// When the raccoon peeks in (D12, owner request 2026-11-02): one pure
/// function of the session, today's plan and runs, the last blocked visit,
/// what was already shown and the instant.
@Suite("Raccoon moments")
struct RaccoonMomentsTests {
    private let today = LocalDate(year: 2026, month: 10, day: 14)
    private let sessionID = UUID()
    /// 24-hour times, so the expected text does not depend on the Mac.
    private let britishEnglish = Locale(identifier: "en_GB")

    private func at(_ time: String) -> Date {
        instant("2026-10-14T\(time):00-05:00")
    }

    private func block(_ id: Int64, _ kind: DayBlock.Kind, _ start: (Int, Int), _ end: (Int, Int),
                       taskID: Int64? = nil) -> DayBlock {
        DayBlock(id: id, kind: kind, start: ClockTime(start.0, start.1), end: ClockTime(end.0, end.1),
                 taskID: taskID, isFixed: kind != .task)
    }

    private func plan(_ blocks: [DayBlock], state: DayPlan.State = .approved) -> DayPlan {
        DayPlan(date: today, state: state, workingHours: TimeSpan(ClockTime(0, 0), ClockTime(23, 45)),
                blocks: blocks, taskTitles: [7: "Write the report"])
    }

    /// 10:30–11:30 on the report with a break 11:00–11:10, lunch 12:00–13:00,
    /// and 12:30–14:00 on the report over the end of lunch.
    private var day: DayPlan {
        plan([block(1, .task, (10, 30), (11, 30), taskID: 7),
              block(2, .break, (11, 0), (11, 10)),
              block(4, .lunch, (12, 0), (13, 0)),
              block(3, .task, (12, 30), (14, 0), taskID: 7)])
    }

    private func session(from start: String, to end: String, _ phase: SessionPhase = .running,
                         mode: SessionMode = .normal) -> FocusSession {
        FocusSession(id: sessionID, taskID: 7, action: "Write the report", mode: mode,
                     startedAt: at(start), plannedEnd: at(end), phase: phase)
    }

    private func run(_ blockID: Int64, from start: String, breaksStarted: Set<Int64> = []) -> PlanRun {
        PlanRun(blockID: blockID, sessionID: sessionID, startedAt: at(start), breaksStarted: breaksStarted)
    }

    private func next(_ mode: RaccoonCompanionMode = .staysOnScreen, session: FocusSession? = nil,
                      extended: TimeInterval = 0, endedBreak: RaccoonMoments.EndedBreak? = nil, plan: DayPlan? = nil,
                      runs: [PlanRun] = [], blockedVisitAt: Date? = nil,
                      shown: [RaccoonMoment.ID: Date] = [:], at time: String) -> RaccoonMoment? {
        RaccoonMoments.next(mode: mode, session: session, extended: extended, endedBreak: endedBreak, plan: plan, runs: runs,
                            blockedVisitAt: blockedVisitAt, shown: shown, at: at(time), timeZone: bogota,
                            locale: britishEnglish)
    }

    // MARK: Modes

    @Test func offModeShowsNothingAndBothOtherModesShowMoments() {
        let running = session(from: "10:00", to: "11:00")

        #expect(next(.off, session: running, at: "10:50") == nil)
        #expect(next(.off, blockedVisitAt: at("10:50"), at: "10:50") == nil)
        #expect(next(.off, plan: day, at: "10:25") == nil)
        #expect(next(.peeksForReminders, session: running, at: "10:50")?.kind == .endWarning)
        #expect(next(.staysOnScreen, session: running, at: "10:50")?.kind == .endWarning)
    }

    @Test func nothingIsDueWithNothingGoingOn() {
        #expect(next(at: "10:00") == nil)
        #expect(next(session: session(from: "10:00", to: "11:00"), at: "10:20") == nil)
    }

    // MARK: Ten minutes left

    @Test func tenMinutesBeforeTheEndItPeeksInWithGotItAndMoreTime() throws {
        let running = session(from: "10:00", to: "11:00")

        #expect(next(session: running, at: "10:49") == nil)
        let moment = try #require(next(session: running, at: "10:50"))
        #expect(moment.id == RaccoonMoment.ID(.endWarning, "\(sessionID.uuidString)-0"))
        #expect(moment.peek == RaccoonPeek(poseID: "peek", message: "10 minutes left", actions: [.gotIt, .extend(minutes: 10), .takeBreak(minutes: 5)]))
        #expect(moment.duration == 20, "Buttons give time to choose")
        #expect(moment.sessionID == sessionID)
        // Still due a little later, e.g. after the Mac woke, saying what is left.
        #expect(next(session: running, at: "10:53")?.peek.message == "7 minutes left")
    }

    @Test func aSessionPlannedShorterThanFifteenMinutesIsWarnedTwoMinutesBefore() throws {
        let short = session(from: "10:00", to: "10:10")

        #expect(next(session: short, at: "10:07") == nil)
        let moment = try #require(next(session: short, at: "10:08"))
        #expect(moment.peek.message == "2 minutes left")
        #expect(moment.peek.actions == [.gotIt, .extend(minutes: 10), .takeBreak(minutes: 5)])
        // Fifteen minutes is not short; a second less is.
        #expect(next(session: session(from: "10:00", to: "10:15"), at: "10:05")?.peek.message == "10 minutes left")
        let shorter = FocusSession(id: sessionID, taskID: 7, action: "Write the report", mode: .normal,
                                   startedAt: at("10:00").addingTimeInterval(1), plannedEnd: at("10:15"), phase: .running)
        #expect(next(session: shorter, at: "10:05") == nil)
    }

    @Test func aFifteenMinuteTaskIsWarnedAfterFiveMinutes() throws {
        let fifteen = session(from: "10:00", to: "10:15")

        #expect(next(session: fifteen, at: "10:04") == nil)
        #expect(next(session: fifteen, at: "10:05")?.peek.message == "10 minutes left")
    }

    @Test func aSessionNoLongerThanItsWarningIsNotWarned() {
        #expect(next(session: session(from: "10:00", to: "10:02"), at: "10:00") == nil)
    }

    @Test func noWarningSoCloseToTheEndThatTimesUpIsNext() {
        let running = session(from: "10:00", to: "11:00")
        #expect(next(session: running, at: "10:59")?.peek.message == "1 minute left")
        let almost = RaccoonMoments.next(mode: .staysOnScreen, session: running, plan: nil, runs: [], blockedVisitAt: nil,
                                         shown: [:], at: at("11:00").addingTimeInterval(-20), timeZone: bogota)
        #expect(almost == nil)
    }

    @Test func noWarningWhilePausedOrOnABreak() {
        // Paused with 5 minutes left: the countdown stands still, so nothing is due.
        let paused = session(from: "10:00", to: "11:00", .paused(since: at("10:55")))
        #expect(next(session: paused, at: "10:57") == nil)
        let onBreak = session(from: "10:00", to: "11:00", .onBreak(until: at("10:58")))
        #expect(next(session: onBreak, at: "10:55")?.kind != .endWarning)
    }

    @Test func theWarningShowsOncePerSession() {
        let running = session(from: "10:00", to: "11:00")
        let shown = [RaccoonMoment.ID(.endWarning, "\(sessionID.uuidString)-0"): at("10:50")]

        #expect(next(session: running, shown: shown, at: "10:55") == nil)
        // Another session is warned in its turn.
        let other = FocusSession(id: UUID(), taskID: 7, action: "Write the report", mode: .normal,
                                 startedAt: at("10:00"), plannedEnd: at("11:00"), phase: .running)
        #expect(next(session: other, shown: shown, at: "10:55")?.kind == .endWarning)
    }

    @Test func moreTimeBringsTheWarningBackBeforeTheNewEndButAPauseDoesNot() throws {
        let running = session(from: "10:00", to: "11:00")
        let first = try #require(next(session: running, at: "10:50"))
        let shown = [first.id: at("10:50")]

        // +10 min at 10:51: 19 minutes left, then warned again at 11:00.
        let extended = session(from: "10:00", to: "11:10")
        #expect(next(session: extended, extended: 600, shown: shown, at: "10:55") == nil)
        let again = try #require(next(session: extended, extended: 600, shown: shown, at: "11:00"))
        #expect(again.kind == .endWarning)
        #expect(again.id != first.id)
        #expect(again.peek.message == "10 minutes left")

        // A 5-minute pause at 10:52 moved the end to 11:05: still 8 minutes
        // left once resumed, and nothing new to say.
        let resumed = session(from: "10:00", to: "11:05")
        #expect(next(session: resumed, shown: shown, at: "10:57") == nil)
    }

    // MARK: Time's up

    @Test func reachingThePlannedEndOffersToKeepGoingForAMinute() throws {
        let ended = session(from: "10:00", to: "11:00", .ended(at: at("11:00"), reason: .reachedPlannedEnd))

        let moment = try #require(next(session: ended, at: "11:00"))
        #expect(moment.id == RaccoonMoment.ID(.timesUp, sessionID.uuidString))
        #expect(moment.peek == RaccoonPeek(poseID: "playbow", message: "Time's up! Nice work.",
                                           actions: [.keepGoing(minutes: 10), .done]))
        #expect(moment.duration == 60)
        #expect(moment.sessionID == sessionID)
        #expect(next(session: ended, shown: [moment.id: at("11:00")], at: "11:00") == nil)
    }

    @Test func anEndLongAgoIsNoLongerNews() {
        // E.g. the Mac slept through the end.
        let ended = session(from: "10:00", to: "11:00", .ended(at: at("11:00"), reason: .reachedPlannedEnd))
        #expect(next(session: ended, at: "11:02") == nil)
        let completed = session(from: "10:00", to: "11:00", .ended(at: at("10:30"), reason: .completed))
        #expect(next(session: completed, at: "10:32") == nil)
    }

    @Test func noTimesUpWhenAPlanBlockStartsRightAway() {
        // An owner session ends as block 1 starts: the block takes over.
        let ended = session(from: "10:00", to: "10:30", .ended(at: at("10:30"), reason: .reachedPlannedEnd))
        #expect(next(session: ended, plan: day, at: "10:30") == nil)
        // Once the block has run, the end is the owner's to celebrate.
        let otherRun = PlanRun(blockID: 1, sessionID: UUID(), startedAt: at("10:30"))
        #expect(next(session: ended, plan: day, runs: [otherRun], at: "10:30")?.kind == .timesUp)
    }

    // MARK: Finished

    @Test func completingCelebratesBrieflyWithoutButtons() throws {
        let completed = session(from: "10:00", to: "11:00", .ended(at: at("10:40"), reason: .completed))

        let moment = try #require(next(session: completed, at: "10:40"))
        #expect(moment.id == RaccoonMoment.ID(.finished, sessionID.uuidString))
        #expect(moment.peek == RaccoonPeek(poseID: "excited", message: "Nice work!"))
        #expect(moment.duration == 6)
    }

    // MARK: Breaks

    @Test func twoMinutesBeforeAPlanBreakItWalksIn() throws {
        let running = session(from: "10:30", to: "11:30")
        let runs = [run(1, from: "10:30")]

        #expect(next(session: running, plan: day, runs: runs, at: "10:57") == nil)
        let moment = try #require(next(session: running, plan: day, runs: runs, at: "10:58"))
        #expect(moment.id == RaccoonMoment.ID(.breakSoon, "\(sessionID.uuidString)-2"))
        #expect(moment.peek == RaccoonPeek(poseID: "walk", message: "Break in 2 minutes", actions: [.gotIt]))
        #expect(next(session: running, plan: day, runs: runs, shown: [moment.id: at("10:58")], at: "10:59") == nil)
        // A break already taken, or a session that is not the block's, has none.
        #expect(next(session: running, plan: day, runs: [run(1, from: "10:30", breaksStarted: [2])], at: "10:58") == nil)
        #expect(next(session: running, plan: day, at: "10:58") == nil)
    }

    @Test func lunchInsideTheBlockIsAnnouncedToo() {
        let running = session(from: "12:30", to: "14:00")
        let lunchLater = plan([block(4, .lunch, (13, 0), (13, 30)), block(3, .task, (12, 30), (14, 0), taskID: 7)])
        #expect(next(session: running, plan: lunchLater, runs: [run(3, from: "12:30")], at: "12:58")?.peek.message
            == "Break in 2 minutes")
    }

    @Test func aBreakStartingBringsCoffeeAndBackToTask() throws {
        let onBreak = session(from: "10:30", to: "11:30", .onBreak(until: at("11:10")))
        let runs = [run(1, from: "10:30", breaksStarted: [2])]

        let moment = try #require(next(session: onBreak, plan: day, runs: runs, at: "11:00"))
        #expect(moment.id == RaccoonMoment.ID(.breakStarted, "\(sessionID.uuidString)-2"))
        #expect(moment.peek == RaccoonPeek(poseID: "coffee", message: "Enjoy your break", actions: [.backToTask]))
        #expect(moment.duration == 20)
        #expect(next(session: onBreak, plan: day, runs: runs, shown: [moment.id: at("11:00")], at: "11:01") == nil)
        #expect(!RaccoonMoments.isOnLunch(onBreak, plan: day, runs: runs, at: at("11:00"), timeZone: bogota))
    }

    @Test func lunchIsANapWithoutButtons() throws {
        let onLunch = session(from: "12:30", to: "14:00", .onBreak(until: at("13:00")))
        let runs = [run(3, from: "12:30", breaksStarted: [4])]

        let moment = try #require(next(session: onLunch, plan: day, runs: runs, at: "12:30"))
        #expect(moment.peek == RaccoonPeek(poseID: "sleep", message: "Lunch time"))
        #expect(RaccoonMoments.isOnLunch(onLunch, plan: day, runs: runs, at: at("12:45"), timeZone: bogota))
        // Back to work once lunch is over.
        let working = session(from: "12:30", to: "14:00")
        #expect(!RaccoonMoments.isOnLunch(working, plan: day, runs: runs, at: at("12:45"), timeZone: bogota))
    }

    @Test func betweenBlocksABreakHasCoffeeAndLunchIsANap() {
        let between = plan([block(1, .task, (10, 0), (11, 0), taskID: 7), block(2, .break, (11, 0), (11, 15)),
                            block(4, .lunch, (12, 0), (13, 0)), block(5, .break, (14, 0), (14, 15))])
        #expect(RaccoonMoments.planBreak(between, at: at("11:05"), timeZone: bogota) == .onBreak)
        #expect(RaccoonMoments.planBreak(between, at: at("12:00"), timeZone: bogota) == .onLunch)
        #expect(RaccoonMoments.planBreak(between, at: at("12:59"), timeZone: bogota) == .onLunch)
        #expect(RaccoonMoments.planBreak(between, at: at("13:00"), timeZone: bogota) == nil)
        #expect(RaccoonMoments.planBreak(between, at: at("10:30"), timeZone: bogota) == nil)
        // Only an approved plan, and only fixed breaks.
        #expect(RaccoonMoments.planBreak(plan(between.blocks, state: .draft), at: at("12:30"), timeZone: bogota) == nil)
        #expect(RaccoonMoments.planBreak(nil, at: at("12:30"), timeZone: bogota) == nil)
        let loose = plan([DayBlock(id: 9, kind: .break, start: ClockTime(15, 0), end: ClockTime(15, 30))])
        #expect(RaccoonMoments.planBreak(loose, at: at("15:10"), timeZone: bogota) == nil)
    }

    // MARK: Owner breaks (2026-11-03)

    @Test func aBreakTheOwnerTakesBringsCoffeeAndBackToTaskEvenOverLunch() throws {
        // Taken during the plan's lunch inside block 3: still the owner's break.
        let onBreak = session(from: "12:30", to: "14:10", .onBreak(until: at("12:45"), movesEnd: true))
        let runs = [run(3, from: "12:30", breaksStarted: [4])]

        let moment = try #require(next(session: onBreak, plan: day, runs: runs, at: "12:35"))
        #expect(moment.kind == .breakStarted)
        #expect(moment.peek == RaccoonPeek(poseID: "coffee", message: "Enjoy your break", actions: [.backToTask]))
        #expect(!RaccoonMoments.isOnLunch(onBreak, plan: day, runs: runs, at: at("12:35"), timeZone: bogota))
    }

    @Test func anOwnerBreakThatRanOutSaysBackToItOnce() throws {
        let running = session(from: "10:00", to: "10:35")
        let ended = RaccoonMoments.EndedBreak(sessionID: sessionID, until: at("10:15"))

        let moment = try #require(next(session: running, endedBreak: ended, at: "10:15"))
        #expect(moment.kind == .breakOver)
        #expect(moment.peek == RaccoonPeek(poseID: "backpack", message: "Break's over. Back to it!", actions: [.gotIt]))
        #expect(moment.sessionID == sessionID)
        #expect(next(session: running, endedBreak: ended, shown: [moment.id: at("10:15")], at: "10:15") == nil)
        // Old news a few minutes on, and only for the session it ended in.
        #expect(next(session: running, endedBreak: ended, at: "10:17") == nil)
        let other = RaccoonMoments.EndedBreak(sessionID: UUID(), until: at("10:15"))
        #expect(next(session: running, endedBreak: other, at: "10:15") == nil)
        // Not while on another break or paused.
        let paused = session(from: "10:00", to: "10:35", .paused(since: at("10:15")))
        #expect(next(session: paused, endedBreak: ended, at: "10:15") == nil)
    }

    // MARK: Blocked visits

    @Test func aBlockedVisitIsCheeredWithACooldown() throws {
        let moment = try #require(next(blockedVisitAt: at("10:00"), at: "10:00"))
        #expect(moment.kind == .blockedVisit)
        #expect(moment.peek == RaccoonPeek(poseID: "sign", message: "You got this"))
        #expect(moment.duration == 6)
        #expect(moment.sessionID == nil)
        let shown = [moment.id: at("10:00")]

        #expect(next(blockedVisitAt: at("10:00"), shown: shown, at: "10:00") == nil)
        // Another visit within ten minutes is not cheered again.
        #expect(next(blockedVisitAt: at("10:09"), shown: shown, at: "10:09") == nil)
        #expect(next(blockedVisitAt: at("10:10"), shown: shown, at: "10:10")?.kind == .blockedVisit)
    }

    @Test func onlyARecentBlockedVisitIsCheered() {
        #expect(next(blockedVisitAt: at("10:00"), at: "10:02") == nil)
        // A visit from before the last cheer does not count again after the cooldown.
        let shown = [RaccoonMoment.ID(.blockedVisit, "earlier"): at("10:00")]
        #expect(next(blockedVisitAt: at("09:59"), shown: shown, at: "10:00") == nil)
    }

    // MARK: Between blocks

    @Test func tenMinutesBeforeTheNextBlockItShowsWhatIsNext() throws {
        #expect(next(plan: day, at: "10:19") == nil)
        let moment = try #require(next(plan: day, at: "10:20"))
        #expect(moment.id == RaccoonMoment.ID(.nextBlock, "1"))
        #expect(moment.peek == RaccoonPeek(poseID: "backpack", message: "Next: Write the report at 10:30", actions: [.gotIt]))
        #expect(next(plan: day, shown: [moment.id: at("10:20")], at: "10:25") == nil)
    }

    @Test func theNextBlockWaitsForAnApprovedPlanAndNoSession() {
        #expect(next(plan: plan(day.blocks, state: .draft), at: "10:20") == nil)
        #expect(next(session: session(from: "10:00", to: "11:00"), plan: day, at: "10:20")?.kind != .nextBlock)
        let paused = session(from: "10:00", to: "11:00", .paused(since: at("10:10")))
        #expect(next(session: paused, plan: day, at: "10:20") == nil)
        // After a session ended the next block is announced.
        let ended = session(from: "09:00", to: "09:30", .ended(at: at("09:30"), reason: .reachedPlannedEnd))
        #expect(next(session: ended, plan: day, at: "10:25")?.kind == .nextBlock)
        // A block that already ran is not next.
        #expect(next(plan: day, runs: [PlanRun(blockID: 3, sessionID: UUID(), startedAt: at("12:20"))], at: "12:25") == nil)
    }

    // MARK: Priority

    @Test func theMostPressingMomentShowsFirst() throws {
        // A 30-minute block with a break at 10:22: at 10:20 both the end
        // warning and the break are due.
        let tight = plan([block(1, .task, (10, 0), (10, 30), taskID: 7), block(2, .break, (10, 22), (10, 25))])
        let running = session(from: "10:00", to: "10:30")
        let runs = [run(1, from: "10:00")]

        let first = try #require(next(session: running, plan: tight, runs: runs, blockedVisitAt: at("10:20"), at: "10:20"))
        #expect(first.kind == .endWarning)
        let second = try #require(next(session: running, plan: tight, runs: runs, blockedVisitAt: at("10:20"),
                                       shown: [first.id: at("10:20")], at: "10:20"))
        #expect(second.kind == .breakSoon)
        let third = next(session: running, plan: tight, runs: runs, blockedVisitAt: at("10:20"),
                         shown: [first.id: at("10:20"), second.id: at("10:20")], at: "10:20")
        #expect(third?.kind == .blockedVisit)

        // Time's up outranks a cheer at the same moment.
        let ended = session(from: "10:00", to: "11:00", .ended(at: at("11:00"), reason: .reachedPlannedEnd))
        #expect(next(session: ended, blockedVisitAt: at("11:00"), at: "11:00")?.kind == .timesUp)
        #expect(RaccoonMoment.Kind.allCases.sorted() == RaccoonMoment.Kind.allCases)
        #expect(RaccoonMoment.Kind.timesUp > .endWarning)
        #expect(RaccoonMoment.Kind.endWarning > .nextBlock)
    }

    @Test func minutesReadNaturally() {
        #expect(RaccoonMoments.minutes(600) == "10 minutes")
        #expect(RaccoonMoments.minutes(599) == "10 minutes")
        #expect(RaccoonMoments.minutes(60) == "1 minute")
        #expect(RaccoonMoments.minutes(10) == "1 minute")
    }
}

@Suite("Raccoon moments: when the next one falls due")
struct RaccoonMomentsDueTests {
    let start = Date(timeIntervalSinceReferenceDate: 815_000_000)

    func session(minutes: Double, phase: SessionPhase = .running) -> FocusSession {
        FocusSession(id: UUID(), taskID: 1, action: "Write", mode: .normal, startedAt: start,
                     plannedEnd: start.addingTimeInterval(minutes * 60), phase: phase)
    }

    @Test func theEndWarningFallsDueExactlyAtItsThreshold() {
        let fifteen = session(minutes: 15)
        #expect(RaccoonMoments.nextDue(session: fifteen, plan: nil, runs: [], at: start, timeZone: .gmt)
            == start.addingTimeInterval(5 * 60))
        let ten = session(minutes: 10)
        #expect(RaccoonMoments.nextDue(session: ten, plan: nil, runs: [], at: start, timeZone: .gmt)
            == start.addingTimeInterval(8 * 60))
        // Past it, or paused, nothing is ahead.
        #expect(RaccoonMoments.nextDue(session: fifteen, plan: nil, runs: [], at: start.addingTimeInterval(6 * 60),
                                       timeZone: .gmt) == nil)
        #expect(RaccoonMoments.nextDue(session: session(minutes: 15, phase: .paused(since: start)), plan: nil, runs: [],
                                       at: start, timeZone: .gmt) == nil)
    }
}

@Suite("Raccoon moments: more time")
struct RaccoonMoreTimeTests {
    @Test func askingForMoreTimeShowsTheTiredRaccoon() {
        let peek = RaccoonMoments.moreTime(minutes: 10)
        #expect(peek.poseID == "lying")
        #expect(peek.message == "10 more minutes. You’ve got this.")
        #expect(RaccoonArtTests.manifest.pose(peek.poseID)?.name == "Tired")
    }
}
