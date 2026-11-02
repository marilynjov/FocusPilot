import Foundation

/// The session's part of the policy that browser extensions enforce.
///
/// Published while session rules apply or are due to apply again. The compiled policy (always-on and
/// scheduled rule sets, exceptions) wraps this later; it is not built here.
public struct SessionPolicy: Equatable, Sendable {
    public var sessionID: UUID
    public var mode: SessionMode
    /// Absolute, so an extension can stop on time (normal) or keep going (strict) without the app.
    public var end: Date
    /// Set during a normal-session break: session rules are lifted until this
    /// instant, then apply again even if the app has crashed in between.
    public var resumesAt: Date?

    public init(sessionID: UUID, mode: SessionMode, end: Date, resumesAt: Date? = nil) {
        self.sessionID = sessionID
        self.mode = mode
        self.end = end
        self.resumesAt = resumesAt
    }
}

/// Something the owner should be told.
public enum FocusNotice: Equatable, Sendable {
    case sessionReachedPlannedEnd
    case breakEnded
    /// A block of the approved plan started a session that ends at `end`.
    case planBlockStarted(title: String, end: Date)
    /// A new exception granted from Chrome's blocked page (not one already
    /// covered), so a grant the owner did not ask for does not go unnoticed.
    case exceptionGrantedFromChrome(ExceptionScope, until: Date)
    /// A quick timer (D2) has 2 minutes left, or has reached its end.
    case quickTimerAlmostUp(label: String?)
    case quickTimerUp(label: String?)
}

/// Work the engine asks the coordinator to perform, in order.
public enum FocusEffect: Equatable, Sendable {
    case persist(FocusSession)
    /// `nil` means no session rules apply.
    case publishPolicy(SessionPolicy?)
    case notify(FocusNotice)
}

/// The engine's answer: the session after the event and the effects to perform.
public struct FocusTransition: Equatable, Sendable {
    public var session: FocusSession?
    public var effects: [FocusEffect]
}
