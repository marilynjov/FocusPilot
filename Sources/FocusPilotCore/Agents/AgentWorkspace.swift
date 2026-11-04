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
        /// The app in front; which tab is the owner's to find. Warp
        /// documents no way to reach an existing tab.
        case activate(App)
        /// Nothing FocusPilot can bring forward; the message says why.
        case none(String)
    }

    public static func action(for terminal: TerminalPlace) -> Action {
        guard let name = terminal.app, let app = apps[name] else {
            return .none(terminal.app.map { "FocusPilot doesn’t know how to bring \($0) forward. Switch to it yourself." }
                ?? "This agent didn’t say which terminal it runs in, so FocusPilot can’t bring it forward.")
        }
        if app != warp, let tty = terminal.tty.flatMap(AgentText.tty) { return .tab(app, tty: tty) }
        return .activate(app)
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
