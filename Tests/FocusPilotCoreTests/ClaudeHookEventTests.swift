import Foundation
import Testing
@testable import FocusPilotCore

/// Claude Code's hook JSON, as the hooks reference shows it
/// (code.claude.com/docs/en/hooks, read 2026-11-03), turned into reports.
@Suite("Claude Code hook payloads")
struct ClaudeHookEventTests {
    private let warp = TerminalPlace(app: "WarpTerminal", tty: "/dev/ttys004")

    // Fixtures shaped like the reference's examples.
    private let sessionStart = """
        {"session_id":"abc123","transcript_path":"/Users/o/.claude/projects/x/abc123.jsonl",
         "cwd":"/Users/o/Projects/nlp","hook_event_name":"SessionStart","source":"startup","model":"claude-opus-5"}
        """
    private let promptSubmit = """
        {"session_id":"abc123","transcript_path":"/t.jsonl","cwd":"/Users/o/Projects/nlp","permission_mode":"default",
         "hook_event_name":"UserPromptSubmit","prompt":"Write a function","session_title":"Ablation fixes"}
        """
    private let permission = """
        {"session_id":"abc123","transcript_path":"/t.jsonl","cwd":"/Users/o/Projects/nlp","hook_event_name":"Notification",
         "message":"Claude needs your permission to use Bash","title":"Permission needed","notification_type":"permission_prompt"}
        """
    private let idle = """
        {"session_id":"abc123","cwd":"/Users/o/Projects/nlp","hook_event_name":"Notification",
         "message":"Claude is waiting for your input","notification_type":"idle_prompt"}
        """
    private let stop = """
        {"session_id":"abc123","transcript_path":"/t.jsonl","cwd":"/Users/o/Projects/nlp","permission_mode":"default",
         "hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"The table is updated.\\nAll tests pass.",
         "background_tasks":[],"session_crons":[],"effort":{"level":"high"}}
        """
    private let stopWithBackgroundWork = """
        {"session_id":"abc123","cwd":"/Users/o/Projects/nlp","hook_event_name":"Stop","stop_hook_active":false,
         "last_assistant_message":"Started the tests.",
         "background_tasks":[{"id":"t1","type":"shell","status":"running","description":"tests","command":"swift test"}],
         "session_crons":[]}
        """

    private func report(_ event: ClaudeHookEvent, _ json: String, name: String? = nil) throws -> AgentReport {
        guard case .report(let report) = event.outcome(payload: Data(json.utf8), name: name, terminal: warp) else {
            throw CancellationError()
        }
        return report
    }

    @Test func aNewSessionIsWorkingInItsFolder() throws {
        let report = try report(.sessionStart, sessionStart)
        #expect(report.source == .claudeCodeHook)
        #expect(report.status == .working)
        #expect(report.label == "Claude Code · nlp")
        #expect(report.key == "abc123")
        #expect(report.folder == "/Users/o/Projects/nlp")
        #expect(report.summary == nil)
        #expect(report.terminal == warp)
    }

    @Test func aPromptIsWorkingAndThePromptIsNotKept() throws {
        let report = try report(.userPromptSubmit, promptSubmit)
        #expect(report.status == .working)
        #expect(report.summary == nil)
        // A session's own title names it.
        #expect(report.label == "Ablation fixes")
    }

    @Test func aGivenNameWinsOverTheTitle() throws {
        #expect(try report(.userPromptSubmit, promptSubmit, name: "ablation").label == "ablation")
    }

    @Test func aPermissionPromptNeedsYouWithItsMessage() throws {
        let report = try report(.notification, permission)
        #expect(report.status == .needsInput)
        #expect(report.summary == "Claude needs your permission to use Bash")
    }

    @Test func otherNotificationsAreIgnored() {
        #expect(ClaudeHookEvent.notification.outcome(payload: Data(idle.utf8), name: nil, terminal: warp) == .ignore)
        let auth = #"{"session_id":"a","cwd":"/p","hook_event_name":"Notification","message":"ok","notification_type":"auth_success"}"#
        #expect(ClaudeHookEvent.notification.outcome(payload: Data(auth.utf8), name: nil, terminal: warp) == .ignore)
    }

    @Test func aFinishedTurnIsReadyWithTheLastMessage() throws {
        let report = try report(.stop, stop)
        #expect(report.status == .done)
        #expect(report.summary == "The table is updated.\nAll tests pass.")
    }

    @Test func aTurnWaitingForBackgroundWorkIsStillWorking() throws {
        let report = try report(.stop, stopWithBackgroundWork)
        #expect(report.status == .working)
        #expect(report.summary == "Waiting for 1 background task")
    }

    @Test func unreadableOrOversizedPayloadsReportNothing() {
        #expect(ClaudeHookEvent.stop.outcome(payload: Data("not json".utf8), name: nil, terminal: warp) == .unreadable)
        let huge = Data(count: ClaudeHookEvent.payloadLimit + 1)
        #expect(ClaudeHookEvent.stop.outcome(payload: huge, name: nil, terminal: warp) == .unreadable)
    }

    @Test func noFolderStillNamesClaudeCode() throws {
        let report = try report(.stop, #"{"session_id":"a","hook_event_name":"Stop"}"#)
        #expect(report.label == "Claude Code")
        #expect(report.folder == nil)
        #expect(report.summary == nil)
    }
}
