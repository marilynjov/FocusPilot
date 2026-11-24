import Foundation

/// A Claude Code chat in a Warp window of its own (decision 0005, owner's
/// choices of 2026-11-10 and 2026-11-11): a Warp launch configuration,
/// opened with `warp://launch/<name>`, whose one tab runs Claude Code in a
/// folder and is titled with the task and a token made for this window.
/// Warp keeps that title on the window, and the chat reports the token
/// (`FOCUSPILOT_WINDOW`), so Go to agent can find that chat's own window
/// later, even with several agents on one task. Started fresh, or resuming
/// a chat that runs elsewhere. Only ever written for the owner's click.
///
/// Warp runs what this file says, so nothing the owner or an agent typed
/// reaches the command: it is fixed text, the task's number, the token
/// FocusPilot made, and for a resume a session ID checked to be a UUID. The
/// title and folder are double-quoted YAML scalars with everything that
/// could end one escaped, and the folder must be an existing absolute
/// directory with no shell characters in it. Sources: docs.warp.dev/terminal/sessions/launch-configurations
/// (the format, the folder, `cwd` absolute) and docs.warp.dev/terminal/more-features/uri-scheme,
/// and the owner's Mac on 2026-11-10.
///
/// Any local process could set `FOCUSPILOT_WINDOW` to another window's
/// token; the most that does is make Go to agent raise a different
/// FocusPilot window.
public struct WarpLaunch: Equatable, Sendable {
    /// Eight lowercase hex digits, new for each window (`newToken`).
    public private(set) var token: String
    public let taskID: Int64
    /// "FocusPilot · Write chapter 2 · 3fa9c01b", as Warp shows it on the window.
    public private(set) var windowTitle: String
    private let taskTitle: String
    /// Standardized, absolute and existing when this was made.
    public let folder: String
    /// The Claude Code session to resume, a UUID; nil starts a new chat.
    public let resumedSession: String?

    /// Nil when the token, the task number, the session ID or the folder
    /// can't be used (see `isToken`, `isSessionID`, `usableFolder`).
    public init?(token: String = WarpLaunch.newToken(), taskID: Int64, taskTitle: String, folder: String,
                 resuming session: String? = nil, fileManager: FileManager = .default) {
        guard Self.isToken(token), taskID > 0, session.map(Self.isSessionID) ?? true,
              let folder = Self.usableFolder(folder, fileManager: fileManager) else { return nil }
        self.token = token
        self.taskID = taskID
        self.taskTitle = taskTitle
        windowTitle = AgentWorkspace.warpWindowTitle(taskTitle: taskTitle, token: token)
        self.folder = folder
        resumedSession = session
    }

    /// The environment variables `focuspilot agent report` reads: the task,
    /// when no `--task` is given, so the agent reports already linked; and
    /// the window, so Go to agent can find it.
    public static let taskVariable = "FOCUSPILOT_TASK"
    public static let windowVariable = "FOCUSPILOT_WINDOW"

    /// A new window token: eight lowercase hex digits from the system's
    /// random generator.
    public static func newToken() -> String {
        String(format: "%08x", UInt32.random(in: .min ... .max))
    }

