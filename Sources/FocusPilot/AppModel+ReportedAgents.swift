import AppKit
import FocusPilotCore
import UserNotifications

/// Agents that report to FocusPilot themselves (decision 0005, step 1):
/// the agent monitoring setting, what a report changes on screen, the
/// owner's links, and Go to agent. Nothing here prompts, answers or stops an
/// agent; Go to agent runs only for the owner's click.
extension AppModel {
    /// Where Go to agent was clicked, so a problem is told there.
    enum AgentClick {
        case panel
        case raccoon
        case notification
    }

    /// The Review queue as shown: a reported agent's result waits while a
    /// plan block runs, until its next break (D8). Only each agent's newest
    /// shown result is unread.
    var reviewItems: [ReviewItem] {
        ReviewItem.markingSuperseded(allReviewItems.filter {
            !ReviewHold.isHeld($0, session: snapshot.activeSession, planSession: snapshot.activePlanRun != nil,
                               releasedAt: reviewReleasedAt)
        })
    }

    /// Results waiting for the next break.
    var heldReviewCount: Int { allReviewItems.count - reviewItems.count }

    /// The raccoon's note for shown results the owner hasn't opened yet,
    /// naming the newest one's agent; held results and approval requests
    /// don't count.
    var raccoonUnreadNote: String? {
        RaccoonPresence.unreadNote(for: allReviewItems, session: snapshot.activeSession,
                                   planSession: snapshot.activePlanRun != nil, releasedAt: reviewReleasedAt)
    }

    /// Clicking the raccoon's unread note: the Review queue, in the
    /// planning window brought forward.
    func openReviewQueue() {
        requestedPage = .review
        planningWindowRequests += 1
    }

    /// A break in the session ended: what was shown during it stays shown.
    func noteReviewRelease(from old: FocusSession?, to new: FocusSession?) {
        guard let old, case .onBreak = old.phase, new?.id == old.id else { return }
        if case .onBreak = new?.phase { return }
        reviewReleasedAt = .now
    }

    /// Keeps only agents still waiting for the owner, as last read; called
    /// after each refresh, so a forgotten, answered or stale agent goes.
    func pruneAgentsNeedingYou() {
        let now = Date.now
        let waiting = Set(reportedAgents.filter { $0.state(at: now) == .needsYou }.map(\.id))
        // Notifications outlive the app: after a relaunch, take back those
        // of agents that no longer need the owner.
        if !checkedLaunchNotifications {
            checkedLaunchNotifications = true
            UserNotices.removeNeedsYou(agentIDs: reportedAgents.map(\.id).filter { !waiting.contains($0) })
        }
        let gone = agentsNeedingYou.filter { !waiting.contains($0.agentID) }
        guard !gone.isEmpty else { return }
        agentsNeedingYou.removeAll { !waiting.contains($0.agentID) }
        UserNotices.removeNeedsYou(agentIDs: gone.map(\.agentID))
        if let shown = raccoon.moment?.agentID, !waiting.contains(shown) { raccoon.endPeek(reevaluating: false) }
    }

    func setAgentMonitoring(_ on: Bool) async {
        guard let coordinator else { return }
        do {
            try await coordinator.setAgentMonitoring(on)
            agentMonitoringError = nil
        } catch {
            agentMonitoringError = "Could not change agent monitoring: \(error.localizedDescription)"
        }
        if !on {
            // Nothing is listened to any more, so nothing still calls the owner.
            UserNotices.removeNeedsYou(agentIDs: agentsNeedingYou.map(\.agentID))
            agentsNeedingYou.removeAll()
            if raccoon.moment?.agentID != nil { raccoon.endPeek(reevaluating: false) }
        }
        await refresh()
    }

