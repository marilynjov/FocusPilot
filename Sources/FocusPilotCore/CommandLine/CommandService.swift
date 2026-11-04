import Foundation

/// A request over the command socket, one per connection: from the
/// focuspilot CLI, or an exception request the Chrome host relays from the
/// blocked page (#14).
public enum CommandRequest: Codable, Equatable, Sendable {
    case add(HerdrAddRequest)
    case tasks(HerdrCaller?)
    case exception(ExceptionCommand)
    /// The owner left a strict-session exception wait for this scope.
    case cancelException(ExceptionScope)
    /// An agent's status, from `focuspilot agent report` or `run` (decision 0005).
    case agentReport(AgentReport)
}

/// A timed exception as the blocked page asks for it.
public struct ExceptionCommand: Codable, Equatable, Sendable {
    public var scope: ExceptionScope
    public var duration: TimeInterval
    public var reason: String?
    public var confirmed: Bool

    public init(scope: ExceptionScope, duration: TimeInterval, reason: String?, confirmed: Bool) {
        self.scope = scope
        self.duration = duration
        self.reason = reason
        self.confirmed = confirmed
    }
}

public enum CommandResponse: Codable, Equatable, Sendable {
    case added(HerdrAddResult)
    case tasks(HerdrTaskScope)
    case exception(ExceptionOutcome)
    case exceptionCancelled
    case agentRecorded(AgentReportReceipt)
    /// Not done, with a message for the caller, e.g. the rate limit.
    case refused(String)
    case failed(String)
}

/// At most `limit` adds per pane in any `window`, so an agent stuck in a
/// loop cannot flood the owner's list. Only allowed adds count.
public struct AddRateLimit: Sendable {
    public static let limit = 20

    /// The most allowed per key in any `window`.
    private let limit: Int
    public static let window: TimeInterval = 60

    private var recent: [String: [Date]] = [:]

    public init(limit: Int = Self.limit) {
        self.limit = limit
    }

    /// Records the add and returns true if it is within the limit. Panes
    /// with no add in the last window are forgotten, so closed panes do not
    /// pile up for as long as the app runs.
    public mutating func allow(_ pane: String, at now: Date) -> Bool {
        recent = recent.compactMapValues { times in
            let kept = times.filter { now.timeIntervalSince($0) < Self.window }
            return kept.isEmpty ? nil : kept
        }
        let kept = recent[pane] ?? []
        guard kept.count < limit else { return false }
        recent[pane] = kept + [now]
        return true
    }

    var trackedPanes: Int { recent.count }

    /// The key adds are counted under; every add from outside Herdr shares one.
    public static func key(for caller: HerdrCaller?) -> String {
        caller?.paneID ?? "outside Herdr"
    }
}

/// Where exception requests go: the coordinator, which applies the
/// strict-session confirmation and wait.
public protocol ExceptionGate: Sendable {
    func requestException(_ scope: ExceptionScope, duration: TimeInterval, reason: String?, confirmed: Bool,
                          origin: ExceptionOrigin) async throws -> ExceptionOutcome
    func cancelException(for scope: ExceptionScope) async
}

extension FocusCoordinator: ExceptionGate {}

