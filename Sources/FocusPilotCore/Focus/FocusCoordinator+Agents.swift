import Foundation

/// Herdr agents linked to tasks. Polling only reads Herdr. The one action
/// that changes what the owner sees in Herdr is `openAgent`, which the app
/// calls only for the owner's click on Open agent; nothing here restores a
/// previous focus. Results go to the Review queue and never change Now or
/// complete a task.
extension FocusCoordinator {
    public enum OpenAgentResult: Equatable, Sendable {
        case opened
        /// The agent in the pane has a new name; the owner can relink it.
        case renamed(String)
        /// The pane holds a different agent now.
        case replaced
        /// The link is gone, the pane is gone, or Herdr restarted.
        case notFound
        case herdrUnavailable
    }

    /// Reads the linked agents' status and queues their results. Herdr is not
    /// asked at all while no task has a linked agent; nil then.
    public func refreshHerdrAgents() async -> HerdrAgents? {
        await oneAgentReadingAtATime {
            guard let agents = self.agents, (try? await self.repository.agentLinks().isEmpty) == false else { return nil }
            let current = await agents.agents()
            await self.record(current)
            return current
        }
    }

    /// Herdr's agents now, for choosing one to link. Nothing is recorded.
    public func availableAgents() async -> HerdrAgents {
        await agents?.agents() ?? .disconnected(.binaryNotFound)
    }

    public func linkAgent(_ agent: HerdrAgent, on server: HerdrServer, workspaceLabel: String?,
                          toTask taskID: Int64) async throws -> TaskAgentLink {
        let link = try await oneAgentReadingAtATime {
            let (link, queued) = try await self.repository.linkAgentQueuing(agent, on: server,
                                                                            workspaceLabel: workspaceLabel, toTask: taskID)
            if let queued { await self.storeOutput(of: queued) }
            return link
        }
        await broadcast()
        return link
    }

    public func unlinkAgent(_ linkID: Int64) async throws {
        try await repository.unlinkAgent(linkID)
        await broadcast()
    }

    public func agentLinks() async throws -> [TaskAgentLink] {
        try await repository.agentLinks()
    }

    /// The owner's Relink after a rename: follows the agent under its new
    /// name. Returns false, changing nothing, unless Herdr shows it renamed.
    public func relinkAgent(_ linkID: Int64) async -> Bool {
        guard let agents, let link = try? await repository.agentLinks().first(where: { $0.id == linkID }),
              case .renamed(let current) = AgentLinkState(link, await agents.agents()),
              (try? await repository.relinkAgent(linkID, to: current)) != nil
        else { return false }
        await broadcast()
        return true
    }

    public func reviewQueue() async throws -> [ReviewItem] {
        try await repository.reviewQueue()
    }

    public func markReviewed(_ itemID: Int64) async throws {
        try await repository.markReviewed(itemID)
    }

    public func markOpened(_ itemID: Int64) async throws {
        try await repository.markOpened(itemID)
    }

    /// Focuses the linked agent's pane in Herdr, for the owner's click only.
    ///
    /// The target is revalidated right before: same server instance, same
    /// pane, same agent. Its status is recorded first, because focusing marks
    /// a finished agent as seen and Herdr then reports it as idle.
    public func openAgent(_ linkID: Int64) async -> OpenAgentResult {
        await oneAgentReadingAtATime { await self.focusAgent(linkID) }
    }

    private func focusAgent(_ linkID: Int64) async -> OpenAgentResult {
        guard let agents, let link = try? await repository.agentLinks().first(where: { $0.id == linkID }) else {
            return .notFound
        }
        let current = await agents.agents()
        guard case .connected(let server, _) = current else { return .herdrUnavailable }
        await record(current)
        switch AgentLinkState(link, current) {
        case .live: return await agents.focus(link.paneID, on: server) ? .opened : .herdrUnavailable
        case .renamed(let agent): return .renamed(agent.name ?? agent.kind)
        case .replaced: return .replaced
        case .notFound: return .notFound
        case .unknown: return .herdrUnavailable
        }
    }

    /// Stores the agents' status and reads each new item's output once.
    private func record(_ current: HerdrAgents) async {
        guard case .connected(let server, let list) = current,
              let queued = try? await repository.recordAgents(list, on: server)
        else { return }
        for item in queued { await storeOutput(of: item) }
    }

    private func storeOutput(of item: NewReviewItem) async {
        guard let text = await agents?.output(of: item.paneID, on: item.server) else { return }
        try? await repository.storeOutput(AgentOutputPreview(text), forReviewItem: item.id)
    }

    /// Runs `work` after every earlier reading of Herdr's agents has been
    /// recorded. The coordinator is suspended while `herdr` runs, so without
    /// this a poll that read "working" could record it after Open agent
    /// recorded "done" and focused, and the next poll would count the same
    /// run as finished a second time.
    private func oneAgentReadingAtATime<T: Sendable>(_ work: @escaping @Sendable () async -> T) async -> T {
        let earlier = agentReading
        let this = Task { await earlier?.value; return await work() }
        agentReading = Task { _ = await this.value }
        return await this.value
    }

    private func oneAgentReadingAtATime<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let outcome: Result<T, any Error> = await oneAgentReadingAtATime {
            do { return .success(try await work()) } catch { return .failure(error) }
        }
        return try outcome.get()
    }
}
