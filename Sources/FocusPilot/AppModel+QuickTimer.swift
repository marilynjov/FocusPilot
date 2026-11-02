import Foundation
import FocusPilotCore

/// Quick timers (D2) as the Today card and the menu bar panel use them.
/// The coordinator keeps the timer and delivers its notices; this reconciles
/// at the timer's next deadline and reports failed commands.
extension AppModel {
    @discardableResult
    func startQuickTimer(minutes: Int, label: String? = nil) async -> Bool {
        await quickTimerCommand("Could not start the timer") { try await $0.startQuickTimer(minutes: minutes, label: label) }
    }

    func finishQuickTimer() async {
        await quickTimerCommand("Could not finish the timer") { try await $0.finishQuickTimer() }
    }

    func stopQuickTimer() async {
        await quickTimerCommand("Could not stop the timer") { try await $0.stopQuickTimer() }
    }

    /// Reconciles, then waits for the next deadline again: a sleep that
    /// wakes a moment early changes nothing, and nothing is broadcast then.
    func reconcileQuickTimer() async {
        guard let coordinator else { return }
        await quickTimerCommand("Could not update the timer") { try await $0.reconcileQuickTimer() }
        scheduleQuickTimerReconcile(at: await coordinator.snapshot().quickTimer?.nextDeadline)
    }

    func scheduleQuickTimerReconcile(at deadline: Date?) {
        quickTimerTask?.cancel()
        guard let deadline else { return }
        quickTimerTask = Task { [weak self] in
            // A deadline already past means the last reconcile failed; wait a
            // second rather than retry in a busy loop.
            try? await Task.sleep(for: .seconds(deadline > .now ? deadline.timeIntervalSinceNow : 1))
            guard !Task.isCancelled else { return }
            await self?.reconcileQuickTimer()
        }
    }

    @discardableResult
    private func quickTimerCommand(_ failure: String, _ command: (FocusCoordinator) async throws -> Void) async -> Bool {
        guard let coordinator else { return false }
        do {
            try await command(coordinator)
            quickTimerError = nil
            return true
        } catch let error as QuickTimerError {
            quickTimerError = switch error {
            case .alreadyRunning: "A quick timer is already running. Finish or stop it first."
            case .notRunning: nil
            case .invalidLength: "Choose between \(QuickTimer.minutesRange.lowerBound) and \(QuickTimer.minutesRange.upperBound) minutes."
            }
            return false
        } catch {
            quickTimerError = "\(failure): \(error.localizedDescription)"
            return false
        }
    }
}
