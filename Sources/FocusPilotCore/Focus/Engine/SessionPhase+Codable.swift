import Foundation

/// Stored as `{"kind": ..., <label>: ...}` with every key spelled out, so a
/// renamed case or label fails the golden-JSON tests instead of making
/// previously saved sessions unreadable.
extension SessionPhase: Codable {
    enum CodingKeys: String, CodingKey {
        case kind, since, until, movesEnd, at, reason
    }

    enum Kind: String, Codable {
        case running = "running", paused = "paused", onBreak = "onBreak", ended = "ended"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .running:
            self = .running
        case .paused:
            self = .paused(since: try container.decode(Date.self, forKey: .since))
        case .onBreak:
            // Breaks stored before owner breaks existed (2026-11-03) were
            // all plan breaks, which keep the planned end.
            self = .onBreak(until: try container.decode(Date.self, forKey: .until),
                            movesEnd: try container.decodeIfPresent(Bool.self, forKey: .movesEnd) ?? false)
        case .ended:
            self = .ended(
                at: try container.decode(Date.self, forKey: .at),
                reason: try container.decode(EndReason.self, forKey: .reason)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .running:
            try container.encode(Kind.running, forKey: .kind)
        case .paused(let since):
            try container.encode(Kind.paused, forKey: .kind)
            try container.encode(since, forKey: .since)
        case .onBreak(let until, let movesEnd):
            try container.encode(Kind.onBreak, forKey: .kind)
            try container.encode(until, forKey: .until)
            // Written only when set, so a plan break is stored as before.
            if movesEnd { try container.encode(movesEnd, forKey: .movesEnd) }
        case .ended(let at, let reason):
            try container.encode(Kind.ended, forKey: .kind)
            try container.encode(at, forKey: .at)
            try container.encode(reason, forKey: .reason)
        }
    }
}
