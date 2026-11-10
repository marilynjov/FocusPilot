import Foundation
import Testing
@testable import FocusPilotCore

/// Claude Code in a Warp window of its own (decision 0005, 2026-11-10): the
/// launch configuration Warp runs, which nothing the owner or an agent typed
/// may change, and finding that window again for Go to agent.
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

    @Test func theConfigurationRunsClaudeCodeInTheTasksFolder() throws {
        let launch = try #require(WarpLaunch(taskID: 12, taskTitle: "Write chapter 2", folder: folder.path))
        #expect(launch.name == "focuspilot-task-12")
        #expect(launch.yaml == """
            ---
            name: "focuspilot-task-12"
            windows:
              - tabs:
                  - title: "FocusPilot · Write chapter 2 (12)"
                    layout:
                      cwd: "\(folder.path)"
                      commands:
                        - exec: "env FOCUSPILOT_TASK=12 claude"

            """)
        #expect(launch.url?.absoluteString == "warp://launch/focuspilot-task-12")
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
        let launch = try #require(WarpLaunch(taskID: 7, taskTitle: title, folder: folder.path))
        let lines = launch.yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // The same nine lines whatever the title: one document, one command.
        #expect(lines.count == 10)
        #expect(lines.filter { $0 == "---" }.count == 1)
        #expect(lines[4].hasPrefix("      - title: \""))
        #expect(lines.filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- exec:") }
            == [#"            - exec: "env FOCUSPILOT_TASK=7 claude""#])
        #expect(!launch.yaml.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\n" })
        #expect(!launch.yaml.contains("\u{2028}") && !launch.yaml.contains("\u{2029}"))
        // The title value, read back as YAML would, is the window title.
        #expect(WarpLaunch.unquoted(String(lines[4].dropFirst("      - title: ".count))) == launch.windowTitle)
        #expect(WarpLaunch.windowTitle(inConfiguration: launch.yaml) == launch.windowTitle)
    }

    @Test func theTitleIsOneCappedLine() {
        let title = AgentWorkspace.warpWindowTitle(taskID: 3, taskTitle: "  Fix\n\tthe\u{202E} bug  " + String(repeating: "x", count: 200))
        #expect(title.hasPrefix("FocusPilot · Fix the bug xxx"))
        #expect(title.hasSuffix("x… (3)"))
        #expect(title.count == "FocusPilot · ".count + AgentWorkspace.warpTitleLimit + " (3)".count)
        // Two tasks with the same title get different windows.
        #expect(AgentWorkspace.warpWindowTitle(taskID: 4, taskTitle: "Fix bug")
            != AgentWorkspace.warpWindowTitle(taskID: 5, taskTitle: "Fix bug"))
        #expect(AgentWorkspace.warpWindowTitle(taskID: 3, taskTitle: "\n\u{200B}") == "FocusPilot · Task 3")
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

    @Test func writingMakesTheDirectoryAndReplacesTheTasksFile() throws {
        let directory = folder.appendingPathComponent("warp/launch_configurations")
        let first = try #require(WarpLaunch(taskID: 4, taskTitle: "Old", folder: folder.path))
        let file = try first.write(into: directory)
        #expect(file.lastPathComponent == "focuspilot-task-4.yaml")
        let second = try #require(WarpLaunch(taskID: 4, taskTitle: "New", folder: folder.path))
        try second.write(into: directory)
        #expect(try String(contentsOf: file, encoding: .utf8) == second.yaml)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["focuspilot-task-4.yaml"])
    }

    // MARK: Go to agent

    @Test func onlyAWarpAgentFocusPilotStartedLooksForItsWindow() {
        let warp = TerminalPlace(app: "WarpTerminal", tty: "/dev/ttys004")
        #expect(AgentWorkspace.action(for: warp, warpWindow: "FocusPilot · Write chapter 2 (12)")
            == .window(AgentWorkspace.warp, title: "FocusPilot · Write chapter 2 (12)"))
        // No launch configuration for its task: no window to look for.
        #expect(AgentWorkspace.action(for: warp) == .activate(AgentWorkspace.warp))
        // Other terminals keep going by device.
        #expect(AgentWorkspace.action(for: TerminalPlace(app: "iTerm.app", tty: "/dev/ttys009"), warpWindow: "x")
            == .tab(AgentWorkspace.iTerm, tty: "/dev/ttys009"))
    }

    @Test func goToAgentReadsTheTitleItWroteSoARenameDoesNotLoseTheWindow() throws {
        let directory = folder.appendingPathComponent("launch_configurations")
        #expect(WarpLaunch.windowTitle(ofTask: 12, in: directory) == nil)
        try #require(WarpLaunch(taskID: 12, taskTitle: "Old \"name\" #1", folder: folder.path)).write(into: directory)
        #expect(WarpLaunch.windowTitle(ofTask: 12, in: directory) == "FocusPilot · Old \"name\" #1 (12)")
        #expect(WarpLaunch.windowTitle(ofTask: 13, in: directory) == nil)
        #expect(WarpLaunch.windowTitle(inConfiguration: "- title: unquoted") == nil)
    }

    @Test func onlyConfigurationsOfTasksNoLongerOpenAreRemoved() throws {
        let directory = folder.appendingPathComponent("launch_configurations")
        for id: Int64 in [1, 2, 3] {
            try #require(WarpLaunch(taskID: id, taskTitle: "t", folder: folder.path)).write(into: directory)
        }
        for other in ["mine.yaml", "focuspilot-task-x.yaml", "focuspilot-task-02.yaml", "focuspilot-task-4.yml"] {
            try Data().write(to: directory.appendingPathComponent(other))
        }
        WarpLaunch.removeStale(keeping: [2], in: directory)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
            == ["focuspilot-task-2.yaml", "mine.yaml", "focuspilot-task-x.yaml", "focuspilot-task-02.yaml",
                "focuspilot-task-4.yml"])
        // A missing directory is left alone.
        WarpLaunch.removeStale(keeping: [], in: folder.appendingPathComponent("missing"))
    }

    @Test func onlyAnExactTitleMatches() {
        let titles: [String?] = ["✳ Raccoon on screen", nil, "FocusPilot · Write chapter 2 (draft)", "FocusPilot · Write chapter 2"]
        #expect(AgentWorkspace.window(titled: "FocusPilot · Write chapter 2", in: titles) == 3)
        #expect(AgentWorkspace.window(titled: "FocusPilot · Write", in: titles) == nil)
    }

    @Test func eachSearchOutcomeSaysWhatHappened() throws {
        #expect(AgentWorkspace.notice(after: .raised, folder: nil) == nil)
        let notAllowed = try #require(AgentWorkspace.notice(after: .notAllowed, folder: nil))
        #expect(notAllowed.contains("System Settings › Privacy & Security › Accessibility"))
        let notFound = try #require(AgentWorkspace.notice(after: .notFound, folder: "/tmp/thesis"))
        #expect(notFound.contains("in /tmp/thesis"))
        #expect(notFound.contains("Start Claude Code"))
        #expect(AgentWorkspace.notice(after: .notRunning, folder: nil) == "Warp isn’t running, so the agent has stopped.")
    }

    @Test func theStartFolderIsTheNewestUsableOne() {
        let usable: Set = ["/b", "/p"]
        #expect(AgentWorkspace.startFolder(agentFolders: [nil, "/gone", "/b"], projectFolder: "/p",
                                           isUsable: usable.contains) == "/b")
        #expect(AgentWorkspace.startFolder(agentFolders: ["/gone"], projectFolder: "/p", isUsable: usable.contains) == "/p")
        #expect(AgentWorkspace.startFolder(agentFolders: [], projectFolder: nil, isUsable: usable.contains) == nil)
    }
}
