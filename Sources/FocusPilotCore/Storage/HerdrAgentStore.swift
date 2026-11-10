import Foundation
import GRDB

/// Task–agent links and the Review queue. Each function runs inside the
/// caller's single write or read. Nothing here changes a task: an agent
/// finishing never completes it and never touches Now.
enum HerdrAgentStore {
    /// Links the agent and, if it is already waiting at an approval, queues
    /// that request: from here on only changes count, so it would never be
    /// queued otherwise. Linking it again changes nothing.
    static func link(_ agent: HerdrAgent, on server: HerdrServer, workspaceLabel: String?, toTask taskID: Int64,
                     at now: Date, in db: Database) throws -> (TaskAgentLink, NewReviewItem?) {
        if let existing = try AgentLinkRow
            .filter(Column("taskId") == taskID && Column("socketPath") == server.socketPath
                && Column("serverStartedAt") == server.startedAtMilliseconds && Column("paneId") == agent.paneID)
            .fetchOne(db) {
            return (existing.link, nil)
        }
        var row = AgentLinkRow(id: nil, taskId: taskID, sessionName: server.sessionName, socketPath: server.socketPath,
                               serverStartedAt: server.startedAtMilliseconds, paneId: agent.paneID,
                               workspaceId: agent.workspaceID, tabId: agent.tabID, agentName: agent.name,
                               agentKind: agent.kind, label: agent.name ?? agent.title ?? agent.kind,
                               workspaceLabel: workspaceLabel,
                               lastStatus: AgentTransition.lastKnown(previous: nil, current: agent.status)?.rawValue,
                               statusChangedAt: now)
        try row.insert(db)
        let approval = AgentTransition.review(from: nil, to: agent.status) == .approval
            ? try queue(.approval, for: row, summary: agent.title, at: now, in: db) : nil
        return (row.link, approval)
    }

    static func links(forTask taskID: Int64?, in db: Database) throws -> [TaskAgentLink] {
        let all = AgentLinkRow.order(Column("id"))
        return try (taskID.map { all.filter(Column("taskId") == $0) } ?? all).fetchAll(db).map(\.link)
    }

    /// Updates each linked agent's last known status from Herdr's list and
    /// queues what its change means. Agents in another server instance, or a
    /// different agent in the same pane, are left alone; an approval asked
    /// from a pane that is gone, replaced or from before a restart of this
    /// Herdr server can no longer be answered, so it is cleared.
    static func record(_ agents: [HerdrAgent], on server: HerdrServer, at now: Date,
                       in db: Database) throws -> [NewReviewItem] {
        let rows = try AgentLinkRow.filter(Column("socketPath") == server.socketPath).fetchAll(db)
        var queued: [NewReviewItem] = []
        for var row in rows {
            guard let agent = agents.first(where: { row.link.isSameAgent(as: $0, on: server) }) else {
                switch AgentLinkState(row.link, .connected(server, agents)) {
                case .replaced, .notFound: try clearApprovals(forLink: row.id!, in: db)
                case .live, .renamed, .unknown: break
                }
                continue
            }
            let previous = row.link.lastStatus
            let known = AgentTransition.lastKnown(previous: previous, current: agent.status)
            if known != previous {
                row.lastStatus = known?.rawValue
                row.statusChangedAt = now
                try row.update(db)
            }
            // Answered in Herdr: the request no longer needs the owner. An
            // unknown reading says nothing, so the request stays.
            if agent.status != .blocked && agent.status != .unknown {
                try clearApprovals(forLink: row.id!, in: db)
            }
            guard let kind = AgentTransition.review(from: previous, to: agent.status) else { continue }
            try queued.append(queue(kind, for: row, summary: agent.title, at: now, in: db))
        }
        return queued
    }

    /// Stops watching the agent. Its results stay queued; an approval
    /// request goes, since nothing would ever clear it.
    static func unlink(_ linkID: Int64, in db: Database) throws {
        try clearApprovals(forLink: linkID, in: db)
        _ = try AgentLinkRow.deleteOne(db, key: linkID)
    }

    private static func queue(_ kind: AgentTransition.Review, for row: AgentLinkRow, summary: String?, at now: Date,
                              in db: Database) throws -> NewReviewItem {
        var item = ReviewItemRow(id: nil, taskId: row.taskId, linkId: row.id, kind: kind.rawValue, occurredAt: now,
                                 agentLabel: row.label, workspaceLabel: row.workspaceLabel, summary: summary,
                                 outputText: nil, outputLineCount: nil, reviewedAt: nil)
        try item.insert(db)
        return NewReviewItem(id: item.id!, paneID: row.paneId, server: row.link.server)
    }