    /// A report was recorded. A needs-you report brings the raccoon in at
    /// once, with the soft sound and a notification; other reports only
    /// redraw.
    func agentReported(_ receipt: AgentReportReceipt) async {
        await refresh()
        // A new request, or a newer report of something else, makes an
        // earlier request out of date; a late report about the past doesn't.
        if receipt.needsYouNow || receipt.state != .needsYou {
            agentsNeedingYou.removeAll { $0.agentID == receipt.agentID }
            UserNotices.removeNeedsYou(agentIDs: [receipt.agentID])
        }
        if receipt.needsYouNow {
            agentsNeedingYou.append(RaccoonMoments.AgentNeed(agentID: receipt.agentID, label: receipt.label, since: .now))
            playTimeUpSound(.soon)
            let message = reportedAgents.first { $0.id == receipt.agentID }?.lastMessage
            Task { await UserNotices.deliverNeedsYou(agentID: receipt.agentID, label: receipt.label, message: message) }
        }
        // An agent no longer waiting takes its peek with it.
        if let shown = raccoon.moment?.agentID, !agentsNeedingYou.contains(where: { $0.agentID == shown }) {
            raccoon.endPeek(reevaluating: false)
        }
        evaluateRaccoonMoments()
    }

    func linkReportedAgent(_ agentID: Int64, toTask taskID: Int64?) async {
        guard let coordinator else { return }
        do {
            try await coordinator.linkReportedAgent(agentID, toTask: taskID)
        } catch {
            agentNotice = "Could not link the agent: \(error.localizedDescription)"
        }
        await refresh()
    }

    func forgetReportedAgent(_ agentID: Int64) async {
        guard let coordinator else { return }
        do {
            try await coordinator.forgetReportedAgent(agentID)
        } catch {
            agentNotice = "Could not remove the agent: \(error.localizedDescription)"
        }
        agentsNeedingYou.removeAll { $0.agentID == agentID }
        UserNotices.removeNeedsYou(agentIDs: [agentID])
        await refresh()
    }

    // MARK: Go to agent

    /// Brings the agent's terminal forward: the exact Terminal or iTerm2
    /// tab when its report named the terminal device, the Warp window
    /// FocusPilot opened for the chat, else the app. Only ever for the
    /// owner's click.
    func goToAgent(_ agentID: Int64, from click: AgentClick) async {
        if reportedAgents.first(where: { $0.id == agentID }) == nil { await refresh() }
        guard let agent = reportedAgents.first(where: { $0.id == agentID }) else {
            return tell("FocusPilot no longer has this agent.", from: click)
        }
        // The title FocusPilot gave the chat's own window, if it opened one.
        let window = agent.warpWindow.flatMap { WarpLaunch.windowTitle(ofWindow: $0, in: WarpLaunch.standardDirectory) }
        let notice: String? = switch AgentWorkspace.action(for: agent.terminal, warpWindow: window) {
        case .none(let message): message
        case .activate(let app): activate(app) ? warpNotice(app, agent) : "\(app.name) isn’t running, so the agent has stopped."
        case .tab(let app, let tty): await selectTab(tty, in: app)
        case .window(let app, let title): AgentWorkspace.notice(after: raiseWindow(titled: title, in: app))
        }
        if let notice { tell(notice, from: click) } else { agentNotice = nil }
    }

    /// Raises the window titled `title` through Accessibility, then brings
    /// the app forward whatever happened. The first time this launch that
    /// FocusPilot isn't allowed, macOS is asked to show its request.
    private func raiseWindow(titled title: String, in app: AgentWorkspace.App) -> AgentWorkspace.WindowSearch {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first else {
            return .notRunning
        }
        let allowed = WarpWindows.isAllowed(prompting: !askedForAccessibility)
        if !allowed { askedForAccessibility = true }
        let raised = allowed && WarpWindows.raise(titled: title, pid: running.processIdentifier)
        _ = activate(app)
        return !allowed ? .notAllowed : raised ? .raised : .notFound
    }

    // MARK: Start Claude Code

    /// Where Start Claude Code opens for the task without asking: where an
    /// agent linked to it last reported from, else its project's Herdr
    /// workspace folder. Nil means the owner is asked.
    func claudeCodeFolder(for task: TodayItem) -> String? {
        let project = task.projectID.flatMap { id in projects.first { $0.id == id }?.herdrLink?.cwd }
        return AgentWorkspace.startFolder(agentFolders: reportedAgents.filter { $0.taskID == task.id }.map(\.folder),
                                          projectFolder: project, isUsable: { WarpLaunch.usableFolder($0) != nil })
    }

