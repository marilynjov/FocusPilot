import Foundation

/// Quick timers (D2, decision 0004): started, finished and stopped only by
/// the owner. They publish no policy, so they never change block rules; a
/// focus session is started separately. The app reconciles at
/// `QuickTimer.nextDeadline` and after the Mac wakes, which delivers the
/// "2 minutes left" and "Time's up" notices once each.
///
/// The in-memory timer is changed before each write is awaited, so two
/// reconciles interleaving on the actor cannot deliver a notice twice; a
/// failed write puts it back.
extension FocusCoordinator {
    /// Starts a timer of `minutes` with an optional label. One runs at a time.
    public func startQuickTimer(minutes: Int, label: String?) async throws {
        try await reconcileQuickTimer()
        guard quickTimer == nil else { throw QuickTimerError.alreadyRunning }
        quickTimer = try await repository.startQuickTimer(minutes: minutes, label: label)
        await broadcast()
    }

    /// The owner says it is done, before or after its end.
    public func finishQuickTimer() async throws {
        try await endQuickTimer(.finished)
    }

    /// The owner gives up on it.
    public func stopQuickTimer() async throws {
        try await endQuickTimer(.stopped)
    }

    /// Delivers the notices the clock has reached and closes a timer left
    /// unattended past `QuickTimer.unattendedLimit`.
    public func reconcileQuickTimer() async throws {
        guard let timer = quickTimer else { return }
        let (reconciled, notices) = timer.reconciled(at: now())
        guard reconciled != timer else { return }
        quickTimer = reconciled.isRunning ? reconciled : nil
        do {
            try await repository.saveQuickTimer(reconciled)
        } catch QuickTimerError.notRunning {
            // Ended by the owner while this waited; nothing left to announce.
            return
        } catch {
            if quickTimer?.id == reconciled.id || quickTimer == nil { quickTimer = timer }
            throw error
        }
        for notice in notices {
            await self.notices.deliver(notice)
        }
        await broadcast()
    }

    /// Restores a timer left running by the last launch.
    func launchQuickTimer() async throws {
        quickTimer = try await repository.runningQuickTimer()
        try await reconcileQuickTimer()
        await broadcast()
    }

    /// Records the end now. A timer already past the unattended limit keeps
    /// its `expired` record instead, since the owner was not there at its end.
    private func endQuickTimer(_ outcome: QuickTimer.Outcome) async throws {
        guard let timer = quickTimer else { throw QuickTimerError.notRunning }
        let at = now()
        var ended = timer.reconciled(at: at).0
        if ended.isRunning {
            // A clock set back must not make the actual length negative.
            ended.endedAt = max(at, timer.startedAt)
            ended.outcome = outcome
        }
        quickTimer = nil
        do {
            try await repository.saveQuickTimer(ended)
        } catch {
            if quickTimer == nil, !(error is QuickTimerError) { quickTimer = timer }
            throw error
        }
        await broadcast()
    }
}