    /// Exactly eight lowercase hex digits; a token from a report is
    /// untrusted and anything else is ignored.
    public static func isToken(_ value: String) -> Bool {
        value.utf8.count == 8 && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// A canonical UUID, 8-4-4-4-12 hex digits, as Claude Code's session
    /// IDs are. Only such a value goes into `claude --resume`.
    public static func isSessionID(_ value: String) -> Bool {
        let groups = value.split(separator: "-", omittingEmptySubsequences: false)
        return groups.map(\.utf8.count) == [8, 4, 4, 4, 12]
            && groups.allSatisfy { $0.utf8.allSatisfy { $0 < 0x80 && Character(Unicode.Scalar($0)).isHexDigit } }
    }

    /// "focuspilot-window-3fa9c01b": the file's name and the configuration's.
    public var name: String { Self.name(token) }

    static func name(_ token: String) -> String { windowPrefix + token }

    static let windowPrefix = "focuspilot-window-"

    /// The one command the tab runs: fixed text, the task's number, the
    /// token and the checked session ID only. `env` sets the variables the
    /// same way in zsh, bash, fish and csh. `--resume` keeps the session's
    /// ID (`--fork-session` would make a new one; `claude --help`, 2.1.294).
    public var command: String {
        "env \(Self.taskVariable)=\(taskID) \(Self.windowVariable)=\(token) claude"
            + (resumedSession.map { " --resume \($0)" } ?? "")
    }

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

    /// `warp://launch/focuspilot-window-3fa9c01b`. The name is letters,
    /// digits and hyphens, so nothing in it needs encoding.
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

    /// Writes the configuration into `directory`, made if missing. Returns
    /// the file. A window never takes over another's file: if the token is
    /// taken, a new one is made, a few times at most.
    @discardableResult
    public mutating func write(into directory: URL, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for _ in 0..<5 where fileManager.fileExists(atPath: Self.file(token, in: directory).path) {
            token = Self.newToken()
            windowTitle = AgentWorkspace.warpWindowTitle(taskTitle: taskTitle, token: token)
        }
        let file = Self.file(token, in: directory)
        guard !fileManager.fileExists(atPath: file.path) else { throw CocoaError(.fileWriteFileExists) }
        try Data(yaml.utf8).write(to: file, options: .atomic)
        return file
    }

    static func file(_ token: String, in directory: URL) -> URL {
        directory.appendingPathComponent(name(token) + ".yaml", isDirectory: false)
    }

    /// The window title in the window's launch configuration, as written
    /// when it was opened; nil if the token isn't one, FocusPilot never
    /// wrote the file, or it no longer reads as one.
    public static func windowTitle(ofWindow token: String, in directory: URL) -> String? {
        guard isToken(token) else { return nil }
        return configuration(at: file(token, in: directory)).flatMap { windowTitle(inConfiguration: $0) }
    }

    /// The file's text, if it is a regular file (not a link, pipe or
    /// device) of at most 64 KB.
    private static func configuration(at file: URL, fileManager: FileManager = .default) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? .max <= 64 * 1024,
              let data = try? Data(contentsOf: file) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The first tab's `title:` value, read back from the double-quoted
    /// scalar `yaml` writes.
    static func windowTitle(inConfiguration text: String) -> String? {
        value(of: "- title: ", in: text)
    }

    /// The task in the command's `FOCUSPILOT_TASK=`, read back.
    static func taskID(inConfiguration text: String) -> Int64? {
        guard let command = value(of: "- exec: ", in: text) else { return nil }
        let prefix = taskVariable + "="
        return command.split(separator: " ").first { $0.hasPrefix(prefix) }.flatMap { Int64($0.dropFirst(prefix.count)) }
    }

    /// The session the command resumes, read back; nil for a new chat.
    static func resumedSession(inConfiguration text: String) -> String? {
        guard let words = value(of: "- exec: ", in: text)?.split(separator: " "),
              let flag = words.firstIndex(of: "--resume"), flag + 1 < words.count else { return nil }
        let session = String(words[flag + 1])
        return isSessionID(session) ? session : nil
    }

    /// A window's configuration on disk, as Go to agent and the panel need it.
    public struct OnDisk: Hashable, Sendable {
        public var token: String
        /// The Claude Code session it resumes; nil for a new chat.
        public var resumedSession: String?

        public init(token: String, resumedSession: String? = nil) {
            self.token = token
            self.resumedSession = resumedSession
        }
    }

    private static func value(of key: String, in text: String) -> String? {
        guard let line = text.split(separator: "\n").lazy
            .map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { $0.hasPrefix(key) })
        else { return nil }
        return unquoted(String(line.dropFirst(key.count)))
    }

    // MARK: Tidying up

    /// A window's configuration no agent reports from is kept this long, so
    /// a chat just opened has time to report.
    public static let unreportedLifetime: TimeInterval = 24 * 3600

    /// One file in the launch configurations directory, as tidying sees it.
    struct Listed: Equatable {
        var name: String
        var modified: Date?
        /// The task its command names; nil if unreadable.
        var taskID: Int64?
        var resumedSession: String?
    }

    /// The files to remove: per-task configurations from before windows had
    /// tokens; a window whose task is done or gone; and a window no agent
    /// reports from (`referenced`) once it is `unreportedLifetime` old. Files
    /// not named as FocusPilot names them are never touched.
    static func stale(_ files: [Listed], referenced: Set<String>, openTasks: Set<Int64>, now: Date) -> [String] {
        files.filter { file in
            if let id = Int64(file.name.dropFirst("focuspilot-task-".count).dropLast(".yaml".count)),
               file.name == "focuspilot-task-\(id).yaml" { return true }
            guard let token = token(inFileName: file.name) else { return false }
            if let task = file.taskID, !openTasks.contains(task) { return true }
            guard !referenced.contains(token) else { return false }
            return file.modified.map { now.timeIntervalSince($0) > unreportedLifetime } ?? true
        }.map(\.name)
    }

    /// "3fa9c01b" from "focuspilot-window-3fa9c01b.yaml"; nil for any other name.
    static func token(inFileName name: String) -> String? {
        guard name.hasPrefix(windowPrefix), name.hasSuffix(".yaml") else { return nil }
        let token = String(name.dropFirst(windowPrefix.count).dropLast(".yaml".count))
        return isToken(token) ? token : nil
    }

    /// Removes the stale configurations in `directory` (`stale`) and returns
    /// the windows still there.
    @discardableResult
    public static func removeStale(referenced: Set<String>, openTasks: Set<Int64>, in directory: URL, now: Date = .now,
                                   fileManager: FileManager = .default) -> Set<OnDisk> {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        let files = names.filter { $0.hasPrefix("focuspilot-") && $0.hasSuffix(".yaml") }.map { name in
            let url = directory.appendingPathComponent(name)
            let modified = (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            let text = token(inFileName: name) == nil ? nil : configuration(at: url, fileManager: fileManager)
            return Listed(name: name, modified: modified, taskID: text.flatMap { taskID(inConfiguration: $0) },
                          resumedSession: text.flatMap { resumedSession(inConfiguration: $0) })
        }
        let gone = Set(stale(files, referenced: referenced, openTasks: openTasks, now: now))
        for name in gone { try? fileManager.removeItem(at: directory.appendingPathComponent(name)) }
        return Set(files.filter { !gone.contains($0.name) }.compactMap { file in
            token(inFileName: file.name).map { OnDisk(token: $0, resumedSession: file.resumedSession) }
        })
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
