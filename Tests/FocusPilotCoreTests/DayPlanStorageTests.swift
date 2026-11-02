import Foundation
import GRDB
import Testing
@testable import FocusPilotCore

@Suite("Day plan storage")
struct DayPlanStorageTests {
    private let location: StorageLocation
    private let clock = SettableClock(wednesdayMorningInBogota)
    private let repository: TaskRepository
    private let today = LocalDate(year: 2026, month: 10, day: 14)
    private let tomorrow = LocalDate(year: 2026, month: 10, day: 15)

    init() throws {
        location = StorageLocation(directory: try makeTemporaryDirectory())
        repository = try TaskRepository(location: location, now: { [clock] in clock.now })
    }

    private func task(_ start: (Int, Int), _ end: (Int, Int), taskID: Int64? = nil) -> DayBlock {
        DayBlock(kind: .task, start: ClockTime(start.0, start.1), end: ClockTime(end.0, end.1), taskID: taskID)
    }

    private func saved(_ edit: DayPlanEdit) throws -> DayPlan {
        guard case .saved(let plan) = edit else { throw DayPlanError.blockNotFound }
        return plan
    }

    @Test func aNewDayStartsAsADraftFromTheStandardPreferences() async throws {
        let plan = try await repository.dayPlan(for: today)

        #expect(plan.date == today)
        #expect(plan.state == .draft)
        #expect(plan.workingHours == TimeSpan(ClockTime(9, 0), ClockTime(17, 0)))
        #expect(plan.blocks.map(\.kind) == [.lunch])
        #expect(plan.blocks.first?.span == TimeSpan(ClockTime(12, 0), ClockTime(13, 0)))
        #expect(plan.blocks.first?.isFixed == true)
        #expect(try await repository.dayPlan(for: today) == plan)
    }

    @Test func savedPreferencesApplyToNewDaysOnly() async throws {
        _ = try await repository.dayPlan(for: today)
        let preferences = DayPreferences(
            workingHours: TimeSpan(ClockTime(8, 0), ClockTime(16, 0)),
            fixedBlocks: [.init(kind: .lunch, start: ClockTime(12, 30), end: ClockTime(13, 30)),
                          .init(kind: .break, start: ClockTime(10, 0), end: ClockTime(10, 15))]
        )

        try await repository.saveDayPreferences(preferences)

        #expect(try await repository.dayPreferences() == preferences)
        let existing = try await repository.dayPlan(for: today)
        #expect(existing.workingHours == DayPreferences.standard.workingHours)
        #expect(existing.blocks.map(\.start) == [ClockTime(12, 0)])
        let next = try await repository.dayPlan(for: tomorrow)
        #expect(next.workingHours == preferences.workingHours)
        #expect(next.blocks.map(\.kind) == [.break, .lunch])
        #expect(next.blocks.allSatisfy { $0.isFixed })
    }

    @Test func invalidPreferencesAreRefused() async throws {
        var preferences = DayPreferences.standard
        preferences.workingHours = TimeSpan(ClockTime(13, 0), ClockTime(17, 0))

        await #expect(throws: DayPlanError.self) { try await repository.saveDayPreferences(preferences) }
        #expect(try await repository.dayPreferences() == .standard)
    }

    @Test func blocksCanBeAddedMovedResizedAndDeleted() async throws {
        let essay = try await repository.addTask(NewTask(title: "Write the essay"))
        var plan = try saved(try await repository.addBlock(task((9, 0), (10, 0), taskID: essay.id), to: today))
        var block = try #require(plan.blocks.first { !$0.isFixed })
        #expect(plan.title(of: block) == "Write the essay")

        block.span = TimeSpan(ClockTime(10, 0), ClockTime(11, 0))
        plan = try saved(try await repository.updateBlock(block, in: today))
        #expect(plan.blocks.map(\.start) == [ClockTime(10, 0), ClockTime(12, 0)])

        block.end = ClockTime(11, 45)
        plan = try saved(try await repository.updateBlock(block, in: today))
        #expect(plan.blocks.first?.span == TimeSpan(ClockTime(10, 0), ClockTime(11, 45)))

        plan = try await repository.deleteBlock(block.id!, from: today)
        #expect(plan.blocks.map(\.kind) == [.lunch])
    }

    @Test func landingOnLunchIsSavedOnlyOnceConfirmed() async throws {
        let lunch = try #require(try await repository.dayPlan(for: today).blocks.first)
        let overLunch = task((11, 30), (12, 30))

        #expect(try await repository.addBlock(overLunch, to: today) == .needsConfirmation([lunch]))
        #expect(try await repository.dayPlan(for: today).blocks.count == 1)

        let plan = try saved(try await repository.addBlock(overLunch, to: today, confirmed: true))
        #expect(plan.blocks.map(\.start) == [ClockTime(11, 30), ClockTime(12, 0)])
    }

