import Foundation
import GRDB

/// The only writer of FocusPilot's databases.
///
/// Both connections are private to this actor, so every write in the app goes
/// through one of its methods. Other code asks the repository (usually via
/// `FocusCoordinator`) instead of opening the database itself.
///
/// The actor does not make a method atomic: it is reentrant, and another call
/// can run whenever a method awaits. Atomicity comes from GRDB instead, so
/// each logical change must happen inside a single `write` closure, never
/// split across two writes or a read followed by a write.
public actor TaskRepository {
    // Internal only so this actor's extensions in other files can write.
    let ownerDatabase: DatabasePool
    private let cacheDatabase: DatabasePool
    let now: @Sendable () -> Date
    /// Names the policy revisions this opening of the owner database hands
    /// out. A deleted database or a restored backup restarts them lower, so
    /// Chrome takes a delivery from a new source whatever its revision.
    public nonisolated let policySource = UUID().uuidString

    /// Opens (creating if needed) both databases in `location` and brings each
    /// up to date with its own migrations. `now` stamps created and updated
    /// times; tests pass a fixed clock.
    ///
    /// Only a failure of the owner database is thrown. A cache that cannot be
    /// opened or migrated is deleted and recreated empty, because losing
    /// derived values is cheap and must never keep the owner from their data.
    public init(location: StorageLocation, now: @escaping @Sendable () -> Date = Date.init) throws {
        self.now = now
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        ownerDatabase = try DatabasePool(path: location.ownerDatabaseURL.path)
        try OwnerSchema.migrator.migrate(ownerDatabase)
        cacheDatabase = try Self.openCache(at: location)
    }

    private static func openCache(at location: StorageLocation) throws -> DatabasePool {
        do {
            return try openAndMigrateCache(at: location)
        } catch {
            for file in location.cacheDatabaseFiles where FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            return try openAndMigrateCache(at: location)
        }
    }

    private static func openAndMigrateCache(at location: StorageLocation) throws -> DatabasePool {
        let pool = try DatabasePool(path: location.cacheDatabaseURL.path)
        try CacheSchema.migrator.migrate(pool)
        return pool
    }

    // MARK: Owner data

    public func addTask(title: String) async throws -> TaskRecord {
        try await addTask(NewTask(title: title))
    }

    public func tasks() async throws -> [TaskRecord] {
        try await ownerDatabase.read { db in
            try TaskRecord.order(Column("id")).fetchAll(db)
        }
    }

    /// Saves a captured task, filing it under an existing project with the
    /// same name (ignoring case and accents) or a new one.
    public func addTask(_ newTask: NewTask) async throws -> TaskRecord {
        guard newTask.isValid else { throw NewTask.Invalid.missingTitle }
        let createdAt = now()
        // One write closure: the project and the task commit together or not at all.
        return try await ownerDatabase.write { db in try Self.insertTask(newTask, createdAt: createdAt, db) }
    }

    /// Inserts a valid captured task inside the caller's write.
    static func insertTask(_ newTask: NewTask, createdAt: Date, _ db: Database) throws -> TaskRecord {
        // A capture joins the end of Next; only the owner pins a Now.
        let lastRank = try Int.fetchOne(db, sql: "SELECT MAX(rank) FROM task WHERE status = 'next'") ?? -1
        var task = TaskRecord(id: nil, title: newTask.title, nextAction: newTask.nextAction, rank: lastRank + 1,
                              createdAt: createdAt, updatedAt: createdAt)
        task.deadline = newTask.deadline
        task.projectId = try newTask.projectName.map { try Self.projectID(named: $0, in: db) }
        try task.insert(db)
        return task
    }

    /// Open tasks (not done): the Now task, then Next and Later in manual order.
    public func todayTasks() async throws -> [TodayItem] {
        try await ownerDatabase.read { db in try TaskWithProject.todayItems(Self.openTasks(db).fetchAll(db), db) }
    }

    /// One project's open tasks in the same order as Today; nil lists the
    /// tasks filed under no project.
    public func projectTasks(_ projectID: Int64?) async throws -> [TodayItem] {
        try await ownerDatabase.read { db in
            try TaskWithProject.todayItems(Self.openTasks(db).filter(Column("projectId") == projectID).fetchAll(db), db)
        }
    }

    /// Projects in alphabetical order with their open tasks counted, then
    /// "No project" if any open task has none.
    public func projects() async throws -> [ProjectSummary] {
        try await ownerDatabase.read { db in
            let tasks = try Self.openTasks(db).fetchAll(db)
            let byProject = Dictionary(grouping: tasks, by: \.task.projectId)
            let links = Dictionary(uniqueKeysWithValues: try HerdrLinkRecord.fetchAll(db).map { ($0.projectId, $0.link) })
            func summary(_ id: Int64?, _ title: String) -> ProjectSummary {
                let open = byProject[id] ?? []
                let nearest = open.compactMap(\.task.deadline).min { $0.endInstant < $1.endInstant }
                return ProjectSummary(id: id, title: title, openTaskCount: open.count, nearestDeadline: nearest,
                                      herdrLink: id.flatMap { links[$0] })
            }
            var projects = try ProjectRecord.fetchAll(db)
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                .map { summary($0.id, $0.title) }
            if byProject[nil] != nil {
                projects.append(summary(nil, "No project"))
            }
            return projects
        }
    }

    /// Moves a task to Now, Next or Later (see `TaskOrder.move`). The reorder
    /// is read, computed and written in one write, and every task whose
    /// place changed gets a new revision and update time.
    public func moveTask(_ id: Int64, to status: TaskStatus, _ placement: TaskPlacement) async throws {
        let updatedAt = now()
        try await ownerDatabase.write { db in
            let positions = try Row.fetchAll(db, sql: "SELECT id, status, rank FROM task WHERE status <> 'done'")
                .map { TaskPosition(id: $0["id"], status: TaskStatus(rawValue: $0["status"])!, rank: $0["rank"]) }
            for change in TaskOrder.move(id, to: status, placement, in: positions) {
                try db.execute(sql: """
                    UPDATE task SET status = ?, rank = ?, revision = revision + 1, updatedAt = ? WHERE id = ?
                    """, arguments: [change.status.rawValue, change.rank, updatedAt, change.id])
            }
        }
    }

    /// The pinned Now task, if the owner chose one.
    public func nowTask() async throws -> TodayItem? {
        try await ownerDatabase.read { db in
            try TaskWithProject.todayItems(Self.openTasks(db).filter(Column("status") == TaskStatus.now.rawValue).fetchAll(db), db).first
        }
    }

    private static func openTasks(_ db: Database) throws -> QueryInterfaceRequest<TaskWithProject> {
        TaskRecord
            .filter(Column("status") != TaskStatus.done.rawValue)
            .including(optional: TaskRecord.project)
            .order(sql: "CASE status WHEN 'now' THEN 0 WHEN 'next' THEN 1 ELSE 2 END, rank, id")
            .asRequest(of: TaskWithProject.self)
    }

    /// Project titles for the capture sheet's popup, in alphabetical order.
    public func projectTitles() async throws -> [String] {
        try await ownerDatabase.read { db in
            try ProjectRecord.fetchAll(db).map(\.title).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    /// Runs inside the caller's write, so the lookup and the insert cannot
    /// be interleaved with another capture. Matching ignores case and accents
    /// in Swift because SQLite's NOCASE only folds ASCII: "INVESTIGACIÓN"
    /// files under "Investigación".
    private static func projectID(named name: String, in db: Database) throws -> Int64 {
        let existing = try ProjectRecord.fetchAll(db).first {
            $0.title.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if let existing {
            return existing.id!
        }
        var project = ProjectRecord(id: nil, title: name)
        try project.insert(db)
        return project.id!
    }

    // MARK: Herdr links

    /// Imports the owner's chosen workspaces as linked projects, in one write.
    public func importHerdrWorkspaces(_ workspaces: [HerdrWorkspace], on server: HerdrServer) async throws {
        try await ownerDatabase.write { db in try HerdrLinkStore.importWorkspaces(workspaces, on: server, in: db) }
    }

    /// Records Herdr's current workspaces and turns the new ones into linked
    /// projects. Returns the titles of the projects it created or linked.
    @discardableResult
    public func syncHerdrWorkspaces(_ workspaces: [HerdrWorkspace], on server: HerdrServer) async throws -> [String] {
        try await ownerDatabase.write { db in try HerdrLinkStore.syncWorkspaces(workspaces, on: server, in: db) }
    }

    /// Links a project to a workspace, replacing its current link.
    public func linkProject(_ projectID: Int64, to workspace: HerdrWorkspace, on server: HerdrServer) async throws {
        try await ownerDatabase.write { db in try HerdrLinkStore.link(project: projectID, to: workspace, on: server, in: db) }
    }

    /// Removes the project's link. The project and its tasks stay.
    public func unlinkProject(_ projectID: Int64) async throws {
        _ = try await ownerDatabase.write { db in try HerdrLinkRecord.deleteOne(db, key: projectID) }
    }

    // MARK: Tasks from the focuspilot CLI

    /// Appends the task to the end of Next in the caller's linked project,
    /// marked as from Herdr, in one write. A request ID already stored
    /// returns that task again instead of adding a copy.
    public func addFromHerdr(_ request: HerdrAddRequest) async throws -> HerdrAddResult {
        let createdAt = now()
        return try await ownerDatabase.write { db in try HerdrTaskStore.add(request, createdAt: createdAt, in: db) }
    }

    /// The owner's undo of a CLI add: deletes the task in one write. Tasks
    /// the owner captured, the Now task and done tasks are refused.
    public func undoHerdrAdd(_ taskID: Int64) async throws {
        try await ownerDatabase.write { db in try HerdrTaskStore.undo(taskID, in: db) }
    }

    /// Deletes the task for good, in one write: its wrap-ups, agent links and
    /// review items go with it (schema cascades), and so do its focus sessions
    /// and plan blocks. The check for a session under way is in the same write,
    /// so a plan block starting meanwhile cannot lose its task. A plan stays
    /// approved: removing a block adds nothing the owner has not approved, and
    /// a draft would silently stop the rest of the day. Reported agents become
    /// unlinked, and pilot metrics keep their numbers without the task.
    public func deleteTask(_ taskID: Int64) async throws {
        try await ownerDatabase.write { db in
            guard try TaskRecord.exists(db, key: taskID) else { throw TaskDeletionError.notFound }
            let sessions = try SessionRow.filter(Column("taskID") == taskID).fetchAll(db)
            if try sessions.contains(where: { try !$0.session().hasEnded }) { throw TaskDeletionError.inRunningSession }
            try DayBlockRow.filter(Column("taskId") == taskID).deleteAll(db)
            try TaskRecord.deleteOne(db, key: taskID)
            try SessionRow.filter(Column("taskID") == taskID).deleteAll(db)
            try db.execute(sql: "UPDATE \(PilotEventRow.databaseTableName) SET taskId = NULL WHERE taskId = ?", arguments: [taskID])
        }
    }

    /// Now, plus the open tasks of the caller's linked project if it has one.
    public func herdrScope(for caller: HerdrCaller?) async throws -> HerdrTaskScope {
        try await ownerDatabase.read { db in try HerdrTaskStore.scope(for: caller, in: db) }
    }

    /// Whether an add failed in a way retrying cannot fix, such as a blank
    /// title or a row the schema rejects. A busy or full disk is not.
    public static func isPermanentAddFailure(_ error: any Error) -> Bool {
        if error is NewTask.Invalid { return true }
        if let database = error as? DatabaseError { return database.resultCode == .SQLITE_CONSTRAINT }
        return false
    }

    func herdrSource(of taskID: Int64) async throws -> String? {
        try await ownerDatabase.read { db in try TaskRecord.fetchOne(db, key: taskID)?.sourcePane }
    }

    // MARK: Cache

    public func storeCacheEntry(key: String, value: Data) async throws {
        try await cacheDatabase.write { db in
            try CacheEntry(key: key, value: value).save(db)
        }
    }

    public func cacheEntry(forKey key: String) async throws -> Data? {
        try await cacheDatabase.read { db in
            try CacheEntry.fetchOne(db, key: key)?.value
        }
    }

    /// Deletes every row of every cache table. The owner database is a
    /// different file and is not opened by this method.
    ///
    /// Rows are deleted in one transaction rather than erasing the file and
    /// re-running migrations: between an erase and the migration, a concurrent
    /// cache read would find no tables at all.
    public func clearCaches() async throws {
        try await cacheDatabase.write { db in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
                """)
            for table in tables {
                try db.execute(sql: "DELETE FROM \(table.quotedDatabaseIdentifier)")
            }
        }
    }
}

public enum TaskDeletionError: Error, Equatable, LocalizedError {
    case notFound
    /// A session is running, paused or on a break on this task; end it first.
    case inRunningSession

    public var errorDescription: String? {
        switch self {
        case .notFound: "The task no longer exists."
        case .inRunningSession: "A focus session is under way on this task. Complete it first."
        }
    }
}
