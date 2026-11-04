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
    /// plan block runs, until its next break (D8).
    var reviewItems: [ReviewItem] {
        allReviewItems.filter { !ReviewHold.isHeld($0, session: snapshot.activeSession, planSession: snapshot.planRun != nil) }
    }

    /// Results waiting for the next break.
    var heldReviewCount: Int { allReviewItems.count - reviewItems.count }

    func setAgentMonitoring(_ on: Bool) async {
        guard let coordinator else { return }
        do {
            try await coordinator.setAgentMonitoring(on)
            agentMonitoringError = nil
        } catch {
            agentMonitoringError = "Could not change agent monitoring: \(error.localizedDescription)"
        }
        await refresh()
    }

    /// A report was recorded. A needs-you report brings the raccoon in at
    /// once, with the soft sound and a notification; other reports only
    /// redraw.
    func agentReported(_ receipt: AgentReportReceipt) async {
        await refresh()
        agentsNeedingYou.removeAll { $0.agentID == receipt.agentID }
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
        await refresh()
    }

    // MARK: Go to agent

    /// Brings the agent's terminal forward: the exact Terminal or iTerm2
    /// tab when its report named the terminal device, else the app. Only
    /// ever for the owner's click.
    func goToAgent(_ agentID: Int64, from click: AgentClick) async {
        if reportedAgents.first(where: { $0.id == agentID }) == nil { await refresh() }
        guard let agent = reportedAgents.first(where: { $0.id == agentID }) else {
            return tell("FocusPilot no longer has this agent.", from: click)
        }
        let notice: String? = switch AgentWorkspace.action(for: agent.terminal) {
        case .none(let message): message
        case .activate(let app): activate(app) ? warpNotice(app, agent) : "\(app.name) isn’t running, so the agent has stopped."
        case .tab(let app, let tty): selectTab(tty, in: app)
        }
        if let notice { tell(notice, from: click) } else { agentNotice = nil }
    }

    /// Opens a new Warp tab in the agent's folder, through Warp's
    /// documented URL. It is a new tab, not the agent's own.
    func openWarpTab(for agent: ReportedAgent) {
        guard let folder = agent.folder, let url = AgentWorkspace.warpNewTab(in: folder) else { return }
        if !NSWorkspace.shared.open(url) { agentNotice = "Warp didn’t open a new tab." }
    }

    private func warpNotice(_ app: AgentWorkspace.App, _ agent: ReportedAgent) -> String? {
        guard app == AgentWorkspace.warp else { return nil }
        let place = agent.folder.map { " in \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? ""
        return "Warp is in front. Warp has no way for FocusPilot to pick a tab, so look for the one\(place)."
    }

    /// Selects the tab through AppleScript. The first time, macOS asks the
    /// owner to let FocusPilot control the app (Automation); if that is
    /// declined, the app is still brought forward.
    private func selectTab(_ tty: String, in app: AgentWorkspace.App) -> String? {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first != nil else {
            return "\(app.name) isn’t running, so the agent has stopped."
        }
        guard let source = AgentWorkspace.script(selecting: tty, in: app), let script = NSAppleScript(source: source) else {
            return activate(app) ? nil : "\(app.name) couldn’t be brought forward."
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if error == nil, result.booleanValue { return nil }
        _ = activate(app)
        if let code = error?[NSAppleScript.errorNumber] as? Int {
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
