import AppKit
import FocusPilotCore
import Observation

/// Builds the long-lived core objects once and exposes what the views show.
@MainActor
@Observable
final class AppModel {
    private(set) var snapshot = FocusSnapshot()
    private(set) var today: [TodayItem] = []
    private(set) var projectTitles: [String] = []
    private(set) var projects: [ProjectSummary] = []
    /// The project shown in Projects (nil inside: tasks with no project).
    private(set) var shownProject: ProjectSummary.ID?
    private(set) var projectItems: [TodayItem] = []
    private(set) var startupError: String?
    private(set) var taskError: String?
    private(set) var commandLineError: String?
    /// What FocusPilot last saw of Herdr; nil until the first check.
    private(set) var herdr: HerdrConnection?
    /// Herdr's agents as last polled; nil while no task has a linked agent.
    private(set) var herdrAgents: HerdrAgents?
    private(set) var agentLinks: [TaskAgentLink] = []
    /// The whole Review queue; `reviewItems` leaves out what waits for a break.
    /// The raccoon's unread note follows it.
    private(set) var allReviewItems: [ReviewItem] = [] {
        didSet { if allReviewItems != oldValue { raccoon.update() } }
    }
    /// Agents that report to FocusPilot themselves (decision 0005); see
    /// `AppModel+ReportedAgents.swift`.
    private(set) var reportedAgents: [ReportedAgent] = []
    /// Agent monitoring as last read; off by default.
    var isAgentMonitoringOn = false
    var agentMonitoringError: String?
    /// Agents that reported they need the owner, for the raccoon; kept
    /// until they report something else or are gone.
    @ObservationIgnored var agentsNeedingYou: [RaccoonMoments.AgentNeed] = []
    /// Whether the needs-you notifications left from the last launch were
    /// checked against the agents' states, which the first refresh does.
    @ObservationIgnored var checkedLaunchNotifications = false
    /// When the last break of a session ended: held results from before it
    /// were shown during the break and stay shown (`ReviewHold`). In memory
    /// only: after a relaunch the session start counts again, so results
    /// from before that break wait for the next one.
    var reviewReleasedAt: Date?
    /// Turns a needs-you notification click into Go to agent.
    @ObservationIgnored let notificationClicks = NotificationClicks()
    /// Why the last Open agent did nothing, shown where it was clicked.
    var agentNotice: String?
    /// A Claude Code chat in Warp that Go to agent can't reach, since it
    /// has no window of its own: the planning window asks whether to open
    /// it in one before Warp covers FocusPilot (owner feedback, 2026-11-12).
    var ownWindowOffer: ReportedAgent?
    /// Go to agent asked macOS for Accessibility once this launch; after
    /// that the notice says where to turn it on.
    @ObservationIgnored var askedForAccessibility = false
    /// When Warp's launch configurations were last tidied, and from what.
    @ObservationIgnored var lastWarpTidy: (inputs: WarpTidyInputs, at: Date)?
    /// The Warp windows whose launch configurations are on disk, as last
    /// tidied or written.
    var warpWindowsOnDisk: Set<WarpLaunch.OnDisk> = []
    /// Set when a session command fails; shown by the session surfaces.
    var sessionError: String?
    /// Asks the planning window to show the Start focus sheet.
    var isStartingFocus = false
    /// A strict session is ending early and every session surface shows the
    /// confirmation, wherever Complete was chosen.
    var isConfirmingEarlyEnd = false
    /// Block rule sets and allowed entries, as Settings shows them.
    var ruleSets: [BlockRuleSet] = []
    var allowed: [AllowedActivity] = []
    /// Set when a rule or allowed-list edit was refused or failed.
    var rulesError: String?
    /// A weakening rule change during a strict session, waiting for the
    /// owner to confirm it on the Blocking tab.
    var ruleEditToConfirm: RuleEdit?
    /// Asks the planning window to show a page, e.g. Settings from ⌘,.
    var requestedPage: PlanningView.Page?
    /// Whether the planning window is open (shown, not closed).
    var isPlanningWindowOpen = false {
        didSet { refreshRaccoonWindowState() }
    }
    /// Whether FocusPilot is in front and its planning window is not
    /// minimized; see `refreshRaccoonWindowState`.
    private(set) var isPlanningWindowInFront = false {
        didSet { if isPlanningWindowInFront != oldValue { raccoon.update() } }
    }
    /// The reminder the raccoon is peeking in with (D12), if any.
    var raccoonPeek: RaccoonPeek?
    /// Today's plan and its block runs, for the raccoon's moments and its
    /// lunch nap; see `AppModel+Raccoon.swift`.
    var raccoonPlan: DayPlan?
    @ObservationIgnored var raccoonPlanRuns: [PlanRun] = []
    /// Moments already shown and when, kept in memory only, so each shows once.
    @ObservationIgnored var raccoonShownMoments: [RaccoonMoment.ID: Date] = [:]
    /// When a blocked app was last hidden or Chrome last showed its blocked page.
    @ObservationIgnored var lastBlockedVisitAt: Date?
    /// Blocked pages Chrome had shown at the last look; nil before the first.
    @ObservationIgnored var chromeBlockedPagesSeen: Int?
    /// Each session's length as planned when first seen, so pauses and
    /// breaks the owner takes, which move its planned end, don't change
    /// which end warning it gets. In memory, like `raccoonExtensions`; a
    /// session first seen after a relaunch counts from its end then.
    @ObservationIgnored var raccoonStartLengths: [UUID: TimeInterval] = [:]
    /// Time "+10 min" added to each session, so its end warning comes back
    /// before the new end. In memory, like `raccoonShownMoments`.
    @ObservationIgnored var raccoonExtensions: [UUID: TimeInterval] = [:]
    /// The last break the owner took that ran out, for "Break's over".
    @ObservationIgnored var raccoonEndedBreak: RaccoonMoments.EndedBreak?
    /// Counts plan reads, so an older read finishing late is dropped.
    @ObservationIgnored var raccoonPlanReads = 0
    /// Looks for time-based moments; see `followRaccoonMoments`.
    @ObservationIgnored var raccoonMomentsTask: Task<Void, Never>?
    /// The raccoon shows in the planning window while the owner is looking
    /// at it, and on screen otherwise (owner request, 2026-11-02).
    var raccoonIsInWindow: Bool { isPlanningWindowOpen && isPlanningWindowInFront }

