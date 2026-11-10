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

    /// `warpWindow` is the title in the launch configuration FocusPilot
    /// wrote for the agent's task, if there is one (`WarpLaunch.windowTitle`):
    /// only then may a Warp agent run in a window of its own, so an agent
    /// FocusPilot never started doesn't ask for Accessibility.
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

    /// "FocusPilot · Write chapter 2 (12)": the title FocusPilot gives the
    /// Warp window it starts for a task. The task's number keeps two tasks
    /// with the same title apart; Go to agent reads the title back from the
    /// launch configuration, so renaming the task doesn't lose the window.
    /// The task's title is cleaned to one line of visible text and capped;
    /// one with nothing left is named by its number alone.
    public static func warpWindowTitle(taskID: Int64, taskTitle: String) -> String {
        "FocusPilot · " + (AgentText.line(taskTitle, limit: warpTitleLimit).map { "\($0) (\(taskID))" } ?? "Task \(taskID)")
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
    public static func notice(after search: WindowSearch, folder: String?) -> String? {
        switch search {
        case .raised: nil
        case .notAllowed:
            "Warp is in front. To let FocusPilot bring the agent’s own window forward, turn on FocusPilot in System Settings › Privacy & Security › Accessibility."
        case .notFound: warpNotice(folder: folder)
        case .notRunning: "Warp isn’t running, so the agent has stopped."
        }
    }

    /// Warp came forward, but not the agent's own window.
    public static func warpNotice(folder: String?) -> String {
        let place = folder.map { " in \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? ""
        return "Warp is in front, but FocusPilot can’t pick a tab, so look for the one\(place). Agents started with Start Claude Code get their own window that Go to agent brings forward."
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
