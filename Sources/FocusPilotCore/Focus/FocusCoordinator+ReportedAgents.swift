import Foundation

/// Agents that report to FocusPilot themselves (decision 0005, step 1).
/// Reports arrive through `CommandService`; the app reads them from here
/// and the owner links, unlinks and forgets them. Nothing here acts on an
/// agent, and a result never changes Now or completes a task.
extension FocusCoordinator {
    public func isAgentMonitoringOn() async throws -> Bool {
        try await repository.isAgentMonitoringOn()
    }

    /// Off by default (decision 0004, 2026-11-02). It covers reported
    /// agents only; Herdr does not read it yet (D8).
    public func setAgentMonitoring(_ on: Bool) async throws {
        try await repository.setAgentMonitoring(on)
    }

    public func reportedAgents() async throws -> [ReportedAgent] {
        try await repository.reportedAgents()
    }

    /// The owner links the agent to a task, or unlinks it with nil.
    public func linkReportedAgent(_ agentID: Int64, toTask taskID: Int64?) async throws {
        try await repository.linkReportedAgent(agentID, toTask: taskID)
    }

    public func forgetReportedAgent(_ agentID: Int64) async throws {
        try await repository.forgetReportedAgent(agentID)
    }
}