    /// Reads the app and window state directly, so a missed notification
    /// cannot leave it stale.
    func refreshRaccoonWindowState() {
        isPlanningWindowInFront = NSApplication.shared.isActive && planningWindow != nil
        raccoon.update()
        raccoon.placePanel()
    }

    /// The planning window while it is open and not minimized.
    var planningWindow: NSWindow? {
        guard isPlanningWindowOpen else { return nil }
        return NSApplication.shared.windows.first {
            $0.identifier?.rawValue.hasPrefix(PlanningView.windowID) == true && $0.isVisible && !$0.isMiniaturized
        }
    }
    /// Why the last exception request was refused.
    var exceptionError: String?
    /// The wrap-up waiting for the owner; see `AppModel+WrapUp.swift`.
    var wrapUp: PendingWrapUp?
    /// Grows each time the planning window should come forward; `MenuBarIcon` opens it.
    var planningWindowRequests = 0
    /// When the owner last pressed Complete; their wrap-up may bring the window forward.
    @ObservationIgnored var ownerCompletedAt: Date?
    /// Chrome profiles running the FocusPilot extension, newest first.
    var chromeProfiles: [ChromeProfileStatus] = []
    /// Where the owner loads the extension, and any setup problem.
    var chromeSetup: ChromeSetup?
    @ObservationIgnored var chromeLocation: StorageLocation?
    /// Protection status inputs (#17); see `AppModel+Protection.swift`.
    var chromeRunning = false
    var protectionEvidence = ProtectionEvidence()
    /// The browser the owner last had in front, if the last app was one.
    var frontBrowser: FrontBrowser?
    /// Observe-only mode and pilot metrics (#21); see `AppModel+Observe.swift`.
    @ObservationIgnored var activityTracker = ActivityTracker(ownBundleID: Bundle.main.bundleIdentifier)
    var weeklySummary: WeeklySummary?
    var observeError: String?
    /// Today's plan and the day preferences (D1); see `AppModel+DayPlan.swift`.
    var dayPlan: DayPlan?
    var dayPlanError: String?
    var dayPreferences = DayPreferences.standard
    var dayPreferencesError: String?
    /// Today's plan kept these working hours at the last save, since a
    /// block falls outside the new ones; Settings › Day offers to apply them.
    var todayKeptHours: TimeSpan?
    /// Why the last quick timer command failed (D2); see `AppModel+QuickTimer.swift`.
    var quickTimerError: String?
    /// Pending reconcile at the next session deadline.
    @ObservationIgnored var reconcileTask: Task<Void, Never>?
    /// Pending reconcile at the quick timer's next notice.
    @ObservationIgnored var quickTimerTask: Task<Void, Never>?
    @ObservationIgnored lazy var focusPanel = FocusPanelController(model: self)
    /// The raccoon companion window (D11); see `RaccoonCompanion.swift`.
    @ObservationIgnored lazy var raccoon = RaccoonCompanionController(model: self)
    @ObservationIgnored lazy var appBlocker = AppBlocker(model: self)
    let loginItem = LoginItemSettings(service: MainAppLoginItem())
    let menuBarPreferences = MenuBarPreferences()
    /// Palette and Appearance (#14); see `PaletteTheme.swift`.
    let displayPreferences = DisplayPreferences()
    private let firstLaunch = FirstLaunchWelcome()

