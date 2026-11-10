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
    public var name: String { Self.name(taskID) }

    static func name(_ taskID: Int64) -> String { "focuspilot-task-\(taskID)" }

    /// The one command the tab runs: fixed text and the task's number only.
    /// `env` sets the variable the same way in zsh, bash, fish and csh.
    public var command: String { "env \(Self.taskVariable)=\(taskID) claude" }

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
        let file = Self.file(taskID, in: directory)
        try Data(yaml.utf8).write(to: file, options: .atomic)
        return file
    }

    static func file(_ taskID: Int64, in directory: URL) -> URL {
        directory.appendingPathComponent(name(taskID) + ".yaml", isDirectory: false)
    }

    /// The window title in the task's launch configuration, as written
    /// when Claude Code was started for it; nil if FocusPilot never wrote
    /// one or it no longer reads as one.
    public static func windowTitle(ofTask taskID: Int64, in directory: URL) -> String? {
        guard let data = try? Data(contentsOf: file(taskID, in: directory)), data.count <= 64 * 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return windowTitle(inConfiguration: text)
    }

    /// The first tab's `title:` value, read back from the double-quoted
    /// scalar `yaml` writes.
    static func windowTitle(inConfiguration text: String) -> String? {
        let prefix = "- title: "
        guard let line = text.split(separator: "\n").lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix(prefix) })
        else { return nil }
        return unquoted(String(line.dropFirst(prefix.count)))
    }

    /// Removes the launch configurations of tasks no longer open, so Warp's
    /// list doesn't fill with old ones. Only files named as FocusPilot names
    /// them are touched.
    public static func removeStale(keeping openTasks: Set<Int64>, in directory: URL,
                                   fileManager: FileManager = .default) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix("focuspilot-task-") && name.hasSuffix(".yaml") {
            let number = name.dropFirst("focuspilot-task-".count).dropLast(".yaml".count)
            guard let id = Int64(number), name == Self.name(id) + ".yaml", !openTasks.contains(id) else { continue }
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// The folder, standardized, if it is absolute, exists as a directory and
    /// holds no control characters or characters a shell treats specially.
    /// Warp should not hand `cwd` to a shell, but nothing proves it, so a
    /// folder that could change a command, or expand to another path
    /// (`~`, globs, braces, subshells, comments), if it did is refused.
    /// Spaces are allowed: they are common in folder names and only split
    /// words, which can't run anything.
    public static func usableFolder(_ path: String, fileManager: FileManager = .default) -> String? {
        guard let clean = AgentText.folder(path),
              !clean.unicodeScalars.contains(where: { unsafeInFolder.contains($0) || $0.properties.generalCategory == .control })
        else { return nil }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: clean, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return clean
    }

    private static let unsafeInFolder = CharacterSet(charactersIn: "`$\\\"';&|<>!~*?[]{}()#")

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

    /// Reads back a double-quoted scalar with the escapes `quoted` writes;
    /// nil for anything else.
    static func unquoted(_ text: String) -> String? {
        guard text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") else { return nil }
        var out = ""
        var scalars = Array(text.dropFirst().dropLast().unicodeScalars)[...]
        while let scalar = scalars.popFirst() {
            guard scalar == "\\" else {
                if scalar == "\"" { return nil }
                out.unicodeScalars.append(scalar)
                continue
            }
            switch scalars.popFirst() {
            case "\\": out += "\\"
            case "\"": out += "\""
            case "n": out += "\n"
            case "r": out += "\r"
            case "t": out += "\t"
            case let code? where code == "x" || code == "u":
                let count = code == "x" ? 2 : 4
                guard scalars.count >= count, let value = UInt32(String(String.UnicodeScalarView(scalars.prefix(count))), radix: 16),
                      let decoded = Unicode.Scalar(value) else { return nil }
                scalars = scalars.dropFirst(count)
                out.unicodeScalars.append(decoded)
            default: return nil
            }
        }
        return out
    }
}
