import Foundation

/// Claude Code started for a task in its own Warp window (decision 0005,
/// owner's choice of 2026-11-10): a Warp launch configuration, opened with
/// `warp://launch/<name>`, whose one tab runs in the task's folder and is
/// titled after the task. Warp keeps that title on the window, so Go to
/// agent can find the window later. Only ever written for the owner's click.
///
/// Warp runs what this file says, so nothing the owner or an agent typed
/// reaches the command: it is fixed text and the task's number. The title
/// and folder are double-quoted YAML scalars with everything that could end
/// one escaped, and the folder must be an existing absolute directory with
/// no shell characters in it. Sources: docs.warp.dev/terminal/sessions/launch-configurations
/// (the format, the folder, `cwd` absolute) and docs.warp.dev/terminal/more-features/uri-scheme,
/// and the owner's Mac on 2026-11-10.
public struct WarpLaunch: Equatable, Sendable {
    public let taskID: Int64
    /// "FocusPilot · Write chapter 2", as Warp shows it on the window.
    public let windowTitle: String
    /// Standardized, absolute and existing when this was made.
    public let folder: String

    /// Nil when the task number isn't positive or the folder can't be
    /// used (see `usableFolder`).
    public init?(taskID: Int64, taskTitle: String, folder: String, fileManager: FileManager = .default) {
        guard taskID > 0, let folder = Self.usableFolder(folder, fileManager: fileManager) else { return nil }
        self.taskID = taskID
        windowTitle = AgentWorkspace.warpWindowTitle(taskID: taskID, taskTitle: taskTitle)
        self.folder = folder
    }

    /// The environment variable `focuspilot agent report` reads when no
    /// `--task` is given, so the agent reports already linked.
    public static let taskVariable = "FOCUSPILOT_TASK"

    /// "focuspilot-task-12": the file's name and the configuration's.
    public var name: String { "focuspilot-task-\(taskID)" }

    /// The one command the tab runs: fixed text and the task's number only.
    public var command: String { "\(Self.taskVariable)=\(taskID) claude" }

    /// The launch configuration, one YAML document in the format Warp
    /// documents and the owner's spike opened.
    public var yaml: String {
        """
        ---
        name: \(Self.quoted(name))
        windows:
          - tabs:
              - title: \(Self.quoted(windowTitle))
                layout:
                  cwd: \(Self.quoted(folder))
                  commands:
                    - exec: \(Self.quoted(command))

        """
    }

    /// `warp://launch/focuspilot-task-12`. The name is letters, digits and
    /// hyphens, so nothing in it needs encoding.
    public var url: URL? {
        var components = URLComponents()
        components.scheme = "warp"
        components.host = "launch"
        components.path = "/" + name
        return components.url
    }

    /// `~/.warp/launch_configurations`, where Warp reads them on macOS.
    public static var standardDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".warp/launch_configurations", isDirectory: true)
    }

    /// Writes the configuration into `directory`, made if missing, replacing
    /// an earlier one for the same task. Returns the file.
    @discardableResult
    public func write(into directory: URL, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name + ".yaml", isDirectory: false)
        try Data(yaml.utf8).write(to: file, options: .atomic)
        return file
    }

    /// The folder, standardized, if it is absolute, exists as a directory and
    /// holds no control characters or characters a shell treats specially.
    /// Warp should not hand `cwd` to a shell, but nothing proves it, so a
    /// folder that could change a command if it did is refused.
    public static func usableFolder(_ path: String, fileManager: FileManager = .default) -> String? {
        guard let clean = AgentText.folder(path),
              !clean.unicodeScalars.contains(where: { unsafeInFolder.contains($0) || $0.properties.generalCategory == .control })
        else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: clean, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return clean
    }

    private static let unsafeInFolder = CharacterSet(charactersIn: "`$\\\"';&|<>!")

    /// A YAML double-quoted scalar (YAML 1.2, section 7.3.1): the backslash
    /// and quote escaped, and every control or line-break character written
    /// as an escape, so the value ends only at its closing quote.
    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value):
                out += String(format: "\\x%02X", scalar.value)
            case "\u{2028}", "\u{2029}", "\u{FEFF}":
                out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