/// Answers command-socket requests inside the running app. CLI callers can
/// only append tasks and read; everything written goes through
/// `TaskRepository`. Exception requests are taken only from callers
/// `ExceptionCallerCheck` allows: in the app, the bundled Chrome host started
/// by a Google-signed Chrome (see there for exactly what that guarantees).
/// The focuspilot CLI, or the host started from a shell, is refused.
public actor CommandService {
    static let rateLimitMessage =
        "Refused: this pane has added \(AddRateLimit.limit) tasks in the last minute. Wait a minute and try again."
    static let exceptionCallerMessage = "Only the FocusPilot blocked page in Chrome can ask for a site exception."
    public static let monitoringOffMessage =
        "Refused: agent monitoring is off in FocusPilot. Turn it on in FocusPilot › Settings › General › Agent monitoring."
    static let reportRateLimitMessage =
        "Refused: this agent has reported \(AddRateLimit.limit) times in the last minute. Wait a minute and try again."
    /// Reports from all agents together in any minute.
    static let allReportsLimit = 60
    static let allReportsLimitMessage =
        "Refused: agents have reported \(allReportsLimit) times in the last minute. Wait a minute and try again."
    static let newAgentsLimitMessage =
        "Refused: \(ReportedAgentStore.newAgentsPerMinute) new agents have reported in the last minute. Wait a minute and try again."

    private let repository: TaskRepository
    private let exceptions: (any ExceptionGate)?
    /// Nil refuses every exception request.
    private let exceptionCaller: ExceptionCallerCheck?
    private let now: @Sendable () -> Date
    private var rateLimit = AddRateLimit()
    /// Reports count per agent, apart from adds, and all together, so a
    /// process making up new agents cannot flood the owner either.
    private var reportLimit = AddRateLimit()
    private var allReports = AddRateLimit(limit: CommandService.allReportsLimit)

    public init(repository: TaskRepository, exceptions: (any ExceptionGate)? = nil, exceptionCaller: ExceptionCallerCheck? = nil,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.repository = repository
        self.exceptions = exceptions
        self.exceptionCaller = exceptionCaller
        self.now = now
    }

    public func handle(_ request: CommandRequest, from peer: CommandPeer? = nil) async -> CommandResponse {
        switch request {
        case .exception(let command):
            guard let exceptions = gate(for: peer) else { return .refused(Self.exceptionCallerMessage) }
            do {
                return .exception(try await exceptions.requestException(command.scope, duration: command.duration,
                                                                        reason: command.reason, confirmed: command.confirmed,
                                                                        origin: .chrome))
            } catch let error as ExceptionError {
                return .refused(ExceptionErrorText.message(error))
            } catch {
                return .failed("FocusPilot could not allow it: \(error.localizedDescription)")
            }
        case .cancelException(let scope):
            guard let exceptions = gate(for: peer) else { return .refused(Self.exceptionCallerMessage) }
            await exceptions.cancelException(for: scope)
            return .exceptionCancelled
        case .add(let add):
            guard add.capture.task.isValid else { return .refused("Nothing to add: the task needs a title.") }
            guard rateLimit.allow(AddRateLimit.key(for: add.caller), at: now()) else {
                return .refused(Self.rateLimitMessage)
            }
            do {
                return .added(try await repository.addFromHerdr(add))
            } catch {
                return .failed("FocusPilot could not save the task: \(error.localizedDescription)")
            }
        case .agentReport(let raw):
            // Cleaned again: any local process can write to the socket.
            guard let report = try? raw.sanitized().report else { return .refused("Refused: the report needs a --name.") }
            guard allReports.allow("all", at: now()) else { return .refused(Self.allReportsLimitMessage) }
            guard reportLimit.allow("\(report.source.rawValue) \(report.identity)", at: now()) else {
                return .refused(Self.reportRateLimitMessage)
            }
            do {
                guard let receipt = try await repository.recordAgentReport(report) else {
                    return .refused(Self.monitoringOffMessage)
                }
                return .agentRecorded(receipt)
            } catch ReportedAgentStore.Refusal.tooManyNewAgents {
                return .refused(Self.newAgentsLimitMessage)
            } catch {
                return .failed("FocusPilot could not record the report: \(error.localizedDescription)")
            }
        case .tasks(let caller):
            do {
                return .tasks(try await repository.herdrScope(for: caller))
            } catch {
                return .failed("FocusPilot could not read the tasks: \(error.localizedDescription)")
            }
        }
    }

    private func gate(for peer: CommandPeer?) -> (any ExceptionGate)? {
        guard let exceptions, let exceptionCaller, exceptionCaller.allows(peer) else { return nil }
        return exceptions
    }
}

/// What an exception refusal says, on the blocked page and in the app.
public enum ExceptionErrorText {
    public static func message(_ error: ExceptionError) -> String {
        switch error {
        case .unsupportedDuration: "Choose 5, 10 or 20 minutes."
        case .reasonRequired: "Say why you need it for the task."
        case .invalidSite: "That isn't a site address."
        case .invalidPage: "That isn't a web page address."
        case .notBlocked(let host): "\(host) isn't blocked by any rule."
        }
    }
}
