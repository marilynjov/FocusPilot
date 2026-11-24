import Foundation
import GRDB

/// Herdr agents linked to tasks, and the Review queue their results go to.
extension TaskRepository {
    /// Links the agent to the task, remembering its current status as the
    /// starting point. Linking it again returns the existing link.
    public func linkAgent(_ agent: HerdrAgent, on server: HerdrServer, workspaceLabel: String?,
                          toTask taskID: Int64) async throws -> TaskAgentLink {
        try await linkAgentQueuing(agent, on: server, workspaceLabel: workspaceLabel, toTask: taskID).link
    }

    /// `linkAgent`, also returning the approval request queued if the agent
    /// was already waiting at one.
    func linkAgentQueuing(_ agent: HerdrAgent, on server: HerdrServer, workspaceLabel: String?,
                          toTask taskID: Int64) async throws -> (link: TaskAgentLink, queued: NewReviewItem?) {
        let linkedAt = now()
        return try await ownerDatabase.write { db in
            try HerdrAgentStore.link(agent, on: server, workspaceLabel: workspaceLabel, toTask: taskID, at: linkedAt, in: db)
        }
    }

    /// Stops watching the agent for this task. Queued results stay; an
    /// unanswered approval request is removed.
    public func unlinkAgent(_ linkID: Int64) async throws {
        try await ownerDatabase.write { db in try HerdrAgentStore.unlink(linkID, in: db) }
    }

    /// The task's links, or every link when `taskID` is nil.
    public func agentLinks(forTask taskID: Int64? = nil) async throws -> [TaskAgentLink] {
        try await ownerDatabase.read { db in try HerdrAgentStore.links(forTask: taskID, in: db) }
    }

    /// Records Herdr's current agents against the links, in one write, and
    /// returns the Review queue items this added.
    public func recordAgents(_ agents: [HerdrAgent], on server: HerdrServer) async throws -> [NewReviewItem] {
        let observedAt = now()
        return try await ownerDatabase.write { db in try HerdrAgentStore.record(agents, on: server, at: observedAt, in: db) }
    }

    /// Updates the link's name after the agent was renamed in Herdr.
    public func relinkAgent(_ linkID: Int64, to agent: HerdrAgent) async throws {
        try await ownerDatabase.write { db in try HerdrAgentStore.relink(linkID, to: agent, in: db) }
    }

    public func storeOutput(_ output: AgentOutputPreview, forReviewItem id: Int64) async throws {
        try await ownerDatabase.write { db in try HerdrAgentStore.storeOutput(output, forReviewItem: id, in: db) }
    }

    public func reviewQueue() async throws -> [ReviewItem] {
        try await ownerDatabase.read { db in try HerdrAgentStore.queue(in: db) }
    }

    public func markReviewed(_ id: Int64) async throws {
        let reviewedAt = now()
        try await ownerDatabase.write { db in try HerdrAgentStore.markReviewed(id, at: reviewedAt, in: db) }
    }

    /// The owner opened the item in the Review queue: it is no longer
    /// unread. Only the first opening is kept.
    public func markOpened(_ id: Int64) async throws {
        let openedAt = now()
        try await ownerDatabase.write { db in try HerdrAgentStore.markOpened(id, at: openedAt, in: db) }
    }
}
