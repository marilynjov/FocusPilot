import Foundation


/// An immutable picture of FocusCoordinator state for the UI to display.
public struct FocusSnapshot: Equatable, Sendable {
    /// SF Symbol used inside the app where the custom glyph is not drawn yet
    /// (logo design 2d). The menu bar uses `MenuBarGlyph` instead.
    public static let fallbackSymbolName = "scope"

    public var currentTaskTitle: String?
    /// The latest session, which may have ended; `nil` before the first one.
    public var session: FocusSession?
    /// Observe-only mode measures without blocking (#21): when it started.
    public var observeSince: Date?
    public var isObserveOnly: Bool { observeSince != nil }
    /// When a strict session the owner asked to end early may be completed;
    /// `nil` when no early end is waiting.
    public var earlyEndAvailableAt: Date?
    /// The last policy published to the extensions.
    public var policy: CompiledPolicy?
    /// A rule change waiting out its strict-session delay.
    public var pendingRuleEdit: PendingRuleEdit?
    /// A strict-session exception waiting out its delay.
    public var pendingException: PendingException?
    /// The quick timer still running (D2), separate from any session.
    public var quickTimer: QuickTimer?
    /// The plan block the active session runs, if it is one (D3).
    public var planRun: PlanRun?
    /// When the approved plan next starts a block or a break inside one.
    public var planDeadline: Date?
    /// Why the approved plan could not be followed just now, if it could not.
    public var planFailure: String?
    /// Higher for later coordinator states; the app keeps the newest.
    public var revision: Int

    public init(currentTaskTitle: String? = nil, session: FocusSession? = nil, observeSince: Date? = nil,
                earlyEndAvailableAt: Date? = nil, policy: CompiledPolicy? = nil,
                pendingRuleEdit: PendingRuleEdit? = nil, pendingException: PendingException? = nil,
                quickTimer: QuickTimer? = nil, planRun: PlanRun? = nil, planDeadline: Date? = nil,
                planFailure: String? = nil,
                revision: Int = 0) {
        self.currentTaskTitle = currentTaskTitle
        self.session = session
        self.observeSince = observeSince
        self.earlyEndAvailableAt = earlyEndAvailableAt
        self.policy = policy
        self.pendingRuleEdit = pendingRuleEdit
        self.pendingException = pendingException
        self.quickTimer = quickTimer
        self.planRun = planRun
        self.planDeadline = planDeadline
        self.planFailure = planFailure
        self.revision = revision
    }

    /// The session that is still running, paused or on a break.
    public var activeSession: FocusSession? {
        guard let session, !session.hasEnded else { return nil }
        return session
    }

    /// Whether session-only rules block now: while running, and through
    /// pauses and breaks of a strict session.
    public var sessionRulesApply: Bool {
        guard let active = activeSession, let policy = FocusEngine.policy(for: active) else { return false }
        return policy.resumesAt == nil
    }

    /// When the coordinator must next be asked to reconcile, such as the
    /// planned end, the end of a break, an exception expiring or the next
    /// block of the approved plan. A quick
    /// timer has its own (`QuickTimer.nextDeadline`): reconciling it
    /// publishes no policy.
    public var nextDeadline: Date? {
        ([activeSession?.nextDeadline, planDeadline] + (policy?.exceptions.map(\.expiresAt) ?? [])).compactMap { $0 }.min()
    }

    /// The run of the active session's plan block, if it is one.
    public var activePlanRun: PlanRun? {
        guard let planRun, planRun.sessionID == activeSession?.id else { return nil }
        return planRun
    }

    /// The state line shown inside the menu and the planning window.
    public var statusText: String {
        activeSession?.action ?? currentTaskTitle ?? "No current task"
    }
}
