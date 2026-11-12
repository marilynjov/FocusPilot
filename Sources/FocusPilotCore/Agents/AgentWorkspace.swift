import Foundation

/// How Go to agent brings a reported agent's terminal forward (decision
/// 0005), decided from what its report said. The app carries it out, and
/// only for the owner's click. Sources are in docs/VALIDATION_PLAN.md.
public enum AgentWorkspace {
    /// A terminal app FocusPilot knows by its `TERM_PROGRAM`.
    public struct App: Equatable, Sendable {
        public var bundleID: String
        public var name: String
    }

    public static let terminal = App(bundleID: "com.apple.Terminal", name: "Terminal")
    public static let iTerm = App(bundleID: "com.googlecode.iterm2", name: "iTerm2")
    public static let warp = App(bundleID: "dev.warp.Warp-Stable", name: "Warp")

    /// `TERM_PROGRAM` values: Terminal's from its binary, iTerm2's from its
    /// source, Warp's as seen in a Warp shell. VS Code's "vscode" is shared
    /// by its forks, so it names no app.
    static let apps: [String: App] = ["Apple_Terminal": terminal, "iTerm.app": iTerm, "WarpTerminal": warp]

    public enum Action: Equatable, Sendable {
        /// The exact tab, found by its terminal device through AppleScript.
        case tab(App, tty: String)
        /// The Warp window FocusPilot started for the agent's task, found
        /// by its title through Accessibility (`WarpLaunch`).
        case window(App, title: String)
        /// The app in front; which tab is the owner's to find. Warp
        /// documents no way to reach an existing tab.
        case activate(App)
        /// Nothing FocusPilot can bring forward; the message says why.
        case none(String)
    }

    /// `warpWindow` is the title in the launch configuration of the window
    /// the agent reported it runs in, if there is one (`WarpLaunch.windowTitle`):
    /// only then has a Warp agent a window of its own, so an agent
    /// FocusPilot never opened doesn't ask for Accessibility.
    public static func action(for terminal: TerminalPlace, warpWindow: String? = nil) -> Action {
        guard let name = terminal.app, let app = apps[name] else {
            return .none(terminal.app.map { "FocusPilot doesn’t know how to bring \($0) forward. Switch to it yourself." }
                ?? "This agent didn’t say which terminal it runs in, so FocusPilot can’t bring it forward.")
        }
        if app == warp, let warpWindow { return .window(app, title: warpWindow) }
        if app != warp, let tty = terminal.tty.flatMap(AgentText.tty) { return .tab(app, tty: tty) }
        return .activate(app)
    }

    // MARK: Warp windows

    /// "FocusPilot · Write chapter 2 · 3fa9c01b": the title of a Warp window
    /// FocusPilot opens for a chat. The token tells apart windows of chats
    /// on the same task; Go to agent reads the title back from the window's
    /// launch configuration, so renaming the task doesn't lose the window.
    /// The task's title is cleaned to one line of visible text and capped;
    /// one with nothing left is left out.
    public static func warpWindowTitle(taskTitle: String, token: String) -> String {
        (["FocusPilot", AgentText.line(taskTitle, limit: warpTitleLimit), token].compactMap(\.self)).joined(separator: " · ")
    }

    static let warpTitleLimit = 80

    /// The first window whose title is exactly `title`. Warp shows the
    /// active tab's title on its window, so a window where the owner opened
    /// and chose another tab no longer matches.
    public static func window(titled title: String, in titles: [String?]) -> Int? {
        titles.firstIndex { $0 == title }
    }

    /// What happened when Go to agent looked for the agent's Warp window.
    public enum WindowSearch: Equatable, Sendable {
        case raised
        /// FocusPilot isn't allowed to use Accessibility; Warp came forward.
        case notAllowed
        /// No window has the title; Warp came forward.
        case notFound
        case notRunning
    }

