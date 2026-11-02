import Foundation

/// Day plans built by hand on the Today timeline (D1, decision 0004). An
/// approved plan only records the owner's approval for now; it starts no
/// sessions until D3.
extension FocusCoordinator {
    public func dayPreferences() async throws -> DayPreferences {
        try await repository.dayPreferences()
    }

    public func saveDayPreferences(_ preferences: DayPreferences) async throws {
        try await repository.saveDayPreferences(preferences)
    }

    public func dayPlan(for date: LocalDate) async throws -> DayPlan {
        try await repository.dayPlan(for: date)
    }

    public func addBlock(_ block: DayBlock, to date: LocalDate, confirmed: Bool = false) async throws -> DayPlanEdit {
        try await repository.addBlock(block, to: date, confirmed: confirmed)
    }

    public func updateBlock(_ block: DayBlock, in date: LocalDate, confirmed: Bool = false) async throws -> DayPlanEdit {
        try await repository.updateBlock(block, in: date, confirmed: confirmed)
    }

    public func deleteBlock(_ id: Int64, from date: LocalDate) async throws -> DayPlan {
        try await repository.deleteBlock(id, from: date)
    }

    public func approveDayPlan(for date: LocalDate) async throws -> DayPlan {
        try await repository.approveDayPlan(for: date)
    }
}
