import AppKit
import FocusPilotCore

/// Observe-only mode and pilot metrics (#21). The tracker hears which app is
/// in front, Chrome's front-tab domain while observing, and each session;
/// what it produces is stored through the coordinator. Raw activity older
/// than a day is deleted at launch and every hour; events stay.
extension AppModel {
    func setObserveOnly(_ on: Bool) async {
        guard let coordinator else { return }
        do {
            try await coordinator.setObserveOnly(on)
            observeError = nil
        } catch ObserveError.strictSession {
            observeError = "Observe only can be turned on once this strict session ends."
        } catch {
            observeError = "Could not change observe only: \(error.localizedDescription)"
        }
        show(await coordinator.snapshot())
        if !on { store(activityTracker.chromeTab(nil, at: .now)) }
    }

    func loadWeeklySummary() async {
        guard let coordinator else { return }
        let now = Date.now
        let events = (try? await coordinator.pilotEvents(since: now.addingTimeInterval(-WeeklySummary.period))) ?? []
        weeklySummary = WeeklySummary(events: events, now: now)
    }

    func track(_ snapshot: FocusSnapshot) {
        store(activityTracker.observing(snapshot.isObserveOnly, at: .now))
        store(activityTracker.session(snapshot.session, at: .now))
    }

    /// While blocking, the owner brought a blocked app forward and it was hidden.
    func noteBlockedApp(_ bundleID: String) {
        store(ActivityRecord(events: [activityTracker.blockedApp(bundleID, at: .now)]))
        noteBlockedVisit()
    }

    func followActivity(location: StorageLocation) {
        noteFrontApp(NSWorkspace.shared.frontmostApplication)
        let center = NSWorkspace.shared.notificationCenter
        Task { [weak self] in
            for await note in center.notifications(named: NSWorkspace.didActivateApplicationNotification) {
                self?.noteFrontApp(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
            }
        }
        // Asleep, locked, switched to another user or idle: nothing is in
        // front. A wake behind the lock screen starts nothing until unlocked.
        followAway(.asleep, center, on: NSWorkspace.willSleepNotification, off: NSWorkspace.didWakeNotification)
        followAway(.locked, center, on: NSWorkspace.sessionDidResignActiveNotification,
                   off: NSWorkspace.sessionDidBecomeActiveNotification)
        // Undocumented (platform assumption): the lock screen posts these
        // distributed notifications; sessionDidResignActive only covers
        // fast user switching.
        followAway(.locked, DistributedNotificationCenter.default(), on: Notification.Name("com.apple.screenIsLocked"),
                   off: Notification.Name("com.apple.screenIsUnlocked"))
        followIdleAndClock()
        let inbox = ChromeActivityInbox(location: location)
        Task { [weak self] in
            while let self {
                // Drained either way, so reports never wait in the file.
                for report in inbox.drain(now: .now) where snapshot.isObserveOnly {
                    store(activityTracker.chromeTab(report.domain, at: report.at))
                }
                // Often, so a short visit is placed before the next app switch.
                try? await Task.sleep(for: .seconds(1))
            }
        }
        Task { [weak self] in
            while let coordinator = self?.coordinator {
                try? await coordinator.pruneRawActivity()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private func followAway(_ reason: ActivityTracker.AwayReason, _ center: NotificationCenter,
                            on: Notification.Name, off: Notification.Name) {
        for (name, isAway) in [(on, true), (off, false)] {
            Task { [weak self] in
                for await _ in center.notifications(named: name) {
                    guard let self else { return }
                    store(activityTracker.away(reason, isAway, at: .now))
                }
            }
        }
    }

    /// Every 15 s: idle after 5 minutes without keyboard or mouse input
    /// (only the time since the last input is read; no event is seen, and
    /// no Accessibility permission is needed), ending the span at the last
    /// input; and a forward clock jump caps the span.
    private func followIdleAndClock() {
        let uptime = FocusCoordinator.continuousUptime()
        let anyInput = CGEventType(rawValue: ~0)!
        Task { [weak self] in
            while let self {
                let now = Date.now
                let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
                let idle = quiet >= Self.idleAfter
                store(activityTracker.away(.idle, idle, at: idle ? now.addingTimeInterval(-quiet) : now))
                store(activityTracker.tick(at: now, uptime: uptime()))
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    static let idleAfter: TimeInterval = 5 * 60

    private func noteFrontApp(_ app: NSRunningApplication?) {
        store(activityTracker.frontApp(app?.bundleIdentifier, at: .now))
    }

    private func store(_ record: ActivityRecord) {
        guard !record.isEmpty, let coordinator else { return }
        Task { try? await coordinator.record(record) }
    }
}