    /// Starts Claude Code for the task in a new Warp window of its own, so
    /// Go to agent can bring that window back (`WarpLaunch`). In
    /// `claudeCodeFolder`, or one the owner chooses when there is none or
    /// `choosingFolder`. Only for the owner's click; the agent's reports
    /// then come linked to the task and name the window.
    func startClaudeCode(for task: TodayItem, choosingFolder: Bool = false) {
        guard canOpenWarpWindows(),
              let folder = (choosingFolder ? nil : claudeCodeFolder(for: task)) ?? chooseFolder(for: task)
        else { return }
        guard let launch = WarpLaunch(taskID: task.id, taskTitle: task.title, folder: folder) else {
            agentNotice = "FocusPilot can’t start Claude Code in that folder. Choose one whose path has no quotes or any of $ ; & | < > ! ` ~ * ? [ ] { } ( ) #."
            return
        }
        if open(launch) { agentNotice = nil }
    }

    /// Moves a Claude Code chat FocusPilot didn't open into a Warp window of
    /// its own, resuming the same session there (`claude --resume`, which
    /// keeps the session's ID, so it stays this agent). Only for the
    /// owner's click; the old tab is the owner's to close.
    func openInOwnWindow(_ agent: ReportedAgent, task: TodayItem) {
        guard AgentWorkspace.canResume(agent, windowsOnDisk: warpWindowsOnDisk), let folder = agent.folder,
              canOpenWarpWindows()
        else { return }
        guard let launch = WarpLaunch(taskID: task.id, taskTitle: task.title, folder: folder, resuming: agent.key) else {
            agentNotice = "FocusPilot can’t open this chat in its own window: its folder’s path has quotes or one of $ ; & | < > ! ` ~ * ? [ ] { } ( ) #, or no longer exists."
            return
        }
        if open(launch) { agentNotice = "Opened in its own window. Close the old tab so you don’t type in both." }
    }

