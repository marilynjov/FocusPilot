import Foundation
import Testing
@testable import FocusPilotCore

/// Claude Code chats in Warp windows of their own (decision 0005,
/// 2026-11-10 and 2026-11-11): the launch configuration Warp runs, which
/// nothing the owner or an agent typed may change, finding that window again
/// for Go to agent, and tidying old configurations.
@Suite("Warp agent windows")
final class WarpLaunchTests {
    private let folder: URL

    init() throws {
        folder = try makeTemporaryDirectory()
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: The launch configuration

    @Test func theConfigurationRunsClaudeCodeInItsOwnWindow() throws {
        let launch = try #require(WarpLaunch(token: "3fa9c01b", taskID: 12, taskTitle: "Write chapter 2", folder: folder.path))
        #expect(launch.name == "focuspilot-window-3fa9c01b")
        #expect(launch.yaml == """
            ---
            name: "focuspilot-window-3fa9c01b"
            windows:
              - tabs:
                  - title: "FocusPilot · Write chapter 2 · 3fa9c01b"
                    layout:
                      cwd: "\(folder.path)"
                      commands:
                        - exec: "env FOCUSPILOT_TASK=12 FOCUSPILOT_WINDOW=3fa9c01b claude"

            """)
        #expect(launch.url?.absoluteString == "warp://launch/focuspilot-window-3fa9c01b")
        #expect(WarpLaunch.taskID(inConfiguration: launch.yaml) == 12)
    }

    @Test func aResumedChatNamesItsSession() throws {
        let session = "0f8e1c2a-4b5d-4e6f-8a9b-0c1d2e3f4a5b"
        let launch = try #require(WarpLaunch(token: "00ff00aa", taskID: 2, taskTitle: "Work", folder: folder.path,
                                             resuming: session))
        #expect(launch.command == "env FOCUSPILOT_TASK=2 FOCUSPILOT_WINDOW=00ff00aa claude --resume \(session)")
        #expect(launch.yaml.contains(#"- exec: "env FOCUSPILOT_TASK=2 FOCUSPILOT_WINDOW=00ff00aa claude --resume \#(session)""#))
        #expect(WarpLaunch(taskID: 2, taskTitle: "Work", folder: folder.path, resuming: "abc; rm -rf ~") == nil)
    }

    @Test func eachWindowGetsANewToken() throws {
        let first = try #require(WarpLaunch(taskID: 2, taskTitle: "Work", folder: folder.path))
        let second = try #require(WarpLaunch(taskID: 2, taskTitle: "Work", folder: folder.path))
        #expect(WarpLaunch.isToken(first.token) && WarpLaunch.isToken(second.token))
        #expect(first.token != second.token)
        #expect(first.windowTitle != second.windowTitle)
    }

    @Test func onlyATokensExactFormIsAccepted() {
        #expect(WarpLaunch.isToken("3fa9c01b"))
        for bad in ["3FA9C01B", "3fa9c01", "3fa9c01b0", "3fa9c01g", "", "3fa9c0 b", "../../x", "３fa9c01b"] {
            #expect(!WarpLaunch.isToken(bad), "\(bad)")
        }
        #expect(WarpLaunch(token: "../etc", taskID: 1, taskTitle: "t", folder: folder.path) == nil)
    }

    @Test func onlyACanonicalUUIDIsASessionID() {
        #expect(WarpLaunch.isSessionID("0f8e1c2a-4b5d-4e6f-8a9b-0c1d2e3f4a5b"))
        #expect(WarpLaunch.isSessionID("0F8E1C2A-4B5D-4E6F-8A9B-0C1D2E3F4A5B"))
        for bad in ["0f8e1c2a4b5d4e6f8a9b0c1d2e3f4a5b", "0f8e1c2a-4b5d-4e6f-8a9b-0c1d2e3f4a5", "0f8e1c2a-4b5d-4e6f-8a9b-0c1d2e3f4a5g",
                    "{0f8e1c2a-4b5d-4e6f-8a9b-0c1d2e3f4a5b}", "0f8e1c2a-4b5d-4e6f-8a9b-0c1d2e3f4a5b --dangerously-skip-permissions",
                    "-0f8e1c2-4b5d-4e6f-8a9b-0c1d2e3f4a5b", "", "w0t0p0:XYZ"] {
            #expect(!WarpLaunch.isSessionID(bad), "\(bad)")
        }
    }

    @Test(arguments: [
        "Fix\"\n    commands:\n      - exec: rm -rf ~",
        "a: b # c",
        "!!python/object:os.system ['rm -rf ~']",
        "{ exec: x }",
        "`whoami` $(rm -rf ~) ${HOME}",
        "back\\slash \\\" end",
        "line\rbreak\u{2028}sep\u{2029}x\u{85}y\u{0}z\u{1B}[31m",
        "---\n...\n---",
        "'single' & | ; < >",
    ])
    func aHostileTitleStaysInsideItsQuotes(title: String) throws {
        let launch = try #require(WarpLaunch(token: "0000000a", taskID: 7, taskTitle: title, folder: folder.path))
        let lines = launch.yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // The same nine lines whatever the title: one document, one command.
        #expect(lines.count == 10)
        #expect(lines.filter { $0 == "---" }.count == 1)
        #expect(lines[4].hasPrefix("      - title: \""))
        #expect(lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- exec:") }
            == [#"            - exec: "env FOCUSPILOT_TASK=7 FOCUSPILOT_WINDOW=0000000a claude""#])
        #expect(!launch.yaml.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\n" })
        #expect(!launch.yaml.contains("\u{2028}") && !launch.yaml.contains("\u{2029}"))
        // The title value, read back as YAML would, is the window title.
        #expect(WarpLaunch.unquoted(String(lines[4].dropFirst("      - title: ".count))) == launch.windowTitle)
        #expect(WarpLaunch.windowTitle(inConfiguration: launch.yaml) == launch.windowTitle)
    }

    @Test func theTitleIsOneCappedLine() {
        let title = AgentWorkspace.warpWindowTitle(taskTitle: "  Fix\n\tthe\u{202E} bug  " + String(repeating: "x", count: 200),
                                                   token: "3fa9c01b")
        #expect(title.hasPrefix("FocusPilot · Fix the bug xxx"))
        #expect(title.hasSuffix("x… · 3fa9c01b"))
        #expect(title.count == "FocusPilot · ".count + AgentWorkspace.warpTitleLimit + " · 3fa9c01b".count)
        #expect(AgentWorkspace.warpWindowTitle(taskTitle: "\n\u{200B}", token: "3fa9c01b") == "FocusPilot · 3fa9c01b")
    }

    @Test func quotingEscapesEverythingThatCouldEndTheValue() {
        #expect(WarpLaunch.quoted(#"a"b\c"#) == #""a\"b\\c""#)
        #expect(WarpLaunch.quoted("a\nb\tc\u{7}d\u{7F}") == #""a\nb\tc\x07d\x7F""#)
        #expect(WarpLaunch.quoted("\u{2028}\u{FEFF}é·") == "\"" + "\\u2028" + "\\uFEFF" + "é·\"")
    }

    @Test func onlyAnExistingPlainFolderIsUsed() throws {
        #expect(WarpLaunch.usableFolder(folder.path + "/") == folder.path)
        #expect(WarpLaunch.usableFolder("relative/path") == nil)
        #expect(WarpLaunch.usableFolder(folder.appendingPathComponent("missing").path) == nil)
        let file = folder.appendingPathComponent("file.txt")
        try Data().write(to: file)
        #expect(WarpLaunch.usableFolder(file.path) == nil)
        for name in ["$(touch x)", "a`b`", "a;b", "a\"b", "a'b", "a|b", "a&b", "a\\b", "a!b", "~x", "a*", "a?", "a[b]",
                     "a{b,c}", "a(b)", "a#b"] {
            let hostile = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: hostile, withIntermediateDirectories: true)
            #expect(WarpLaunch.usableFolder(hostile.path) == nil, "\(name)")
            #expect(WarpLaunch(taskID: 1, taskTitle: "t", folder: hostile.path) == nil)
        }
        let spaced = folder.appendingPathComponent("My Project 2")
        try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
        #expect(WarpLaunch.usableFolder(spaced.path) == spaced.path)
        #expect(WarpLaunch(taskID: 0, taskTitle: "t", folder: spaced.path) == nil)
    }

    @Test func writingMakesTheDirectory() throws {
        let directory = folder.appendingPathComponent("warp/launch_configurations")
        var launch = try #require(WarpLaunch(token: "0000000b", taskID: 4, taskTitle: "Old", folder: folder.path))
        let file = try launch.write(into: directory)
        #expect(file.lastPathComponent == "focuspilot-window-0000000b.yaml")
        #expect(try String(contentsOf: file, encoding: .utf8) == launch.yaml)
    }

    // MARK: Go to agent

    @Test func onlyAWarpAgentWithAWindowLooksForIt() {
        let warp = TerminalPlace(app: "WarpTerminal", tty: "/dev/ttys004")
        #expect(AgentWorkspace.action(for: warp, warpWindow: "FocusPilot · Work · 3fa9c01b")
            == .window(AgentWorkspace.warp, title: "FocusPilot · Work · 3fa9c01b"))
        // No window FocusPilot opened: Warp comes forward, with no Accessibility prompt.
        #expect(AgentWorkspace.action(for: warp) == .activate(AgentWorkspace.warp))
        // Other terminals keep going by device.
        #expect(AgentWorkspace.action(for: TerminalPlace(app: "iTerm.app", tty: "/dev/ttys009"), warpWindow: "x")
            == .tab(AgentWorkspace.iTerm, tty: "/dev/ttys009"))
    }

    @Test func goToAgentReadsTheTitleItWroteSoARenameDoesNotLoseTheWindow() throws {
        let directory = folder.appendingPathComponent("launch_configurations")
        #expect(WarpLaunch.windowTitle(ofWindow: "3fa9c01b", in: directory) == nil)
        var launch = try #require(WarpLaunch(token: "3fa9c01b", taskID: 12, taskTitle: "Old \"name\" #1", folder: folder.path))
        try launch.write(into: directory)
        #expect(WarpLaunch.windowTitle(ofWindow: "3fa9c01b", in: directory) == "FocusPilot · Old \"name\" #1 · 3fa9c01b")
        #expect(WarpLaunch.windowTitle(ofWindow: "3fa9c01c", in: directory) == nil)
        #expect(WarpLaunch.windowTitle(ofWindow: "../../x", in: directory) == nil)
        #expect(WarpLaunch.windowTitle(inConfiguration: "- title: unquoted") == nil)
    }

    @Test func twoChatsOnOneTaskHaveTheirOwnWindows() {
        let titles: [String?] = ["FocusPilot · Work · 0000000a", "FocusPilot · Work · 0000000b"]
        #expect(AgentWorkspace.window(titled: "FocusPilot · Work · 0000000b", in: titles) == 1)
    }

    // MARK: Tidying up

    @Test func staleConfigurationsAreChosenByTaskAndAge() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = now.addingTimeInterval(-WarpLaunch.unreportedLifetime - 60)
        let files: [WarpLaunch.Listed] = [
            .init(name: "focuspilot-task-12.yaml", modified: now),             // the per-task kind: goes
            .init(name: "focuspilot-window-0000000a.yaml", modified: old, taskID: 2),  // reported, task open: stays
            .init(name: "focuspilot-window-0000000b.yaml", modified: now, taskID: 9),  // task done or gone: goes
            .init(name: "focuspilot-window-0000000c.yaml", modified: now, taskID: 2),  // new, not reported yet: stays
            .init(name: "focuspilot-window-0000000d.yaml", modified: old, taskID: 2),  // unreported for a day: goes
            .init(name: "focuspilot-window-0000000e.yaml", modified: old, taskID: 9),  // reported, task done: goes
            .init(name: "focuspilot-window-ZZ.yaml", modified: old),
            .init(name: "focuspilot-task-x.yaml", modified: old),
            .init(name: "focuspilot-task-02.yaml", modified: old),
            .init(name: "mine.yaml", modified: old),
        ]
        let stale = WarpLaunch.stale(files, referenced: ["0000000a", "0000000e"], openTasks: [2], now: now)
        #expect(Set(stale) == ["focuspilot-task-12.yaml", "focuspilot-window-0000000b.yaml",
                               "focuspilot-window-0000000d.yaml", "focuspilot-window-0000000e.yaml"])
    }

    @Test func tidyingOnlyTouchesFocusPilotsFiles() throws {
        let directory = folder.appendingPathComponent("launch_configurations")
        var kept = try #require(WarpLaunch(token: "0000000a", taskID: 2, taskTitle: "Work", folder: folder.path))
        var done = try #require(WarpLaunch(token: "0000000b", taskID: 9, taskTitle: "Old", folder: folder.path))
        try kept.write(into: directory)
        try done.write(into: directory)
        for other in ["mine.yaml", "focuspilot-task-3.yaml", "focuspilot-window-0000000c.yml"] {
            try Data().write(to: directory.appendingPathComponent(other))
        }
        let remaining = WarpLaunch.removeStale(referenced: [], openTasks: [2], in: directory)
        #expect(remaining == [.init(token: "0000000a")])
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            == ["focuspilot-window-0000000a.yaml", "mine.yaml", "focuspilot-window-0000000c.yml"])
        // A missing directory is left alone.
        #expect(WarpLaunch.removeStale(referenced: [], openTasks: [], in: folder.appendingPathComponent("missing")).isEmpty)
    }

    // MARK: Resuming a chat elsewhere

    @Test func onlyAClaudeCodeChatInWarpWithASessionUUIDAndNoWindowCanBeResumed() {
        let session = "0f8e1c2a-4b5d-4e6f-8a9b-0c1d2e3f4a5b"
        func agent(_ source: AgentSource = .claudeCodeHook, key: String = session, folder: String? = "/p",
                   app: String = "WarpTerminal", window: String? = nil) -> ReportedAgent {
            ReportedAgent(id: 1, source: source, key: key, label: "Claude Code · p", folder: folder, taskID: 2,
                          isLinkedByOwner: false, reportedState: .ready, lastMessage: nil, lastReportAt: .now,
                          stateChangedAt: .now, terminal: TerminalPlace(app: app), warpWindow: window)
        }
        #expect(AgentWorkspace.canResume(agent(), windowsOnDisk: []))
        #expect(!AgentWorkspace.canResume(agent(.command), windowsOnDisk: []))
        #expect(!AgentWorkspace.canResume(agent(key: "abc"), windowsOnDisk: []))
        #expect(!AgentWorkspace.canResume(agent(folder: nil), windowsOnDisk: []))
        // Terminal and iTerm2 already reach the exact tab.
        #expect(!AgentWorkspace.canResume(agent(app: "iTerm.app"), windowsOnDisk: []))
        #expect(!AgentWorkspace.canResume(agent(window: "0000000a"), windowsOnDisk: [.init(token: "0000000a")]))
        // Its window's configuration is gone: it can be given a new one.
        #expect(AgentWorkspace.canResume(agent(window: "0000000a"), windowsOnDisk: []))
        // A window already waits to resume it: no second one.
        #expect(!AgentWorkspace.canResume(agent(), windowsOnDisk: [.init(token: "0000000b", resumedSession: session)]))
        #expect(AgentWorkspace.canResumeNow(.ready) && AgentWorkspace.canResumeNow(.failed))
        #expect(!AgentWorkspace.canResumeNow(.working) && !AgentWorkspace.canResumeNow(.needsYou)
            && !AgentWorkspace.canResumeNow(.unknown))
    }

    @Test func aTakenTokenIsNeverOverwritten() throws {
        let directory = folder.appendingPathComponent("launch_configurations")
        var first = try #require(WarpLaunch(token: "0000000a", taskID: 2, taskTitle: "Work", folder: folder.path))
        try first.write(into: directory)
        var second = try #require(WarpLaunch(token: "0000000a", taskID: 3, taskTitle: "Other", folder: folder.path))
        let file = try second.write(into: directory)
        #expect(second.token != "0000000a")
        #expect(second.windowTitle == "FocusPilot · Other · \(second.token)")
        #expect(file.lastPathComponent == "focuspilot-window-\(second.token).yaml")
        #expect(WarpLaunch.windowTitle(ofWindow: "0000000a", in: directory) == "FocusPilot · Work · 0000000a")
    }

    @Test func onlyARegularFileIsRead() throws {
        let directory = folder.appendingPathComponent("launch_configurations")
        var real = try #require(WarpLaunch(token: "0000000a", taskID: 2, taskTitle: "Work", folder: folder.path))
        let file = try real.write(into: directory)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("focuspilot-window-0000000b.yaml"),
                                                   withDestinationURL: file)
        #expect(WarpLaunch.windowTitle(ofWindow: "0000000b", in: directory) == nil)
        try Data(count: 64 * 1024 + 1).write(to: directory.appendingPathComponent("focuspilot-window-0000000c.yaml"))
        #expect(WarpLaunch.windowTitle(ofWindow: "0000000c", in: directory) == nil)
    }

    @Test func tidyingReportsWhichSessionAWindowResumes() throws {
        let directory = folder.appendingPathComponent("launch_configurations")
        let session = "0f8e1c2a-4b5d-4e6f-8a9b-0c1d2e3f4a5b"
        var resumed = try #require(WarpLaunch(token: "0000000a", taskID: 2, taskTitle: "Work", folder: folder.path,
                                              resuming: session))
        try resumed.write(into: directory)
        #expect(WarpLaunch.removeStale(referenced: [], openTasks: [2], in: directory)
            == [.init(token: "0000000a", resumedSession: session)])
    }

    @Test func onlyAnExactTitleMatches() {
        let titles: [String?] = ["✳ Raccoon on screen", nil, "FocusPilot · Write chapter 2 (draft)", "FocusPilot · Write chapter 2"]
        #expect(AgentWorkspace.window(titled: "FocusPilot · Write chapter 2", in: titles) == 3)
        #expect(AgentWorkspace.window(titled: "FocusPilot · Write", in: titles) == nil)
    }

    @Test func eachSearchOutcomeSaysWhatHappened() throws {
        #expect(AgentWorkspace.notice(after: .raised) == nil)
        let notAllowed = try #require(AgentWorkspace.notice(after: .notAllowed))
        #expect(notAllowed.contains("System Settings › Privacy & Security › Accessibility"))
        #expect(AgentWorkspace.notice(after: .notFound)?.contains("wasn’t found") == true)
        #expect(AgentWorkspace.notice(after: .notRunning) == "Warp isn’t running, so the agent has stopped.")
        let fallback = AgentWorkspace.warpNotice(folder: "/tmp/thesis", canOpenOwnWindow: true)
        #expect(fallback.contains("in /tmp/thesis") && fallback.contains("Open in Its Own Window"))
        #expect(!AgentWorkspace.warpNotice(folder: nil, canOpenOwnWindow: false).contains("Open in Its Own Window"))
    }

    @Test func theStartFolderIsTheNewestUsableOne() {
        let usable: Set = ["/b", "/p"]
        #expect(AgentWorkspace.startFolder(agentFolders: [nil, "/gone", "/b"], projectFolder: "/p",
                                           isUsable: usable.contains) == "/b")
        #expect(AgentWorkspace.startFolder(agentFolders: ["/gone"], projectFolder: "/p", isUsable: usable.contains) == "/p")
        #expect(AgentWorkspace.startFolder(agentFolders: [], projectFolder: nil, isUsable: usable.contains) == nil)
    }
}
