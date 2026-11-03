import AppKit
import FocusPilotCore

/// Focus sessions as the views use them. The coordinator does the work; this
/// keeps the latest snapshot, reconciles at the next deadline and on wake,
/// and shows or hides the focus panel.
extension AppModel {
    /// What the current focus session is doing, for the raccoon; nil
    /// when there is none.
    /// Between task blocks, an approved plan's break or lunch counts too.
    var raccoonActivity: RaccoonActivity? {
        guard let session = snapshot.activeSession else {
            return RaccoonMoments.planBreak(raccoonPlan, at: .now, timeZone: .autoupdatingCurrent)
        }
        return RaccoonActivity(session.phase, isLunch: RaccoonMoments.isOnLunch(session, plan: raccoonPlan, runs: raccoonRuns,
                                                                              at: .now, timeZone: .autoupdatingCurrent))
    }

    /// The session that just reached its planned end, while "Keep going"
    /// is still offered (as long as the raccoon's "Time's up" stays).
    var keepGoingOffer: FocusSession? {
        guard let session = snapshot.session, case .ended(let at, .reachedPlannedEnd) = session.phase,
              now.timeIntervalSince(at) <= RaccoonMoments.timesUpDuration
        else { return nil }
        return session
    }

    /// The task a new session would run on: the pinned Now task.
    var nowTask: TodayItem? {
        today.first { $0.status == .now }
    }

    /// Restores a session left running by the last launch, then follows
    /// every snapshot the coordinator streams.
    func followSessions() {
        guard let coordinator else { return }
        Task { [weak self] in
            do {
                try await coordinator.launch()
            } catch {
                self?.sessionError = "Could not restore the session: \(error.localizedDescription)"
            }
            self?.appBlocker.start()
            var policyRevision: Int?
            for await snapshot in await coordinator.snapshots() {
                guard let self else { return }
                show(snapshot)
                track(snapshot)
                scheduleReconcile(at: snapshot.nextDeadline)
                scheduleQuickTimerReconcile(at: snapshot.quickTimer?.nextDeadline)
                focusPanel.update()
                await refreshRaccoonPlan()
                raccoon.update()
                evaluateRaccoonMoments()
                // Rules name the apps the Apps line shows; every rule edit publishes a policy.
                if snapshot.policy?.revision != policyRevision {
                    policyRevision = snapshot.policy?.revision
                    await loadRules()
                }
                appBlocker.policyChanged()
            }
        }
        // A clock change can bring a quick timer's notice or close forward.
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NSSystemClockDidChange) {
                await self?.reconcileQuickTimer()
            }
        }
        Task { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                // Before reconciling, which publishes the revision Chrome must confirm.
                self?.markProtectionStale()
                await self?.reconcileAfterWake()
                await self?.reconcileQuickTimer()
            }
        }
        // A plan block's instant moves when the clock, the time zone or the
        // day changes, so the wait for the next deadline is out of date.
        for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSSystemClockDidChange, .NSCalendarDayChanged] {
            Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    await self?.run { try await $0.reconcile() }
                }
            }
        }
    }

    /// Retries until it succeeds: until the wake's revision is published,
    /// Chrome can't confirm it and the status stays unknown.
    private func reconcileAfterWake() async {
        var delay = 1.0
        while coordinator != nil, !(await run { try await $0.reconcile() }) {
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 60)
        }
    }

    func requestStartFocus() {
        isStartingFocus = true
    }

    func startSession(minutes: Int, mode: SessionMode) async -> Bool {
        await run { try await $0.startSession(duration: TimeInterval(minutes * 60), mode: mode) }
    }

    func pause() async {
        await run { try await $0.pause() }
    }

    func resume() async {
        await run { try await $0.resume() }
    }

    /// Completes the session. A strict session ending early shows the
    /// confirmation instead; once `confirmed`, it starts the wait, which the
    /// snapshot shows. Returns true when the confirmation is now showing.
    @discardableResult
    func complete(confirmed: Bool = false) async -> Bool {
        var completion: SessionCompletion?
        ownerCompletedAt = .now
        await run { completion = try await $0.complete(confirmed: confirmed) }
        isConfirmingEarlyEnd = completion == .needsConfirmation
        return isConfirmingEarlyEnd
    }

    /// "I need more time" on a plan block's session: recorded only (D3).
    func requestMoreTime() async {
        await run { try await $0.requestMoreTime() }
    }

    /// "+10 min" on the session under way, running, paused or on a break.
    /// On a plan block's session it also notes that the block needed more time.
    func extend(minutes: Int) async {
        guard let id = snapshot.activeSession?.id else { return }
        let interval = TimeInterval(minutes * 60)
        if await run({ try await $0.extend(by: interval) }) {
            raccoonExtensions[id, default: 0] += interval
            showRaccoonTired(minutes: minutes)
        }
    }

    /// The tired raccoon after more time is asked for.
    private func showRaccoonTired(minutes: Int) {
        raccoon.peek(RaccoonMoments.moreTime(minutes: minutes), for: .seconds(RaccoonMoments.moreTimeDuration))
    }

    /// "Keep going" once a session has ended: the same task and mode again.
    func keepGoing(minutes: Int) async {
        if await run({ try await $0.keepGoing(duration: TimeInterval(minutes * 60)) }) {
            showRaccoonTired(minutes: minutes)
        }
    }

    /// "Take a Break" for `minutes`: the countdown stands still meanwhile
    /// (owner request, 2026-11-03).
    func takeBreak(minutes: Int) async {
        await run { try await $0.takeBreak(duration: TimeInterval(minutes * 60)) }
    }

    /// "Back to task": ends the break early.
    func endBreak() async {
        await run { try await $0.endBreak() }
    }

    func cancelEarlyEnd() async {
        isConfirmingEarlyEnd = false
        await coordinator?.cancelEarlyEnd()
    }

    @discardableResult
    private func run(_ command: (FocusCoordinator) async throws -> Void) async -> Bool {
        guard let coordinator else { return false }
        do {
            try await command(coordinator)
            sessionError = nil
            return true
        } catch {
            sessionError = "Could not update the session: \(error.localizedDescription)"
            return false
        }
    }

    private func scheduleReconcile(at deadline: Date?) {
        reconcileTask?.cancel()
        guard let deadline else { return }
        reconcileTask = Task { [weak self] in
            // A deadline already past means the last reconcile did not clear
            // it (it failed); wait a second rather than retry in a busy loop.
            try? await Task.sleep(for: .seconds(deadline > .now ? deadline.timeIntervalSinceNow : 1))
            guard !Task.isCancelled else { return }
            await self?.run { try await $0.reconcile() }
        }
    }
}
