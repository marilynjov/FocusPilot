import Foundation
import FocusPilotCore

/// What a block edit came to, for the surface that made it.
enum BlockEditOutcome {
    case saved
    /// Nothing saved yet: the owner has to confirm the overlap first.
    case needsConfirmation([DayBlock])
    /// Refused or failed; `dayPlanError` says why.
    case failed
}

/// Today's plan and the day preferences (D1). The coordinator checks and
/// saves every edit; this keeps what the timeline and Settings show.
///
/// Edits and approval go to the date of the plan on screen, never to
/// "today" worked out again, so a page left open past midnight cannot change
/// or approve a day it does not show. The page reloads when the day changes.
extension AppModel {
    /// The local date on this Mac's clock right now.
    var todayDate: LocalDate {
        LocalDate(containing: .now, in: .current)
    }

    /// Loads today's plan, creating it from the preferences on a new day.
    func loadDayPlan() async {
        guard let coordinator else { return }
        do {
            dayPlan = try await coordinator.dayPlan(for: todayDate)
            dayPlanError = nil
        } catch {
            dayPlanError = "Could not load today’s plan: \(error.localizedDescription)"
        }
    }

    /// Reloads if the plan on screen is not for today any more.
    func reloadDayPlanIfDayChanged() async {
        if let shown = dayPlan?.date, shown != todayDate { await loadDayPlan() }
    }

    func addBlock(_ block: DayBlock, confirmed: Bool = false) async -> BlockEditOutcome {
        await blockEdit("Could not add the block") { coordinator, date in
            try await coordinator.addBlock(block, to: date, confirmed: confirmed)
        }
    }

    /// A move, a resize, or a change of kind or task.
    func updateBlock(_ block: DayBlock, confirmed: Bool = false) async -> BlockEditOutcome {
        await blockEdit("Could not change the block") { coordinator, date in
            try await coordinator.updateBlock(block, in: date, confirmed: confirmed)
        }
    }

    /// Deleting a fixed block skips it on this day only.
    func deleteBlock(_ id: Int64) async {
        await planChange("Could not delete the block") { try await $0.deleteBlock(id, from: $1) }
    }

    func approveDayPlan() async {
        await planChange("Could not approve the plan") { try await $0.approveDayPlan(for: $1) }
    }

    func loadDayPreferences() async {
        guard let coordinator else { return }
        do {
            dayPreferences = try await coordinator.dayPreferences()
        } catch {
            dayPreferencesError = "Could not load your day settings: \(error.localizedDescription)"
        }
    }

    /// Saves the preferences, or explains why they were not saved.
    func saveDayPreferences(_ preferences: DayPreferences) async {
        guard let coordinator else { return }
        do {
            try await coordinator.saveDayPreferences(preferences)
            dayPreferences = preferences
            dayPreferencesError = nil
        } catch DayPlanError.invalid(let problem) {
            dayPreferencesError = "Not saved: \(DayPlanText.message(problem))"
        } catch {
            dayPreferencesError = "Could not save your day settings: \(error.localizedDescription)"
        }
    }

    private func blockEdit(_ failure: String,
                           _ edit: (FocusCoordinator, LocalDate) async throws -> DayPlanEdit) async -> BlockEditOutcome {
        var outcome = BlockEditOutcome.failed
        await planChange(failure) { coordinator, date in
            switch try await edit(coordinator, date) {
            case .saved(let plan):
                outcome = .saved
                return plan
            case .needsConfirmation(let overlapping):
                outcome = .needsConfirmation(overlapping)
                return nil
            }
        }
        return outcome
    }

    /// Runs `change` on the plan on screen and shows the plan it returns.
    private func planChange(_ failure: String, _ change: (FocusCoordinator, LocalDate) async throws -> DayPlan?) async {
        guard let coordinator, let date = dayPlan?.date else { return }
        do {
            if let plan = try await change(coordinator, date) { dayPlan = plan }
            dayPlanError = nil
        } catch let error as DayPlanError {
            dayPlanError = DayPlanText.message(error, in: dayPlan)
        } catch {
            dayPlanError = "\(failure): \(error.localizedDescription)"
        }
    }
}
