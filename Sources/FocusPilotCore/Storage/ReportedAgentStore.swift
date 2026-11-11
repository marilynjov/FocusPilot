import Foundation
import GRDB

/// Reported agents (decision 0005, step 1) and the agent monitoring
/// setting. Each function runs inside the caller's single write or read.
/// Like Herdr links, nothing here changes a task: a finished agent never
/// completes it and never touches Now.
enum ReportedAgentStore {
    /// Agents that have not reported for this long are forgotten; their
    /// results stay in the Review queue under their label.
    static let retention: TimeInterval = 7 * 24 * 3600

    static func isMonitoring(in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM agentMonitoring)") ?? false
    }

    /// Turning it on again keeps when it was first turned on.
    static func setMonitoring(_ on: Bool, at now: Date, in db: Database) throws {
        if on {
            try db.execute(sql: "INSERT INTO agentMonitoring (id, since) VALUES (1, ?) ON CONFLICT(id) DO NOTHING",
                           arguments: [now])
        } else {
            try db.execute(sql: "DELETE FROM agentMonitoring")
        }
    }

    /// At most this many agents FocusPilot has never heard from may start
    /// reporting in any minute, so a process making up agents can't fill
    /// the Agent panel.
    static let newAgentsPerMinute = 10

    /// The earliest a report may say it was sent, before now.
    static let oldestReport: TimeInterval = 300

    enum Refusal: Error, Equatable {
        case tooManyNewAgents
    }

    /// Records a sanitized report. Nil, writing nothing, while agent
    /// monitoring is off. `home` is the owner's home folder, which an
    /// owner's link may not cover (see `AgentTaskMatch`).
    static func record(_ report: AgentReport, at now: Date, home: String = NSHomeDirectory(),
                       in db: Database) throws -> AgentReportReceipt? {
        guard try isMonitoring(in: db) else { return nil }
        try ReportedAgentRow.filter(Column("lastReportAt") < now.addingTimeInterval(-retention)).deleteAll(db)

        // The time the CLI started, never later than now nor more than
        // `oldestReport` before it: a report's own claim about time is
        // untrusted too, and one far in the past would otherwise never
        // count as news.
        let reportedAt = max(now.addingTimeInterval(-oldestReport), min(report.reportedAt ?? now, now))
        let state = report.status.state
        let existing = try ReportedAgentRow
            .filter(Column("source") == report.source.rawValue && Column("agentKey") == report.identity)
            .fetchOne(db)
        if existing == nil {
            let recent = try ReportedAgentRow.filter(Column("firstReportAt") > now.addingTimeInterval(-60)).fetchCount(db)
            guard recent < newAgentsPerMinute else { throw Refusal.tooManyNewAgents }
        }
        var row = existing ?? ReportedAgentRow(
            id: nil, source: report.source.rawValue, agentKey: report.identity, label: report.label, folder: report.folder,
            taskId: nil, linkedByOwner: false, state: state.rawValue, lastMessage: nil, firstReportAt: now,
            lastReportAt: reportedAt, stateChangedAt: reportedAt)
        let previous = existing.map { (state: $0.agent.state(at: now), message: $0.lastMessage) }
        // Async hooks can arrive out of order, e.g. a turn's Stop after the
        // next prompt. An older report is already out of date: it changes
        // neither the state nor the message, which came with the newer one.
        // It still fills in what the agent never said, and a finished
        // turn in it is still a result.
        let isStale = existing.map { reportedAt < $0.lastReportAt } ?? false

        if !row.linkedByOwner {
            let explicit = try report.taskID.flatMap { try isOpen($0, in: db) ? $0 : nil }
            if let explicit {
                row.taskId = explicit
            } else if row.taskId == nil {
                row.taskId = try AgentTaskMatch.task(explicit: nil, folder: report.folder ?? row.folder,
                                                     links: folderLinks(in: db), openTasks: openTasks(in: db), home: home)
            }
        }
        // A made-up label never replaces one the agent gave.
        if existing == nil || (!report.labelIsFallback && !isStale) { row.label = report.label }
        if isStale {
            row.folder = row.folder ?? report.folder
            row.terminalApp = row.terminalApp ?? report.terminal.app
            row.terminalTTY = row.terminalTTY ?? report.terminal.tty
            row.terminalSession = row.terminalSession ?? report.terminal.sessionID
            row.warpWindow = row.warpWindow ?? report.warpWindow
        } else {
            row.folder = report.folder ?? row.folder
            row.terminalApp = report.terminal.app ?? row.terminalApp
            row.terminalTTY = report.terminal.tty ?? row.terminalTTY
            row.terminalSession = report.terminal.sessionID ?? row.terminalSession
            row.warpWindow = report.warpWindow ?? row.warpWindow
            if row.state != state.rawValue { row.stateChangedAt = reportedAt }
            row.state = state.rawValue
            row.lastMessage = report.summary
            row.lastReportAt = reportedAt
        }
        try row.save(db)

        // Each finished turn or run is a result, once: the same result
        // reported again is not queued twice. A late one is compared with
        // the agent's queued results, since the state has moved on.
        var queued = false
        let text = report.summary ?? (state == .failed ? "The agent reported that it failed." : "The agent reported that it finished.")
        let isNew = isStale
            ? try ReviewItemRow.filter(Column("reportedAgentId") == row.id && Column("outputText") == text
                && Column("agentState") == state.rawValue).fetchCount(db) == 0
            : previous.map { $0.state != state || $0.message != report.summary } ?? true
        if state == .ready || state == .failed, let taskId = row.taskId, isNew {
            let lines = text.components(separatedBy: "\n")
            var item = ReviewItemRow(id: nil, taskId: taskId, linkId: nil, kind: AgentTransition.Review.finished.rawValue,
                                     occurredAt: reportedAt, agentLabel: row.label,
                                     workspaceLabel: row.folder.map(Self.folderName),
                                     summary: lines.first, outputText: text, outputLineCount: lines.count, reviewedAt: nil,
                                     reportedAgentId: row.id, source: row.source, agentState: state.rawValue)
            try item.insert(db)
            queued = true
        }
        let taskTitle = try row.taskId.flatMap { try String.fetchOne(db, sql: "SELECT title FROM task WHERE id = ?", arguments: [$0]) }
        let current = ReportedAgentState(rawValue: row.state) ?? state
        return AgentReportReceipt(agentID: row.id!, label: row.label, state: current,
                                  needsYouNow: !isStale && state == .needsYou, queuedResult: queued, taskTitle: taskTitle)
    }

    static func agents(in db: Database) throws -> [ReportedAgent] {
        try ReportedAgentRow.order(Column("lastReportAt").desc, Column("id").desc).fetchAll(db).map(\.agent)
    }

    /// The owner links the agent to a task, or unlinks it with nil. Either
    /// way folder matching leaves it alone from then on.
    static func link(_ agentID: Int64, toTask taskID: Int64?, in db: Database) throws {
        try db.execute(sql: "UPDATE reportedAgent SET taskId = ?, linkedByOwner = 1 WHERE id = ?",
                       arguments: [taskID, agentID])
    }

    /// Removes the agent; its results stay in the Review queue.
    static func forget(_ agentID: Int64, in db: Database) throws {
        _ = try ReportedAgentRow.deleteOne(db, key: agentID)
    }

    /// The last folder name, shown where Herdr shows the workspace.
    static func folderName(_ folder: String) -> String {
        let name = (folder as NSString).lastPathComponent
        return name.isEmpty ? folder : name
    }

    private static func isOpen(_ taskID: Int64, in db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM task WHERE id = ? AND status != 'done')",
                          arguments: [taskID]) ?? false
    }

    private static func openTasks(in db: Database) throws -> Set<Int64> {
        Set(try Int64.fetchAll(db, sql: "SELECT id FROM task WHERE status != 'done'"))
    }

    /// The owner's own links of agents in a folder to a task, newest first,
    /// then the folder of the Now task's project's Herdr workspace.
    private static func folderLinks(in db: Database) throws -> [AgentTaskMatch.FolderLink] {
        let owner = try Row.fetchAll(db, sql: """
            SELECT folder, taskId FROM reportedAgent
            WHERE linkedByOwner = 1 AND taskId IS NOT NULL AND folder IS NOT NULL
            ORDER BY lastReportAt DESC, id DESC
            """).map { AgentTaskMatch.FolderLink(folder: $0["folder"], taskID: $0["taskId"], kind: .task) }
        let project = try Row.fetchAll(db, sql: """
            SELECT herdrLink.cwd AS folder, task.id AS taskId FROM task
            JOIN herdrLink ON herdrLink.projectId = task.projectId
            WHERE task.status = 'now' AND herdrLink.cwd IS NOT NULL
            """).map { AgentTaskMatch.FolderLink(folder: $0["folder"], taskID: $0["taskId"], kind: .project) }
        return owner + project
    }
}

/// `reportedAgent` as stored.
struct ReportedAgentRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "reportedAgent"

    var id: Int64?
    var source: String
    var agentKey: String
    var label: String
    var folder: String?
    var taskId: Int64?
    var linkedByOwner: Bool
    var state: String
    var lastMessage: String?
    var firstReportAt: Date
    var lastReportAt: Date
    var stateChangedAt: Date
    var terminalApp: String? = nil
    var terminalTTY: String? = nil
    var terminalSession: String? = nil
    var warpWindow: String? = nil

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var agent: ReportedAgent {
        ReportedAgent(id: id!, source: AgentSource(rawValue: source) ?? .command, key: agentKey, label: label,
                      folder: folder, taskID: taskId, isLinkedByOwner: linkedByOwner,
                      reportedState: ReportedAgentState(rawValue: state) ?? .working, lastMessage: lastMessage,
                      lastReportAt: lastReportAt, stateChangedAt: stateChangedAt,
                      terminal: TerminalPlace(app: terminalApp, tty: terminalTTY, sessionID: terminalSession),
                      warpWindow: warpWindow)
    }
}
