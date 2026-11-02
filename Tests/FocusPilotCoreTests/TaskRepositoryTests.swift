import Foundation
import Testing
@testable import FocusPilotCore

@Suite("TaskRepository storage")
struct TaskRepositoryTests {
    @Test func ownerAndCacheTablesLiveInSeparateDatabases() throws {
        let location = StorageLocation(directory: try makeTemporaryDirectory())
        _ = try TaskRepository(location: location)

        let owner = try DatabaseInspection(fileAt: location.ownerDatabaseURL)
        let cache = try DatabaseInspection(fileAt: location.cacheDatabaseURL)

        #expect(owner.tables == ["task", "project", "herdrLink", "herdrSeenWorkspace", "herdrSeenServer", "focusSession", "policyPublication",
                                "blockRuleSet", "allowedActivity", "wrapUp", "herdrAgentLink", "herdrReviewItem", "timedException",
                                "observeMode", "pilotEvent", "rawActivity", "dayPreferences", "dayPlan", "dayBlock", "quickTimer", "planRun"])
        #expect(cache.tables == ["cacheEntry"])
    }

    @Test func eachDatabaseRecordsOnlyItsOwnMigrations() throws {
        let location = StorageLocation(directory: try makeTemporaryDirectory())
        _ = try TaskRepository(location: location)

        let owner = try DatabaseInspection(fileAt: location.ownerDatabaseURL)
        let cache = try DatabaseInspection(fileAt: location.cacheDatabaseURL)

        #expect(owner.appliedMigrations == OwnerSchema.migrator.migrations)
        #expect(cache.appliedMigrations == CacheSchema.migrator.migrations)
    }

    @Test func clearingCachesKeepsOwnerData() async throws {
        let repository = try TaskRepository(location: StorageLocation(directory: makeTemporaryDirectory()))
        _ = try await repository.addTask(title: "Write the essay")
        try await repository.storeCacheEntry(key: "summary", value: Data("derived".utf8))

        try await repository.clearCaches()

        #expect(try await repository.tasks().map(\.title) == ["Write the essay"])
        #expect(try await repository.cacheEntry(forKey: "summary") == nil)
    }

    @Test func cacheIsUsableAgainAfterClearing() async throws {
        let repository = try TaskRepository(location: StorageLocation(directory: makeTemporaryDirectory()))
        try await repository.clearCaches()

        try await repository.storeCacheEntry(key: "summary", value: Data("rebuilt".utf8))

        #expect(try await repository.cacheEntry(forKey: "summary") == Data("rebuilt".utf8))
    }

    @Test func ownerDataSurvivesReopening() async throws {
        let location = StorageLocation(directory: try makeTemporaryDirectory())
        _ = try await TaskRepository(location: location).addTask(title: "Read chapter 3")

        let reopened = try TaskRepository(location: location)

        #expect(try await reopened.tasks().map(\.title) == ["Read chapter 3"])
    }

    @Test func deletingTheCacheFileKeepsOwnerData() async throws {
        let location = StorageLocation(directory: try makeTemporaryDirectory())
        _ = try await TaskRepository(location: location).addTask(title: "Read chapter 3")
        try FileManager.default.removeItem(at: location.cacheDatabaseURL)

        let reopened = try TaskRepository(location: location)

        #expect(try await reopened.tasks().map(\.title) == ["Read chapter 3"])
        #expect(try await reopened.cacheEntry(forKey: "anything") == nil)
    }

    @Test func corruptCacheFileIsReplacedWithoutTouchingOwnerData() async throws {
        let location = StorageLocation(directory: try makeTemporaryDirectory())
        _ = try await TaskRepository(location: location).addTask(title: "Read chapter 3")
        try Data("not a database".utf8).write(to: location.cacheDatabaseURL)

        let reopened = try TaskRepository(location: location)

        #expect(try await reopened.tasks().map(\.title) == ["Read chapter 3"])
        try await reopened.storeCacheEntry(key: "summary", value: Data("rebuilt".utf8))
        #expect(try await reopened.cacheEntry(forKey: "summary") == Data("rebuilt".utf8))
    }

    @Test func cacheReadsDuringClearingNeverSeeAMissingTable() async throws {
        let repository = try TaskRepository(location: StorageLocation(directory: makeTemporaryDirectory()))

        try await withThrowingTaskGroup { group in
            for _ in 0..<200 {
                group.addTask { try await repository.clearCaches() }
                group.addTask { _ = try await repository.cacheEntry(forKey: "summary") }
                group.addTask { try await repository.storeCacheEntry(key: "summary", value: Data()) }
            }
            try await group.waitForAll()
        }
    }
}