    @Test func invalidEditsAreRefusedAndChangeNothing() async throws {
        let plan = try saved(try await repository.addBlock(task((9, 0), (10, 0)), to: today))
        let clash = task((9, 30), (10, 30))

        await #expect(throws: DayPlanError.invalid(.overlap(clash, plan.blocks[0]))) {
            try await repository.addBlock(clash, to: today, confirmed: true)
        }
        var late = plan.blocks[0]
        late.end = ClockTime(18, 0)
        await #expect(throws: DayPlanError.invalid(.outsideWorkingHours(late, plan.workingHours))) {
            try await repository.updateBlock(late, in: today)
        }
        #expect(try await repository.dayPlan(for: today) == plan)
    }

    @Test func fixedBlocksChangeOnlyInSettings() async throws {
        var lunch = try #require(try await repository.dayPlan(for: today).blocks.first)
        lunch.start = ClockTime(11, 0)

        await #expect(throws: DayPlanError.fixedBlock) { try await repository.updateBlock(lunch, in: today) }
        await #expect(throws: DayPlanError.fixedBlock) { try await repository.deleteBlock(lunch.id!, from: today) }
    }

    @Test func aBlockFromAnotherDayIsNotFound() async throws {
        let plan = try saved(try await repository.addBlock(task((9, 0), (10, 0)), to: today))
        let block = try #require(plan.blocks.first { !$0.isFixed })

        await #expect(throws: DayPlanError.blockNotFound) { try await repository.deleteBlock(block.id!, from: tomorrow) }
    }

    @Test func approvingMarksThePlanAndAnyEditMakesItADraftAgain() async throws {
        _ = try await repository.addBlock(task((9, 0), (10, 0)), to: today)

        var plan = try await repository.approveDayPlan(for: today)
        #expect(plan.state == .approved)
        #expect(try await repository.dayPlan(for: today).state == .approved)

        var block = try #require(plan.blocks.first { !$0.isFixed })
        block.end = ClockTime(10, 30)
        plan = try saved(try await repository.updateBlock(block, in: today))
        #expect(plan.state == .draft)
    }

    @Test func aPlanWithAProblemCannotBeApproved() async throws {
        _ = try await repository.dayPlan(for: today)
        // Only possible by writing around the repository, e.g. a damaged file.
        try await DatabaseQueue(path: location.ownerDatabaseURL.path).write { db in
            try db.execute(sql: """
                INSERT INTO dayBlock (planDate, kind, startTime, endTime) VALUES
                ('2026-10-14', 'task', '09:00', '10:00'), ('2026-10-14', 'break', '09:30', '09:45')
                """)
        }

        await #expect(throws: DayPlanError.self) { try await repository.approveDayPlan(for: today) }
        #expect(try await repository.dayPlan(for: today).state == .draft)
    }

    @Test func deletingATaskKeepsItsBlockWithoutATask() async throws {
        let essay = try await repository.addTask(NewTask(title: "Write the essay"))
        _ = try await repository.addBlock(task((9, 0), (10, 0), taskID: essay.id), to: today)
        try await DatabaseQueue(path: location.ownerDatabaseURL.path).write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "DELETE FROM task")
        }

        let block = try #require(try await repository.dayPlan(for: today).blocks.first { !$0.isFixed })
        #expect(block.taskID == nil)
    }

    @Test func onlyTaskBlocksKeepATask() async throws {
        let essay = try await repository.addTask(NewTask(title: "Write the essay"))
        let plan = try saved(try await repository.addBlock(
            DayBlock(kind: .break, start: ClockTime(10, 0), end: ClockTime(10, 15), taskID: essay.id), to: today))

        #expect(plan.blocks.allSatisfy { $0.taskID == nil })
    }

    @Test func plansSurviveClearingCachesAndReopening() async throws {
        _ = try await repository.addBlock(task((9, 0), (10, 0)), to: today)
        let approved = try await repository.approveDayPlan(for: today)

        try await repository.clearCaches()
        #expect(try await repository.dayPlan(for: today) == approved)

        let reopened = try TaskRepository(location: location)
        #expect(try await reopened.dayPlan(for: today) == approved)
    }
}

@Suite("Owner schema migration to v12")
struct OwnerMigrationV12Tests {
    @Test func existingTasksStayAndDaysStartFromTheStandardPreferences() async throws {
        let location = StorageLocation(directory: try makeTemporaryDirectory())
        let oldDatabase = try DatabaseQueue(path: location.ownerDatabaseURL.path)
        try OwnerSchema.migrator.migrate(oldDatabase, upTo: "owner-v11-observe")
        try await oldDatabase.write { db in
            try db.execute(sql: "INSERT INTO task (title) VALUES ('Write the essay')")
        }
        try oldDatabase.close()

        let repository = try TaskRepository(location: location)

        #expect(try await repository.tasks().map(\.title) == ["Write the essay"])
        #expect(try await repository.dayPreferences() == .standard)
        #expect(try await repository.dayPlan(for: LocalDate(year: 2026, month: 10, day: 14)).blocks.map(\.kind) == [.lunch])
    }
}