    private static func clearApprovals(forLink linkID: Int64, in db: Database) throws {
        try ReviewItemRow
            .filter(Column("linkId") == linkID && Column("kind") == AgentTransition.Review.approval.rawValue
                && Column("reviewedAt") == nil)
            .deleteAll(db)
    }

    /// Follows the agent under its new name. Only the name may differ: the
    /// pane and program must be the linked ones.
    static func relink(_ linkID: Int64, to agent: HerdrAgent, in db: Database) throws {
        guard var row = try AgentLinkRow.fetchOne(db, key: linkID), row.paneId == agent.paneID, row.agentKind == agent.kind
        else { throw HerdrAgentLinkError.differentAgent }
        row.agentName = agent.name
        row.label = agent.name ?? agent.title ?? agent.kind
        try row.update(db)
    }

    static func storeOutput(_ output: AgentOutputPreview, forReviewItem id: Int64, in db: Database) throws {
        try db.execute(sql: "UPDATE herdrReviewItem SET outputText = ?, outputLineCount = ? WHERE id = ?",
                       arguments: [output.storedText, output.totalLineCount, id])
    }

    /// Unreviewed items, newest first, with older results from the same
    /// agent superseded.
    static func queue(in db: Database) throws -> [ReviewItem] {
        try ReviewItem.markingSuperseded(Row.fetchAll(db, sql: """
            SELECT herdrReviewItem.*, task.title AS taskTitle FROM herdrReviewItem
            JOIN task ON task.id = herdrReviewItem.taskId
            WHERE reviewedAt IS NULL ORDER BY occurredAt DESC, herdrReviewItem.id DESC
            """).map { row in
            let text: String? = row["outputText"]
            return ReviewItem(id: row["id"], taskID: row["taskId"], taskTitle: row["taskTitle"], linkID: row["linkId"],
                              kind: AgentTransition.Review(rawValue: row["kind"])!, occurredAt: row["occurredAt"],
                              agentLabel: row["agentLabel"], workspaceLabel: row["workspaceLabel"], summary: row["summary"],
                              output: text.map { AgentOutputPreview(storedText: $0, totalLineCount: row["outputLineCount"]) },
                              reportedAgentID: row["reportedAgentId"],
                              source: (row["source"] as String?).flatMap(AgentSource.init(rawValue:)),
                              agentState: (row["agentState"] as String?).flatMap(ReportedAgentState.init(rawValue:)),
                              openedAt: row["openedAt"])
        })
    }

    static func markReviewed(_ id: Int64, at now: Date, in db: Database) throws {
        try db.execute(sql: "UPDATE herdrReviewItem SET reviewedAt = ? WHERE id = ?", arguments: [now, id])
    }

    /// Keeps the first time it was opened; opening it again changes nothing.
    static func markOpened(_ id: Int64, at now: Date, in db: Database) throws {
        try db.execute(sql: "UPDATE herdrReviewItem SET openedAt = ? WHERE id = ? AND openedAt IS NULL",
                       arguments: [now, id])
    }
}

public enum HerdrAgentLinkError: Error, Equatable {
    case differentAgent
}

/// `herdrAgentLink` as stored.
struct AgentLinkRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "herdrAgentLink"

    var id: Int64?
    var taskId: Int64
    var sessionName: String
    var socketPath: String
    var serverStartedAt: Int64
    var paneId: String
    var workspaceId: String
    var tabId: String
    var agentName: String?
    var agentKind: String
    var label: String
    var workspaceLabel: String?
    var lastStatus: String?
    var statusChangedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var link: TaskAgentLink {
        let server = HerdrServer(sessionName: sessionName, socketPath: socketPath,
                                 startedAt: Date(timeIntervalSince1970: Double(serverStartedAt) / 1000))
        return TaskAgentLink(id: id!, taskID: taskId, server: server, paneID: paneId, workspaceID: workspaceId,
                             tabID: tabId, name: agentName, kind: agentKind, label: label, workspaceLabel: workspaceLabel,
                             lastStatus: lastStatus.flatMap(HerdrAgentStatus.init(rawValue:)),
                             statusChangedAt: statusChangedAt)
    }
}

/// `herdrReviewItem` as stored.
struct ReviewItemRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "herdrReviewItem"

    var id: Int64?
    var taskId: Int64
    var linkId: Int64?
    var kind: String
    var occurredAt: Date
    var agentLabel: String
    var workspaceLabel: String?
    var summary: String?
    var outputText: String?
    var outputLineCount: Int?
    var reviewedAt: Date?
    var reportedAgentId: Int64? = nil
    var source: String? = nil
    var agentState: String? = nil
    var openedAt: Date? = nil

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
