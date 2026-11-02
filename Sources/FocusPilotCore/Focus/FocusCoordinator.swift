import Foundation


/// Owns FocusPilot's state transitions and is the UI's single entry point.
///
/// The UI reads snapshots from here and sends requests here; the coordinator
/// talks to the repository. The current task is the one the owner pinned as
/// Now; nothing else changes it. Focus sessions are driven by `FocusEngine`
/// (see `FocusCoordinator+Sessions.swift`); every change is pushed to
/// `snapshots()` subscribers, so the menu bar stays current without the
/// planning window.
public actor FocusCoordinator {
    public enum SessionError: Error, Equatable {
        case noCurrentTask
        /// A wrap-up was asked for a session that is still running or paused.
        case sessionStillActive
    }

    private let herdr: (any HerdrWorkspaceSource)?
    let agents: (any HerdrAgentSource)?

    let repository: TaskRepository
    let publisher: PolicyPublisher
    let notices: FocusNoticeSink
    let now: @Sendable () -> Date
    /// A monotonic clock for waits, so changing the Mac's clock cannot skip them.
    let uptime: @Sendable () -> Duration
    /// The Mac's time zone, which turns plan times into instants.
    let timeZone: @Sendable () -> TimeZone

    /// The latest session, active or ended.
    var session: FocusSession?
    /// The last policy published, shown in Settings.
    var policy: CompiledPolicy?
    /// When observe-only mode started, as of that policy.
    var observeSince: Date?
    /// The owner confirmed ending the current strict session early.
    var earlyEnd: StrictWait<UUID>?
    /// The owner confirmed a rule change that weakens the strict session.
    var ruleWait: StrictWait<ConfirmedRuleEdit>?
    /// The owner confirmed an exception request during a strict session.
    var exceptionWait: StrictWait<ExceptionRequest>?
    /// The reason given when `exceptionWait` was confirmed; asking again
    /// from another profile or the app need not type it again.
    var exceptionWaitReason: String?
    /// The quick timer still running (D2); see `FocusCoordinator+QuickTimer.swift`.
    var quickTimer: QuickTimer?
    /// The last queued read-and-record of Herdr's agents; see `oneAgentReadingAtATime`.
    var agentReading: Task<Void, Never>?
    /// The run of the plan block whose session is active, if it is one.
    var planRun: PlanRun?
    /// When the approved plan next asks for a step (D3).
    var planDeadline: Date?
    /// Grows with every change, so the app can drop a snapshot older than one it has.
    private var revision = 0
    private var subscribers: [UUID: AsyncStream<FocusSnapshot>.Continuation] = [:]

    /// Without `herdr` and `agents`, Herdr reads as not installed.
    public init(repository: TaskRepository, herdr: (any HerdrWorkspaceSource)? = nil,
                agents: (any HerdrAgentSource)? = nil,
                publisher: PolicyPublisher = PolicyNotDelivered(),
                notices: FocusNoticeSink = NoticesIgnored(), now: @escaping @Sendable () -> Date = Date.init,
                uptime: @escaping @Sendable () -> Duration = FocusCoordinator.continuousUptime(),
                timeZone: @escaping @Sendable () -> TimeZone = { .autoupdatingCurrent }) {
        self.repository = repository
        self.herdr = herdr
        self.agents = agents
        self.publisher = publisher
        self.notices = notices
        self.now = now
        self.uptime = uptime
        self.timeZone = timeZone
    }

    /// Time on `ContinuousClock`, which keeps counting while the Mac sleeps.
    public static func continuousUptime() -> @Sendable () -> Duration {
        let origin = ContinuousClock.now
        return { ContinuousClock.now - origin }
    }

    public func snapshot() async -> FocusSnapshot {
        FocusSnapshot(currentTaskTitle: try? await repository.nowTask()?.title, session: session,
                      observeSince: observeSince, earlyEndAvailableAt: earlyEndAvailableAt(), policy: policy,
                      pendingRuleEdit: pendingRuleEdit(), pendingException: pendingException(),
                      quickTimer: quickTimer, planRun: planRun, planDeadline: planDeadline, revision: revision)
    }

    /// Every snapshot from now on, starting with the current one.
    public func snapshots() async -> AsyncStream<FocusSnapshot> {
        let (stream, continuation) = AsyncStream.makeStream(of: FocusSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        subscribers[id] = continuation
        continuation.onTermination = { _ in Task { await self.unsubscribe(id) } }
        continuation.yield(await snapshot())
        return stream
    }

    private func unsubscribe(_ id: UUID) {
        subscribers[id] = nil
    }

    func broadcast() async {
        revision += 1
        guard !subscribers.isEmpty else { return }
        let latest = await snapshot()
        for continuation in subscribers.values {
            continuation.yield(latest)
        }
    }

    public func hasTasks() async throws -> Bool {
        try await !repository.tasks().isEmpty
    }

    // MARK: Tasks

    public func capture(_ newTask: NewTask) async throws {
        _ = try await repository.addTask(newTask)
        await broadcast()
    }

    public func todayTasks() async throws -> [TodayItem] {
        try await repository.todayTasks()
    }

    public func projectTitles() async throws -> [String] {
        try await repository.projectTitles()
    }

    /// Pins a task as Now or moves it within or between Next and Later.
    /// Only called for the owner's own actions.
    public func moveTask(_ id: Int64, to status: TaskStatus, _ placement: TaskPlacement) async throws {
        try await repository.moveTask(id, to: status, placement)
        await broadcast()
    }

    public func projects() async throws -> [ProjectSummary] {
        try await repository.projects()
    }

    public func projectTasks(_ projectID: Int64?) async throws -> [TodayItem] {
        try await repository.projectTasks(projectID)
    }

    // MARK: Herdr workspaces

    /// Reads Herdr's workspaces and links the new ones to projects. Nothing
    /// is written while Herdr is unreachable, and a failed write is retried
    /// on the next refresh, since unseen workspaces stay unseen.
    public func refreshHerdr() async -> HerdrConnection {
        guard let herdr else { return .disconnected(.binaryNotFound) }
        let connection = await herdr.connection()
        if case .connected(let server, let workspaces) = connection {
            _ = try? await repository.syncHerdrWorkspaces(workspaces, on: server)
        }
        return connection
    }

    public func importHerdrWorkspaces(_ workspaces: [HerdrWorkspace], on server: HerdrServer) async throws {
        try await repository.importHerdrWorkspaces(workspaces, on: server)
    }

    public func linkProject(_ projectID: Int64, to workspace: HerdrWorkspace, on server: HerdrServer) async throws {
        try await repository.linkProject(projectID, to: workspace, on: server)
    }

    public func unlinkProject(_ projectID: Int64) async throws {
        try await repository.unlinkProject(projectID)
    }

    // MARK: Tasks from the focuspilot CLI

    /// The owner's undo of a task added from Herdr. The task a session is
    /// running on is refused, wherever it sits in the list.
    public func undoHerdrAdd(_ taskID: Int64) async throws {
        if let active = await snapshot().activeSession, active.taskID == taskID { throw HerdrTaskError.inRunningSession }
        try await repository.undoHerdrAdd(taskID)
    }

    /// Imports the adds queued while FocusPilot was closed. Returns how many
    /// were handed to the repository; already stored ones are not repeated.
    public func importInbox(_ inbox: TaskInbox) async throws -> Int {
        let repository = repository
        return try await inbox.drain(isPermanent: TaskRepository.isPermanentAddFailure) {
            _ = try await repository.addFromHerdr($0)
        }.imported
    }
}