    /// Agent monitoring is on and Warp is installed, or the owner is told.
    private func canOpenWarpWindows() -> Bool {
        guard isAgentMonitoringOn else {
            agentNotice = "Turn on Agent monitoring in Settings › General to open Claude Code from FocusPilot."
            return false
        }
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: AgentWorkspace.warp.bundleID) != nil else {
            agentNotice = "Warp isn’t installed, so FocusPilot can’t open Claude Code in it."
            return false
        }
        return true
    }

    /// Writes the window's launch configuration and asks Warp to open it.
    private func open(_ launch: WarpLaunch) -> Bool {
        var launch = launch
        do {
            try launch.write(into: WarpLaunch.standardDirectory)
        } catch {
            agentNotice = "Could not save Warp’s launch configuration: \(error.localizedDescription)"
            return false
        }
        warpWindowsOnDisk.insert(WarpLaunch.OnDisk(token: launch.token, resumedSession: launch.resumedSession))
        guard let url = launch.url, NSWorkspace.shared.open(url) else {
            agentNotice = "Warp didn’t open the new window."
            return false
        }
        return true
    }

    /// Removes Warp launch configurations no longer needed (see
    /// `WarpLaunch.stale`): when the open tasks or the agents' windows
    /// change, and hourly, since an unreported window goes after a day.
    func removeStaleWarpLaunches() async {
        guard let open = try? await coordinator?.openTaskIDs() else { return }
        let inputs = WarpTidyInputs(openTasks: open, referenced: Set(reportedAgents.compactMap(\.warpWindow)))
        if let last = lastWarpTidy, last.inputs == inputs, Date.now.timeIntervalSince(last.at) < 3600 { return }
        lastWarpTidy = (inputs, .now)
        let remaining = WarpLaunch.removeStale(referenced: inputs.referenced, openTasks: open,
                                               in: WarpLaunch.standardDirectory)
        if remaining != warpWindowsOnDisk { warpWindowsOnDisk = remaining }
    }

    /// Asks the owner for the folder Claude Code works in. Nil if cancelled.
    private func chooseFolder(for task: TodayItem) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        panel.prompt = "Start Here"
        panel.message = "Choose the folder Claude Code works in for “\(task.title)”."
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// Opens a new Warp tab in the agent's folder, through Warp's
    /// documented URL. It is a new tab, not the agent's own.
    func openWarpTab(for agent: ReportedAgent) {
        guard let folder = agent.folder, let url = AgentWorkspace.warpNewTab(in: folder) else { return }
        if !NSWorkspace.shared.open(url) { agentNotice = "Warp didn’t open a new tab." }
    }

    private func warpNotice(_ app: AgentWorkspace.App, _ agent: ReportedAgent) -> String? {
        app == AgentWorkspace.warp
            ? AgentWorkspace.warpNotice(folder: agent.folder,
                                        canOpenOwnWindow: AgentWorkspace.canResume(agent, windowsOnDisk: warpWindowsOnDisk))
            : nil
    }

    /// Selects the tab through AppleScript. The first time, macOS asks the
    /// owner to let FocusPilot control the app (Automation); if that is
    /// declined, the app is still brought forward.
    private func selectTab(_ tty: String, in app: AgentWorkspace.App) async -> String? {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first != nil else {
            return "\(app.name) isn’t running, so the agent has stopped."
        }
        guard let source = AgentWorkspace.script(selecting: tty, in: app) else {
            return activate(app) ? nil : "\(app.name) couldn’t be brought forward."
        }
        // Off the main actor: the first time, the Automation prompt waits
        // for the owner, and the app must not freeze meanwhile. The script
        // object is made and used on that one task only.
        let (found, code) = await Task.detached { () -> (Bool, Int?) in
            guard let script = NSAppleScript(source: source) else { return (false, nil) }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            return (error == nil && result.booleanValue, error?[NSAppleScript.errorNumber] as? Int)
        }.value
        if found { return nil }
        _ = activate(app)
        if let code {
            // errAEEventNotPermitted: the owner declined, or has not allowed, Automation.
            return code == -1743
                ? "\(app.name) is in front, but FocusPilot isn’t allowed to pick its tab. To allow it, turn on \(app.name) under FocusPilot in System Settings › Privacy & Security › Automation."
                : "\(app.name) is in front, but its tab couldn’t be picked (error \(code))."
        }
        return "\(app.name) is in front, but the agent’s tab wasn’t found. It may have closed."
    }

    /// Brings a running app forward. False if it isn't running.
    private func activate(_ app: AgentWorkspace.App) -> Bool {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first,
              let url = running.bundleURL
        else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return true
    }

    /// Shows a Go to agent problem where it was clicked: in the Agent panel,
    /// or by the raccoon when the click was on its bubble or a notification.
    private func tell(_ notice: String, from click: AgentClick) {
        agentNotice = notice
        guard click != .panel, displayPreferences.raccoonMode != .off else { return }
        raccoon.show(RaccoonMoment(id: .init(.needsYou, "notice-\(Date.now.timeIntervalSinceReferenceDate)"),
                                   peek: RaccoonPeek(poseID: "confused", message: notice, actions: [.gotIt])))
    }

    /// Clicking a needs-you notification goes to the agent.
    func followNotificationClicks() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = notificationClicks
        Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .goToReportedAgent) {
                guard let agentID = note.object as? Int64 else { continue }
                await self?.goToAgent(agentID, from: .notification)
            }
        }
    }
}

/// Receives notification clicks. A needs-you notification names its
/// agent; any other click only reaches the app, as before.
final class NotificationClicks: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let agentID = response.notification.request.content.userInfo[UserNotices.reportedAgentKey] as? Int64
        else { return }
        await MainActor.run { NotificationCenter.default.post(name: .goToReportedAgent, object: agentID) }
    }
}

extension Notification.Name {
    static let goToReportedAgent = Notification.Name("FocusPilot.goToReportedAgent")
}

/// What tidying Warp's launch configurations depends on.
struct WarpTidyInputs: Equatable {
    var openTasks: Set<Int64>
    var referenced: Set<String>
}
