import Foundation
import GRDB

/// Agents that report to FocusPilot themselves (decision 0005, step 1), and
/// the agent monitoring setting that lets them.
extension TaskRepository {
    public func isAgentMonitoringOn() async throws -> Bool {
        try await ownerDatabase.read { db in try ReportedAgentStore.isMonitoring(in: db) }
    }

    public func setAgentMonitoring(_ on: Bool) async throws {
        let changedAt = now()
        try await ownerDatabase.write { db in try ReportedAgentStore.setMonitoring(on, at: changedAt, in: db) }
    }

    /// Records a report in one write, checking the setting in the same
    /// write. Nil while agent monitoring is off: nothing was recorded.
    public func recordAgentReport(_ report: AgentReport) async throws -> AgentReportReceipt? {
        let reportedAt = now()
        return try await ownerDatabase.write { db in try ReportedAgentStore.record(report, at: reportedAt, in: db) }
    }

    /// Every reported agent, the latest report first.
    public func reportedAgents() async throws -> [ReportedAgent] {
        try await ownerDatabase.read { db in try ReportedAgentStore.agents(in: db) }
    }

    /// The owner links the agent to a task by hand, or unlinks it with nil.
    public func linkReportedAgent(_ agentID: Int64, toTask taskID: Int64?) async throws {
        try await ownerDatabase.write { db in try ReportedAgentStore.link(agentID, toTask: taskID, in: db) }
    }

    public func forgetReportedAgent(_ agentID: Int64) async throws {
        try await ownerDatabase.write { db in try ReportedAgentStore.forget(agentID, in: db) }
    }

    /// Every task not done, so the Warp launch configurations of the rest
    /// can go (`WarpLaunch.removeStale`).
    public func openTaskIDs() async throws -> Set<Int64> {
        try await ownerDatabase.read { db in
            Set(try Int64.fetchAll(db, sql: "SELECT id FROM task WHERE status != 'done'"))
        }
    }
}
