import Foundation

/// The hooks block the owner pastes into `~/.claude/settings.json`: each
/// event FocusPilot listens to calls `focuspilot agent report
/// --from-claude-hook <event>`, which reads the hook's JSON from stdin, so
/// no jq is needed. Format from https://code.claude.com/docs/en/hooks
/// (read 2026-11-03). FocusPilot never writes the file itself.
public enum ClaudeHookSnippet {
    /// `command` is the focuspilot command: "focuspilot" when it is on the
    /// PATH, or the path inside the app. Every hook is `async`, so Claude
    /// Code never waits for FocusPilot and nothing it prints reaches Claude.
    public static func settings(command: String = "focuspilot") -> String {
        let invocation = shellQuoted(command)
        let events = ClaudeHookEvent.allCases.map { event in
            let line = jsonString("\(invocation) agent report --from-claude-hook \(event.rawValue)")
            return """
                    "\(event.rawValue)": [
                      { "hooks": [{ "type": "command", "command": \(line), "async": true }] }
                    ]
                """
        }
        return "{\n  \"hooks\": {\n" + events.joined(separator: ",\n") + "\n  }\n}\n"
    }

    /// Left alone when it is a plain word or path; single-quoted otherwise,
    /// as the hook runs in a shell.
    static func shellQuoted(_ word: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-~"))
        if !word.isEmpty, word.unicodeScalars.allSatisfy({ $0.isASCII && plain.contains($0) }) { return word }
        return "'" + word.replacing("'", with: "'\\''") + "'"
    }

    private static func jsonString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data()
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}
