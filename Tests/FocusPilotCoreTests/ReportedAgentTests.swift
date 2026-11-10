import Foundation
import Testing
@testable import FocusPilotCore

/// Reported agents (decision 0005, step 1) without storage: cleaning a
/// report, reading Claude Code's hook JSON, the state going Unknown,
/// matching a folder to a task, and where Go to agent goes.
@Suite("Reported agents")
struct ReportedAgentTests {
    // MARK: Cleaning a report

    @Test func aReportIsCappedAndCleaned() throws {
        let raw = AgentReport(source: .command, status: .done, label: "  re\u{202E}view\tbot\n" + String(repeating: "a", count: 200),
                              summary: "Line one\u{1B}[31m\n\n\n\nLine\u{0007} two " + String(repeating: "b", count: 3000))
        let (report, notes) = try raw.sanitized()

        #expect(report.label.count == AgentReport.labelLimit)
        #expect(report.label.hasPrefix("review bot aaa"))
        #expect(report.label.hasSuffix("…"))
        let summary = try #require(report.summary)
        #expect(summary.count == AgentReport.summaryLimit)
        // The escape and bell are gone; blank lines collapse to one.
        #expect(summary.hasPrefix("Line one[31m\n\nLine two bbb"))
        #expect(notes.isEmpty)
    }

