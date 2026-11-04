import Foundation

/// Claude Code's hook events FocusPilot listens to, and the report each
/// one makes. Event names, fields and notification types are from Claude
/// Code's hooks reference, https://code.claude.com/docs/en/hooks (read
/// 2026-11-03); see docs/agents/claude-code-hooks.md.
public enum ClaudeHookEvent: String, CaseIterable, Sendable {
    /// A session starts, resumes, or is cleared or compacted: Working.
    case sessionStart = "SessionStart"
    /// The owner sent a prompt (or Claude Code started a turn itself): Working.
    case userPromptSubmit = "UserPromptSubmit"
    /// Claude Code wants the owner: Needs you, for the types in `needsYouTypes`.
    case notification = "Notification"
    /// The main agent finished responding: Ready, with its last message.
    case stop = "Stop"

    /// Notification types that mean Claude is waiting on the owner.
    /// `idle_prompt` is left out: it follows a finished turn by a minute,
    /// which `Stop` already reported as Ready.
    static let needsYouTypes: Set<String> = ["permission_prompt", "elicitation_dialog", "elicitation_url_dialog",
                                             "agent_needs_input", "quota_auto_resume_stale"]

    /// The most of the hook's JSON read; a larger payload is not parsed.
    public static let payloadLimit = 4 * 1024 * 1024

    /// What one hook call comes to.
    public enum Outcome: Equatable, Sendable {
        case report(AgentReport)
        /// Nothing to report, e.g. a notification that is not a request.
        case ignore
        /// The payload could not be read.
        case unreadable
    }

    /// The fields read from the hook's stdin; the rest is ignored.
    struct Payload: Decodable {
        var session_id: String?
        var cwd: String?
        var hook_event_name: String?
        var session_title: String?
        var message: String?
        var notification_type: String?
        var last_assistant_message: String?
        var background_tasks: [Ignored]?
    }

    /// Any JSON value, unread.
    struct Ignored: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    /// The report for this event's payload. `name` is `--name`, if given;
    /// otherwise the session's title, else "Claude Code · <folder>".
    /// `terminal` is what the hook's process knows of its terminal.
    /// `session_title` comes only with SessionStart and UserPromptSubmit, so
    /// a label made from the folder is marked as a fallback.
    public func outcome(payload data: Data, name: String?, terminal: TerminalPlace) -> Outcome {
        guard data.count <= Self.payloadLimit, let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return .unreadable
        }
        let status: AgentReport.Status
        var summary: String?
        switch self {
        case .sessionStart, .userPromptSubmit:
            // The prompt itself is never kept.
            status = .working
        case .notification:
            guard let type = payload.notification_type, Self.needsYouTypes.contains(type) else { return .ignore }
            status = .needsInput
            summary = payload.message
        case .stop:
            // Background work still running will wake the session again.
            if let tasks = payload.background_tasks, !tasks.isEmpty {
                status = .working
                summary = tasks.count == 1 ? "Waiting for 1 background task" : "Waiting for \(tasks.count) background tasks"
            } else {
                status = .done
                summary = payload.last_assistant_message
            }
        }
        let folder = payload.cwd.flatMap { $0.isEmpty ? nil : $0 }
        let place = folder.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty || $0 == "/" ? nil : $0 }
        let given = [name, payload.session_title].compactMap { $0 }.first { AgentText.line($0, limit: 80) != nil }
        let label = given ?? (place.map { "Claude Code · \($0)" } ?? "Claude Code")
        return .report(AgentReport(source: .claudeCodeHook, status: status, label: label,
                                   key: payload.session_id.flatMap { $0.isEmpty ? nil : $0 }, folder: folder,
                                   summary: summary, terminal: terminal, labelIsFallback: given == nil))
    }
}
