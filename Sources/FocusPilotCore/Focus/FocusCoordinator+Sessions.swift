import Foundation

/// Focus sessions: the coordinator feeds owner commands and the passing of
/// time to `FocusEngine` and performs the effects it returns, in order.
extension FocusCoordinator {
    /// Loads the last session and reconciles it with the clock, so a session
    /// that ended while the app was quit is recorded at its planned end and
    /// the extensions get a fresh policy.
    public func launch() async throws {
        session = try await repository.latestSession()
        try await handle(.reconcile)
        try await repository.forgetEndedExceptions()
        if policy == nil {
            try await publish(repository.republish())
        }
        try await launchQuickTimer()
        // Catches up on a block in progress; one already over never starts.
        try await followPlan()
    }

    /// Starts a session on the pinned Now task.
    public func startSession(duration: TimeInterval, mode: SessionMode) async throws {
        guard let task = try await repository.nowTask() else { throw SessionError.noCurrentTask }
        try await handle(.start(SessionRequest(id: UUID(), taskID: task.id, action: task.title, mode: mode, duration: duration)))
    }

    public func pause() async throws {
        try await handle(.pause)
    }

    public func resume() async throws {
        try await handle(.resume)
        try await followPlan()
    }

    /// Applies any deadline the clock has passed. Called at `nextDeadline`,
    /// after the Mac wakes, and at launch.
    public func reconcile() async throws {
        try await handle(.reconcile)
        try await repository.forgetEndedExceptions()
        try await followPlan()
    }

    /// Completes the session. A strict session ending before its planned end
    /// first needs the owner's confirmation, then waits `StrictEarlyEnd.wait`
    /// from that confirmation on the monotonic clock; until then it keeps
    /// running. Completing a plan block's session before the block ends is
    /// "Done early": the block is recorded as ended then (D3).
    public func complete(confirmed: Bool = false) async throws -> SessionCompletion {
        if let active = session, !active.hasEnded, active.mode == .strict, now() < active.plannedEnd {
            if earlyEnd?.request != active.id {
                guard confirmed else { return .needsConfirmation }
                earlyEnd = StrictWait(request: active.id, confirmedAt: uptime())
                await broadcast()
            }
            if let availableAt = earlyEndAvailableAt(), now() < availableAt { return .waitUntil(availableAt) }
        }
        var planChange: PlanRunChange?
        if let active = session, !active.hasEnded, planRun?.sessionID == active.id, now() < active.plannedEnd {
            planChange = .endedEarly(sessionID: active.id, at: now())
        }
        try await handle(.complete, planChange: planChange)
        try await followPlan()
        return .completed
    }

    /// When the confirmed early end may complete, measured on `uptime` and
    /// shown on the wall clock; `nil` when the owner has not confirmed.
    func earlyEndAvailableAt() -> Date? {
        earlyEnd.map(availableAt)
    }

    /// When a strict wait is over, on the wall clock for display.
    func availableAt<Request>(_ wait: StrictWait<Request>) -> Date {
        now().addingTimeInterval(wait.remaining(at: uptime()) / .seconds(1))
    }

    /// The owner changed their mind about ending a strict session early.
    public func cancelEarlyEnd() async {
        earlyEnd = nil
        await broadcast()
    }

    /// One engine step: record the session, revisions and any plan block
    /// change in one write, then publish the wrapped policies and deliver notices.
    func handle(_ event: FocusEvent, planChange: PlanRunChange? = nil) async throws {
        let at = now()
        let transition = try FocusEngine.handle(event, session: session, at: at)
        // Starting a strict session cancels exceptions granted before it,
        // for apps and sites (decision 0003, 2026-10-22).
        var cancelsExceptions = false
        if case .start(let request) = event, request.mode == .strict { cancelsExceptions = true }
        let recorded = try await repository.record(transition, cancellingExceptionsAt: cancelsExceptions ? at : nil,
                                                   planChange: planChange)
        var revisions = recorded.revisions.makeIterator()
        session = transition.session
        if session?.hasEnded != false {
            earlyEnd = nil
            ruleWait = nil
            exceptionWait = nil
            exceptionWaitReason = nil
        }
        for effect in transition.effects {
            switch effect {
            case .persist:
                break
            case .publishPolicy(let sessionPolicy):
                await publish(revision: revisions.next()!, inputs: recorded.inputs, session: sessionPolicy, at: at)
            case .notify(let notice):
                await notices.deliver(notice)
            }
        }
        await broadcast()
    }
}