    @Test func aLabelWithNothingPrintableIsRefused() {
        #expect(throws: AgentReport.Invalid.missingLabel) {
            try AgentReport(source: .command, status: .working, label: " \u{200B}\u{0007} ").sanitized()
        }
    }

    @Test func optionalFieldsThatDoNotLookRightAreDroppedWithANote() throws {
        let raw = AgentReport(source: .command, status: .working, label: "bot", key: "has space",
                              folder: "relative/path",
                              terminal: TerminalPlace(app: "Warp; rm -rf /", tty: "/dev/../etc/passwd", sessionID: "ok-1"),
                              taskID: -3)
        let (report, notes) = try raw.sanitized()

        #expect(report.key == nil)
        #expect(report.folder == nil)
        #expect(report.terminal == TerminalPlace(app: nil, tty: nil, sessionID: "ok-1"))
        #expect(report.taskID == nil)
        #expect(notes.count == 5)
    }

    @Test func goodFieldsAreKept() throws {
        let raw = AgentReport(source: .claudeCodeHook, status: .needsInput, label: "Claude Code · nlp",
                              key: "0b4a2e9c-1d2f-4c3b-9a8e-123456789abc", folder: "/Users/owner/nlp/./src/..",
                              terminal: TerminalPlace(app: "iTerm.app", tty: "ttys003", sessionID: "w0t1p0:ABC-123"),
                              taskID: 4)
        let (report, notes) = try raw.sanitized()

        #expect(report.folder == "/Users/owner/nlp")
        #expect(report.terminal == TerminalPlace(app: "iTerm.app", tty: "/dev/ttys003", sessionID: "w0t1p0:ABC-123"))
        #expect(report.taskID == 4)
        #expect(report.status.state == .needsYou)
        #expect(notes.isEmpty)
    }

    @Test func statusesMapToStates() {
        #expect(AgentReport.Status.allCases.map(\.state) == [.working, .needsYou, .ready, .failed])
        #expect(AgentReport.Status(rawValue: "needs-input") == .needsInput)
    }

    // MARK: Going Unknown

    private func agent(_ state: ReportedAgentState, reportedAt: Date) -> ReportedAgent {
        ReportedAgent(id: 1, source: .claudeCodeHook, key: "s1", label: "bot", folder: nil, taskID: nil,
                      isLinkedByOwner: false, reportedState: state, lastMessage: nil, lastReportAt: reportedAt,
                      stateChangedAt: reportedAt, terminal: TerminalPlace())
    }

    @Test func workingGoesUnknownAfterThirtyMinutesWithoutAReport() {
        let start = wednesdayMorningInBogota
        let working = agent(.working, reportedAt: start)
        #expect(working.state(at: start.addingTimeInterval(29 * 60)) == .working)
        #expect(working.state(at: start.addingTimeInterval(31 * 60)) == .unknown)
        #expect(working.goesUnknownAt == start.addingTimeInterval(30 * 60))
    }

    @Test func needsYouWaitsLongerButNotForever() {
        let start = wednesdayMorningInBogota
        let waiting = agent(.needsYou, reportedAt: start)
        #expect(waiting.state(at: start.addingTimeInterval(90 * 60)) == .needsYou)
        #expect(waiting.state(at: start.addingTimeInterval(3 * 3600)) == .unknown)
    }

    @Test func readyAndFailedAreTheLastWordAndStay() {
        let start = wednesdayMorningInBogota
        for state in [ReportedAgentState.ready, .failed] {
            #expect(agent(state, reportedAt: start).state(at: start.addingTimeInterval(86_400)) == state)
            #expect(agent(state, reportedAt: start).goesUnknownAt == nil)
        }
    }

    // MARK: Matching a folder to a task

    private let open: Set<Int64> = [1, 2, 3]
    private let home = "/Users/o"

    @Test func anExplicitOpenTaskWins() {
        let links = [AgentTaskMatch.FolderLink(folder: "/p", taskID: 2, kind: .task)]
        #expect(AgentTaskMatch.task(explicit: 3, folder: "/p", links: links, openTasks: open, home: home) == 3)
        // A closed or unknown task is ignored, and the folder decides.
        #expect(AgentTaskMatch.task(explicit: 9, folder: "/p", links: links, openTasks: open, home: home) == 2)
    }

    @Test func theClosestFolderWinsByWholeComponents() {
        let links = [AgentTaskMatch.FolderLink(folder: "/Users/o/nlp", taskID: 1, kind: .project),
                     AgentTaskMatch.FolderLink(folder: "/Users/o/nlp/paper", taskID: 2, kind: .project)]
        #expect(AgentTaskMatch.task(explicit: nil, folder: "/Users/o/nlp/paper/figs", links: links, openTasks: open, home: home) == 2)
        #expect(AgentTaskMatch.task(explicit: nil, folder: "/Users/o/nlp/code", links: links, openTasks: open, home: home) == 1)
        #expect(AgentTaskMatch.task(explicit: nil, folder: "/Users/o/nlp-old", links: links, openTasks: open, home: home) == nil)
        #expect(AgentTaskMatch.task(explicit: nil, folder: nil, links: links, openTasks: open, home: home) == nil)
    }

    @Test func onATieTheOwnersLinkThenTheNewestWins() {
        let links = [AgentTaskMatch.FolderLink(folder: "/p", taskID: 1, kind: .project),
                     AgentTaskMatch.FolderLink(folder: "/p", taskID: 2, kind: .task),
                     AgentTaskMatch.FolderLink(folder: "/p", taskID: 3, kind: .task)]
        #expect(AgentTaskMatch.task(explicit: nil, folder: "/p", links: links, openTasks: open, home: home) == 2)
    }

    @Test func anOwnersLinkHoldsItsFolderOnly() {
        let links = [AgentTaskMatch.FolderLink(folder: "/Users/o/thesis", taskID: 2, kind: .task),
                     AgentTaskMatch.FolderLink(folder: "/Users/o", taskID: 3, kind: .task)]
        #expect(AgentTaskMatch.task(explicit: nil, folder: "/Users/o/thesis", links: links, openTasks: open, home: home) == 2)
        #expect(AgentTaskMatch.task(explicit: nil, folder: "/Users/o/thesis/ch2", links: links, openTasks: open, home: home) == nil)
    }

    @Test func aLinkMadeInTheHomeFolderCapturesNothing() {
        for root in ["/Users/o", "/Users/o/", "/Users", "/"] {
            let links = [AgentTaskMatch.FolderLink(folder: root, taskID: 1, kind: .task)]
            #expect(AgentTaskMatch.task(explicit: nil, folder: root, links: links, openTasks: open, home: home) == nil)
            #expect(AgentTaskMatch.task(explicit: nil, folder: "/Users/o/x", links: links, openTasks: open, home: home) == nil)
        }
    }

    @Test func doneTasksAndTheRootFolderMatchNothing() {
        let links = [AgentTaskMatch.FolderLink(folder: "/", taskID: 1, kind: .task),
                     AgentTaskMatch.FolderLink(folder: "/p", taskID: 8, kind: .task)]
        #expect(AgentTaskMatch.task(explicit: nil, folder: "/p/q", links: links, openTasks: open, home: home) == nil)
    }

    // MARK: Go to agent

    @Test func terminalAndITermGoToTheTabByDevice() {
        #expect(AgentWorkspace.action(for: TerminalPlace(app: "Apple_Terminal", tty: "/dev/ttys004"))
            == .tab(AgentWorkspace.terminal, tty: "/dev/ttys004"))
        #expect(AgentWorkspace.action(for: TerminalPlace(app: "iTerm.app", tty: "/dev/ttys009"))
            == .tab(AgentWorkspace.iTerm, tty: "/dev/ttys009"))
        // Without a device, the app comes forward.
        #expect(AgentWorkspace.action(for: TerminalPlace(app: "iTerm.app")) == .activate(AgentWorkspace.iTerm))
    }

    @Test func warpOnlyComesForwardEvenWithADevice() {
        #expect(AgentWorkspace.action(for: TerminalPlace(app: "WarpTerminal", tty: "/dev/ttys004"))
            == .activate(AgentWorkspace.warp))
    }

    @Test func anUnknownTerminalSaysSo() {
        guard case .none(let message) = AgentWorkspace.action(for: TerminalPlace(app: "vscode")) else {
            Issue.record("expected no action")
            return
        }
        #expect(message.contains("vscode"))
        guard case .none = AgentWorkspace.action(for: TerminalPlace()) else {
            Issue.record("expected no action")
            return
        }
    }

    @Test func theScriptHoldsOnlyAValidDevice() throws {
        let script = try #require(AgentWorkspace.script(selecting: "/dev/ttys004", in: AgentWorkspace.terminal))
        #expect(script.contains(#"if tty of t is "/dev/ttys004" then"#))
        #expect(script.contains("set selected of t to true"))
        let iTerm = try #require(AgentWorkspace.script(selecting: "/dev/ttys004", in: AgentWorkspace.iTerm))
        #expect(iTerm.contains(#"tell application id "com.googlecode.iterm2""#))
        #expect(iTerm.contains("select s"))
        #expect(AgentWorkspace.script(selecting: #"/dev/ttys1" then do shell script "x"#, in: AgentWorkspace.terminal) == nil)
        #expect(AgentWorkspace.script(selecting: "/dev/ttys004", in: AgentWorkspace.warp) == nil)
    }

    @Test func warpsNewTabURLEncodesTheFolder() throws {
        let url = try #require(AgentWorkspace.warpNewTab(in: "/Users/o/My Project&x"))
        #expect(url.absoluteString == "warp://action/new_tab?path=/Users/o/My%20Project%26x")
    }

    // MARK: Hooks snippet

    @Test func theSnippetIsValidJSONWithEveryEventAsync() throws {
        let snippet = ClaudeHookSnippet.settings()
        let object = try #require(try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any])
        let hooks = try #require(object["hooks"] as? [String: [[String: Any]]])
        #expect(Set(hooks.keys) == ["SessionStart", "UserPromptSubmit", "Notification", "Stop"])
        for (event, groups) in hooks {
            let handler = try #require((groups.first?["hooks"] as? [[String: Any]])?.first)
            #expect(handler["type"] as? String == "command")
            #expect(handler["async"] as? Bool == true)
            #expect(handler["command"] as? String == "focuspilot agent report --from-claude-hook \(event)")
        }
    }

    @Test func aPathWithSpacesIsQuotedForTheShell() throws {
        let snippet = ClaudeHookSnippet.settings(command: "/Users/o/Apps/Focus Pilot.app/Contents/Helpers/focuspilot")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any])
        let stop = try #require(((object["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])?.first)
        let command = try #require((stop["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        #expect(command == "'/Users/o/Apps/Focus Pilot.app/Contents/Helpers/focuspilot' agent report --from-claude-hook Stop")
        #expect(ClaudeHookSnippet.shellQuoted("it's") == #"'it'\''s'"#)
    }

    // MARK: Review hold

    private func item(at date: Date, reported: Bool = true) -> ReviewItem {
        ReviewItem(id: 1, taskID: 1, taskTitle: "T", linkID: nil, kind: .finished, occurredAt: date, agentLabel: "bot",
                   workspaceLabel: nil, summary: nil, output: nil, reportedAgentID: reported ? 1 : nil,
                   source: reported ? .claudeCodeHook : nil, agentState: reported ? .ready : nil)
    }

    private func session(_ phase: SessionPhase) -> FocusSession {
        FocusSession(id: UUID(), taskID: 1, action: "Write", mode: .strict, startedAt: wednesdayMorningInBogota,
                     plannedEnd: wednesdayMorningInBogota.addingTimeInterval(3600), phase: phase)
    }

    @Test func aReportedResultWaitsForTheBreakDuringAPlanBlock() {
        let during = item(at: wednesdayMorningInBogota.addingTimeInterval(600))
        #expect(ReviewHold.isHeld(during, session: session(.running), planSession: true))
        #expect(ReviewHold.isHeld(during, session: session(.paused(since: .now)), planSession: true))
        #expect(!ReviewHold.isHeld(during, session: session(.onBreak(until: .now)), planSession: true))
        #expect(!ReviewHold.isHeld(during, session: session(.running), planSession: false))
        #expect(!ReviewHold.isHeld(during, session: nil, planSession: false))
        // From before the block began, it is already news; Herdr's are not held.
        #expect(!ReviewHold.isHeld(item(at: wednesdayMorningInBogota.addingTimeInterval(-60)), session: session(.running),
                                   planSession: true))
        #expect(!ReviewHold.isHeld(item(at: wednesdayMorningInBogota.addingTimeInterval(600), reported: false),
                                   session: session(.running), planSession: true))
    }

    @Test func aBreakReleasesWhatCameBeforeItForGood() {
        let beforeBreak = item(at: wednesdayMorningInBogota.addingTimeInterval(600))
        let duringBreak = item(at: wednesdayMorningInBogota.addingTimeInterval(1500))
        let breakEnd = wednesdayMorningInBogota.addingTimeInterval(1800)
        let afterBreak = item(at: wednesdayMorningInBogota.addingTimeInterval(2000))
        // On the break, both show.
        #expect(!ReviewHold.isHeld(beforeBreak, session: session(.onBreak(until: breakEnd)), planSession: true))
        #expect(!ReviewHold.isHeld(duringBreak, session: session(.onBreak(until: breakEnd)), planSession: true))
        // Running again, they still show; only what came after waits.
        for shown in [beforeBreak, duringBreak] {
            #expect(!ReviewHold.isHeld(shown, session: session(.running), planSession: true, releasedAt: breakEnd))
        }
        #expect(ReviewHold.isHeld(afterBreak, session: session(.running), planSession: true, releasedAt: breakEnd))
    }

    // MARK: Unread

    @Test func aResultIsUnreadThenReadAndOthersAddUnread() {
        var result = item(at: wednesdayMorningInBogota)
        #expect(result.stateTitle == "Unread")
        result.openedAt = wednesdayMorningInBogota
        #expect(result.stateTitle == "Read")

        var approval = item(at: wednesdayMorningInBogota, reported: false)
        approval.kind = .approval
        #expect(approval.stateTitle == "Needs your approval · Unread")
        approval.openedAt = wednesdayMorningInBogota
        #expect(approval.stateTitle == "Needs your approval")

        var failed = item(at: wednesdayMorningInBogota)
        failed.agentState = .failed
        #expect(failed.stateTitle == "Failed · Unread")
        failed.openedAt = wednesdayMorningInBogota
        #expect(failed.stateTitle == "Failed")
    }

    @Test func onlyEachAgentsNewestResultIsUnread() {
        let newest = item(at: wednesdayMorningInBogota)
        let older = item(at: wednesdayMorningInBogota.addingTimeInterval(-60))
        var other = item(at: wednesdayMorningInBogota.addingTimeInterval(-120))
        other.reportedAgentID = 2
        var herdr = item(at: wednesdayMorningInBogota.addingTimeInterval(-150), reported: false)
        herdr.linkID = 7
        var olderHerdr = item(at: wednesdayMorningInBogota.addingTimeInterval(-160), reported: false)
        olderHerdr.linkID = 7
        var approval = item(at: wednesdayMorningInBogota.addingTimeInterval(-180))
        approval.kind = .approval

        let queue = ReviewItem.markingSuperseded([newest, older, other, herdr, olderHerdr, approval])

        #expect(queue.map(\.isUnread) == [true, false, true, true, false, true])
        #expect(queue[1].stateTitle == "Read")
    }

    @Test func theNoteCountsShownUnreadResultsOnly() {
        var newest = item(at: wednesdayMorningInBogota.addingTimeInterval(-60), reported: false)
        newest.agentLabel = "Claude Code · Bowling"
        let older = item(at: wednesdayMorningInBogota.addingTimeInterval(-120), reported: false)
        var opened = item(at: wednesdayMorningInBogota.addingTimeInterval(-180), reported: false)
        opened.openedAt = wednesdayMorningInBogota
        var approval = item(at: wednesdayMorningInBogota.addingTimeInterval(-30), reported: false)
        approval.kind = .approval
        let held = item(at: wednesdayMorningInBogota.addingTimeInterval(600))
        // Newest first, as the queue is.
        let queue = [held, approval, newest, older, opened]

        // In a plan block the reported result waits for the break and isn't counted.
        #expect(RaccoonPresence.unreadNote(for: queue, session: session(.running), planSession: true)
            == "2 unread · Claude Code · Bowling")
        // On the break it shows, and counts, as the newest.
        #expect(RaccoonPresence.unreadNote(for: queue, session: session(.onBreak(until: .now)), planSession: true)
            == "3 unread · bot")
        #expect(RaccoonPresence.unreadNote(for: [approval, opened], session: session(.running), planSession: true) == nil)
        #expect(RaccoonPresence.unreadNote(for: [held], session: session(.running), planSession: true) == nil)
        // A newer result held for the break doesn't make the shown one read.
        let shownBefore = item(at: wednesdayMorningInBogota.addingTimeInterval(-60))
        #expect(RaccoonPresence.unreadNote(for: [held, shownBefore], session: session(.running), planSession: true)
            == "1 unread · bot")
    }
}