    let coordinator: FocusCoordinator?
    private var commandServer: CommandSocketServer?

    init() {
        do {
            let location = StorageLocation.applicationSupport()
            let repository = try TaskRepository(location: location)
            let herdr = HerdrCLI()
            coordinator = FocusCoordinator(repository: repository, herdr: herdr, agents: herdr,
                                           publisher: ChromePolicyMailbox(location: location), notices: UserNotices())
            // Site exceptions come only from the Chrome host in this bundle (#14).
            let chromeHost = Bundle.main.bundleURL.appending(path: "Contents/Helpers/focuspilot-chrome-host")
            listenForCommands(location: location, service: CommandService(repository: repository, exceptions: coordinator,
                                                                          exceptionCaller: .chromeHost(at: chromeHost)))
            followNotificationClicks()
            setUpChrome(location: location)
            followActivity(location: location)
        } catch {
            coordinator = nil
            startupError = "Could not open the database: \(error.localizedDescription)"
        }
        displayPreferences.applyAppearance()
        displayPreferences.appearanceDidChange = { [weak self] _ in self?.displayPreferences.applyAppearance() }
        displayPreferences.raccoonModeDidChange = { [weak self] _ in
            self?.raccoon.update()
            self?.focusPanel.update()
            Task { await self?.refreshRaccoonMoments() }
        }
        displayPreferences.raccoonScreenDidChange = { [weak self] in self?.raccoon.placePanel() }
        refreshRaccoonWindowState()
        refreshLoginItem(on: NSMenu.didBeginTrackingNotification)
        refreshLoginItem(on: NSApplication.didBecomeActiveNotification)
        tickWhileTimeIsShown()
        watchHerdr()
        followSessions()
        followRaccoonMoments()
    }

