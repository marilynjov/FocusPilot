import Foundation
import FocusPilotCore

/// A block edit waiting for the owner to confirm it lands on a fixed block.
struct BlockEditToConfirm: Identifiable {
    enum Change {
        case add, update
    }

    let id = UUID()
    let change: Change
    let block: DayBlock
    let overlapping: [DayBlock]
}

/// Today's day plan and the day preferences (D1). The coordinator checks and
/// saves every edit; this keeps what the timeline and Settings show.
extension AppModel {
    /// The local date on this Mac's clock right now.
    var todayDate: LocalDate {
        LocalDate(containing: .now, in: .current)
    }

    /// Loads today's plan, creating it from the preferences on a new day.
    func loadDayPlan() async {
        await planEdit("Could not load today’s plan") { coordinator, date in
            dayPlan = try await coordinator.dayPlan(for: date)
        }
    }

    func addBlock(_ block: DayBlock, confirmed: Bool = false) async {
        await planEdit("Could not add the block") { coordinator, date in
            apply(try await coordinator.addBlock(block, to: date, confirmed: confirmed), .add, block)
        }
    }

    /// A move, a resize, or a change of kind or task.
    func updateBlock(_ block: DayBlock, confirmed: Bool = false) async {
        await planEdit("Could not change the block") { coordinator, date in
            apply(try await coordinator.updateBlock(block, in: date, confirmed: confirmed), .update, block)
        }
    }

    func deleteBlock(_ id: Int64) async {
        await planEdit("Could not delete the block") { coordinator, date in
            dayPlan = try await coordinator.deleteBlock(id, from: date)
        }
    }

    func approveDayPlan() async {
        await planEdit("Could not approve the plan") { coordinator, date in
            dayPlan = try await coordinator.approveDayPlan(for: date)
        }
    }

    /// The owner confirmed placing the block on a fixed one.
    func confirmBlockEdit() async {
        guard let pending = blockEditToConfirm else { return }
        blockEditToConfirm = nil
        switch pending.change {
        case .add: await addBlock(pending.block, confirmed: true)
        case .update: await updateBlock(pending.block, confirmed: true)
        }
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
            dayPreferencesError = DayPlanText.message(problem)
        } catch {
            dayPreferencesError = "Could not save your day settings: \(error.localizedDescription)"
        }
    }

    private func apply(_ edit: DayPlanEdit, _ change: BlockEditToConfirm.Change, _ block: DayBlock) {
        switch edit {
        case .saved(let plan): dayPlan = plan
        case .needsConfirmation(let overlapping):
            blockEditToConfirm = BlockEditToConfirm(change: change, block: block, overlapping: overlapping)
        }
    }

    private func planEdit(_ failure: String, _ change: (FocusCoordinator, LocalDate) async throws -> Void) async {
        guard let coordinator else { return }
        do {
            try await change(coordinator, todayDate)
            dayPlanError = nil
        } catch DayPlanError.invalid(let problem) {
            dayPlanError = DayPlanText.message(problem, in: dayPlan)
        } catch DayPlanError.fixedBlock {
            dayPlanError = "Fixed blocks such as lunch are changed in Settings › Day."
        } catch {
            dayPlanError = "\(failure): \(error.localizedDescription)"
        }
    }
}