    /// What the owner is told after a Warp window search; nil when the
    /// window came forward.
    public static func notice(after search: WindowSearch) -> String? {
        switch search {
        case .raised: nil
        case .notAllowed:
            "Warp is in front. To let FocusPilot bring the agent’s own window forward, turn on FocusPilot in System Settings › Privacy & Security › Accessibility."
        case .notFound:
            "Warp is in front, but the agent’s own window wasn’t found. It may have closed, or show another tab."
        case .notRunning: "Warp isn’t running, so the agent has stopped."
        }
    }

    /// Warp came forward, but not the agent's own window, which it has
    /// none of. `canOpenOwnWindow`: the panel offers Open in Its Own Window
    /// for this agent (`canResume`).
    public static func warpNotice(folder: String?, canOpenOwnWindow: Bool) -> String {
        let place = folder.map { " in \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? ""
        let hint = canOpenOwnWindow ? " So Go to agent can bring this chat forward, use Open in Its Own Window once its turn has ended." : ""
        return "Warp is in front, but FocusPilot can’t pick a tab, so look for the one\(place).\(hint)"
    }

    /// Whether a Claude Code chat in Warp that FocusPilot didn't open can be
    /// resumed in a window of its own: its key is Claude Code's session ID,
    /// a UUID, it has a folder, it has no window FocusPilot opened, and no
    /// window waits to resume it already (so a second click doesn't open a
    /// second). Terminal and iTerm2 already reach the exact tab. Its state
    /// is checked by the panel, since it changes with time.
    public static func canResume(_ agent: ReportedAgent, windowsOnDisk: Set<WarpLaunch.OnDisk>) -> Bool {
        agent.source == .claudeCodeHook && apps[agent.terminal.app ?? ""] == warp
            && WarpLaunch.isSessionID(agent.key) && agent.folder != nil
            && !windowsOnDisk.contains { $0.token == agent.warpWindow || $0.resumedSession == agent.key }
    }

    /// Resuming starts a second Claude Code on the session, so only once
    /// its turn has ended: Ready or Failed. Needs you may be a permission
    /// prompt mid-turn, and Unknown may still be running.
    public static func canResumeNow(_ state: ReportedAgentState) -> Bool {
        state == .ready || state == .failed
    }

    /// The folder a new Claude Code window for a task starts in: where an
    /// agent linked to it last reported from (`folders`, newest first), else
    /// its project's Herdr workspace folder. Nil means the owner chooses.
    public static func startFolder(agentFolders folders: [String?], projectFolder: String?,
                                   isUsable: (String) -> Bool) -> String? {
        (folders + [projectFolder]).lazy.compactMap(\.self).first(where: isUsable)
    }

    /// The AppleScript that selects the tab whose terminal device is `tty`
    /// and brings its window forward; it returns true if it found one.
    /// iTerm2: windows, tabs and sessions, a session's `tty`, and `select`
    /// (iterm2.com/documentation-scripting.html). Terminal: a tab's `tty`
    /// and `selected`, a window's `frontmost` (Terminal.sdef).
    public static func script(selecting tty: String, in app: App) -> String? {
        // Checked again here: the device is the only value put in the script.
        guard AgentText.tty(tty) == tty else { return nil }
        switch app {
        case iTerm:
            return """
                tell application id "\(app.bundleID)"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is "\(tty)" then
                                    select s
                                    select t
                                    select w
                                    activate
                                    return true
                                end if
                            end repeat
                        end repeat
                    end repeat
                    return false
                end tell
                """
        case terminal:
            return """
                tell application id "\(app.bundleID)"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is "\(tty)" then
                                set selected of t to true
                                set frontmost of w to true
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                    return false
                end tell
                """
        default:
            return nil
        }
    }

    /// Warp's documented URL for a new tab in `folder`
    /// (docs.warp.dev/features/uri-scheme). It opens a new tab; it cannot
    /// reach the agent's own tab.
    public static func warpNewTab(in folder: String) -> URL? {
        var components = URLComponents()
        components.scheme = "warp"
        components.host = "action"
        components.path = "/new_tab"
        // "+", "&" and "=" are allowed in a query but would change its meaning here.
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=?#"))
        guard let value = folder.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        components.percentEncodedQuery = "path=" + value
        return components.url
    }
}