    /// Answers the focuspilot CLI, and imports what it queued while the app
    /// was closed: at launch, then every few seconds in case an add was
    /// queued while the app was starting.
    private func listenForCommands(location: StorageLocation, service: CommandService) {
        let server = CommandSocketServer(path: location.commandSocketPath) { [weak self] request, peer in
            let response = await service.handle(request, from: peer)
            switch response {
            case .added: await self?.refresh()
            case .agentRecorded(let receipt): await self?.agentReported(receipt)
            default: break
            }
            return response
        }
        do {
            try server.start()
            commandServer = server
        } catch {
            // The CLI then queues to the inbox, which is still imported.
            commandLineError = "The focuspilot command can’t reach FocusPilot: \(error)"
        }
        Task { [weak self] in
            while let self, let coordinator {
                if (try? await coordinator.importInbox(location.inbox)) ?? 0 > 0 { await refresh() }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Reads Herdr on `HerdrPollSchedule`, which also turns new workspaces
    /// into projects and, while tasks have linked agents, queues their
    /// results. Polling only reads; it never focuses or prompts an agent. While Herdr is unreachable it keeps retrying, less
    /// often, without reporting errors. Lists reload only when Herdr's answer
    /// changes.
    private func watchHerdr() {
        Task { [weak self] in
            var schedule = HerdrPollSchedule()
            while let coordinator = self?.coordinator {
                let connection = await coordinator.refreshHerdr()
                let agents = await coordinator.refreshHerdrAgents()
                guard let self else { return }
                // A new terminal title alone only redraws the inspector.
                let needsReload = connection != herdr || agents?.ignoringTitles != herdrAgents?.ignoringTitles
                herdr = connection
                herdrAgents = agents
                if needsReload { await refresh() }
                try? await Task.sleep(for: schedule.delay(after: connection))
            }
        }
    }

    // The owner can change the login item in System Settings while the app
    // runs. SwiftUI's onAppear is not guaranteed to fire on each menu open,
    // so re-read the status whenever a menu opens or the app activates.
    private func refreshLoginItem(on name: Notification.Name) {
        Task { [loginItem] in
            for await _ in NotificationCenter.default.notifications(named: name) {
                loginItem.refresh()
            }
        }
    }

    /// True once, on the first launch with no tasks; see `FirstLaunchWelcome`.
    func claimPlanningWindowAtLaunch() async -> Bool {
        guard let coordinator, let hasTasks = try? await coordinator.hasTasks() else { return false }
        return firstLaunch.claimPlanningWindowOpening(hasTasks: hasTasks)
    }

    /// The instant session times are computed for; see `tickWhileTimeIsShown`.
    private(set) var now = Date.now

    /// With Reduce Motion the time reads in whole minutes.
    func menuBarStatus(reducesMotion: Bool = false) -> MenuBarStatus {
        MenuBarStatus(snapshot: snapshot, now: now, showsTime: menuBarPreferences.showsTime, reducesMotion: reducesMotion)
    }

    // Advances `now` once a second while a session or quick timer is
    // running (its time is on screen in the popover and panel), so an idle
    // app is not redrawn every second.
    private func tickWhileTimeIsShown() {
        Task { [weak self] in
            while let self {
                try? await Task.sleep(for: .seconds(1))
                if snapshot.activeSession != nil || snapshot.quickTimer != nil || menuBarStatus().timeText != nil
                    || keepGoingOffer != nil {
                    now = .now
                }
            }
        }
    }

    /// Takes a snapshot from the coordinator unless a newer one is shown,
    /// since a fetched snapshot can arrive after a streamed one.
    func show(_ latest: FocusSnapshot) {
        now = .now
        guard latest.revision >= snapshot.revision else { return }
        noticeWrapUp(from: snapshot.session, to: latest.session)
        noteRaccoonBreakEnd(from: snapshot.session, to: latest.session)
        noteReviewRelease(from: snapshot.session, to: latest.session)
        if let sound = TimeUpSound.due(from: snapshot, to: latest, at: .now) { playTimeUpSound(sound) }
        if let session = latest.activeSession, raccoonStartLengths[session.id] == nil {
            raccoonStartLengths[session.id] = session.plannedEnd.timeIntervalSince(session.startedAt)
        }
        snapshot = latest
        if latest.activeSession == nil || latest.earlyEndAvailableAt != nil {
            isConfirmingEarlyEnd = false
        }
    }

    func refreshTime() {
        now = .now
    }

    func refresh() async {
        guard let coordinator else { return }
        show(await coordinator.snapshot())
        do {
            today = try await coordinator.todayTasks()
            projectTitles = try await coordinator.projectTitles()
            projects = try await coordinator.projects()
            if let shownProject {
                projectItems = try await coordinator.projectTasks(shownProject)
            }
            agentLinks = try await coordinator.agentLinks()
            allReviewItems = try await coordinator.reviewQueue()
            reportedAgents = try await coordinator.reportedAgents()
            isAgentMonitoringOn = try await coordinator.isAgentMonitoringOn()
            pruneAgentsNeedingYou()
            await removeStaleWarpLaunches()
            taskError = nil
        } catch {
            taskError = "Could not load tasks: \(error.localizedDescription)"
        }
    }

    func showProject(_ id: ProjectSummary.ID) async {
        shownProject = id
        await refresh()
    }

    /// Applies the owner's reorder or pin and reloads every list.
    func move(_ id: Int64, to status: TaskStatus, _ placement: TaskPlacement) async {
        guard let coordinator else { return }
        do {
            try await coordinator.moveTask(id, to: status, placement)
        } catch {
            taskError = "Could not move the task: \(error.localizedDescription)"
            return
        }
        await refresh()
    }

    func importHerdrWorkspaces(_ workspaces: [HerdrWorkspace], on server: HerdrServer) async {
        await perform("Could not import the workspaces") {
            try await $0.importHerdrWorkspaces(workspaces, on: server)
        }
    }

    func linkProject(_ projectID: Int64, to workspace: HerdrWorkspace, on server: HerdrServer) async {
        await perform("Could not link the workspace") { try await $0.linkProject(projectID, to: workspace, on: server) }
    }

    func undoHerdrAdd(_ taskID: Int64) async {
        await perform("Could not undo the task") { try await $0.undoHerdrAdd(taskID) }
    }

    // MARK: Herdr agents on tasks

    /// Herdr's agents right now, for the link sheet.
    func availableAgents() async -> HerdrAgents {
        await coordinator?.availableAgents() ?? .disconnected(.binaryNotFound)
    }

    func linkAgents(_ agents: [HerdrAgent], on server: HerdrServer, toTask taskID: Int64) async {
        var labels: [String: String] = [:]
        if case .connected(let current, let workspaces)? = herdr, current == server {
            for workspace in workspaces { labels[workspace.id] = workspace.label }
        }
        // The refresh runs before `perform` reloads the lists, so anything it
        // queued shows at once.
        await perform("Could not link the agent") { coordinator in
            for agent in agents {
                _ = try await coordinator.linkAgent(agent, on: server, workspaceLabel: labels[agent.workspaceID],
                                                    toTask: taskID)
            }
            herdrAgents = await coordinator.refreshHerdrAgents()
        }
    }

    func unlinkAgent(_ linkID: Int64) async {
        await perform("Could not unlink the agent") { try await $0.unlinkAgent(linkID) }
    }

    /// The owner's Relink after the agent was renamed in Herdr.
    func relinkAgent(_ linkID: Int64) async {
        guard let coordinator else { return }
        agentNotice = await coordinator.relinkAgent(linkID) ? nil
            : "The agent changed again in Herdr, so it wasn’t relinked. Check it and try again."
        await refresh()
    }

    func markReviewed(_ itemID: Int64) async {
        await perform("Could not mark the result reviewed") { try await $0.markReviewed(itemID) }
    }

    /// The owner selected the item in the Review queue: it is read from now
    /// on, even an older result already shown as read, so it stays read once
    /// the newer one is reviewed. Opening an opened item again writes nothing. Only that item changes,
    /// so it is updated in place rather than reloading everything.
    func markOpened(_ itemID: Int64) async {
        guard let coordinator, allReviewItems.first(where: { $0.id == itemID })?.openedAt == nil else { return }
        do {
            try await coordinator.markOpened(itemID)
        } catch {
            taskError = "Could not mark the result read: \(error.localizedDescription)"
            return
        }
        // The queue may have been reloaded meanwhile; the next refresh reads
        // the stored time anyway.
        if let index = allReviewItems.firstIndex(where: { $0.id == itemID }) {
            allReviewItems[index].openedAt = .now
        }
    }

    /// The owner clicked Open agent: focuses that agent's pane in Herdr.
    /// This is the only path to a Herdr focus, and it never restores the
    /// previous one afterwards.
    func openAgent(_ linkID: Int64) async {
        guard let coordinator else { return }
        agentNotice = switch await coordinator.openAgent(linkID) {
        case .opened: nil
        case .renamed(let name): "This agent’s name changed in Herdr to “\(name)”. Relink it to keep following it."
        case .replaced: "That pane now runs a different agent. Unlink it, or link the new one."
        case .notFound: "The agent is no longer in Herdr. It may have closed, or Herdr restarted."
        case .herdrUnavailable: "Herdr isn’t available, so the agent couldn’t be opened."
        }
        await refresh()
    }

    func unlinkProject(_ projectID: Int64) async {
        await perform("Could not unlink the workspace") { try await $0.unlinkProject(projectID) }
    }

    private func perform(_ failure: String, _ change: (FocusCoordinator) async throws -> Void) async {
        guard let coordinator else { return }
        do {
            try await change(coordinator)
        } catch {
            taskError = "\(failure): \(error.localizedDescription)"
            return
        }
        await refresh()
    }

    /// Saves the task and reloads Today. Returns false, with `taskError`
    /// set, if nothing was saved.
    func capture(_ newTask: NewTask) async -> Bool {
        guard let coordinator else {
            taskError = startupError
            return false
        }
        do {
            try await coordinator.capture(newTask)
            taskError = nil
        } catch {
            taskError = "Could not save the task: \(error.localizedDescription)"
            return false
        }
        await refresh()
        return true
    }
}
