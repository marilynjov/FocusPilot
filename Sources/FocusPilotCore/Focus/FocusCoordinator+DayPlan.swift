import Foundation

/// Day plans built by hand on the Today timeline (D1, decision 0004), and
/// following an approved one (D3): each task block runs as an ordinary focus
/// session through `FocusEngine`, decided by `PlanSessions`.
extension FocusCoordinator {
    public func dayPreferences() async throws -> DayPreferences {
        try await repository.dayPreferences()
    }

    public func saveDayPreferences(_ preferences: DayPreferences) async throws {
        try await repository.saveDayPreferences(preferences)
    }

    public func dayPlan(for date: LocalDate) async throws -> DayPlan {
        try await repository.dayPlan(for: date)
    }

    public func addBlock(_ block: DayBlock, to date: LocalDate, confirmed: Bool = false) async throws -> DayPlanEdit {
        let edit = try await repository.addBlock(block, to: date, confirmed: confirmed)
        await followPlanAfterAction()
        return edit
    }

    /// Captures a new task and places its block in one step (#29). Following
    /// the plan afterwards broadcasts, so subscribers hear of the new task.
    public func addBlock(_ block: DayBlock, forNew newTask: NewTask, to date: LocalDate,
                         confirmed: Bool = false) async throws -> DayPlanEdit {
        let edit = try await repository.addBlock(block, forNew: newTask, to: date, confirmed: confirmed)
        await followPlanAfterAction()
        return edit
    }

    public func updateBlock(_ block: DayBlock, in date: LocalDate, confirmed: Bool = false) async throws -> DayPlanEdit {
        let edit = try await repository.updateBlock(block, in: date, confirmed: confirmed)
        await followPlanAfterAction()
        return edit
    }

    public func deleteBlock(_ id: Int64, from date: LocalDate) async throws -> DayPlan {
        let plan = try await repository.deleteBlock(id, from: date)
        await followPlanAfterAction()
        return plan
    }

    /// Approves the plan and follows it right away: a block already in
    /// progress starts for the time left.
    public func approveDayPlan(for date: LocalDate) async throws -> DayPlan {
        let plan = try await repository.approveDayPlan(for: date)
        await followPlanAfterAction()
        return plan
    }

    /// Follows the plan after an owner action that already succeeded. A
    /// failure here is the plan's, not the action's: it is shown on its own
    /// through the snapshot, and the next deadline or wake tries again.
    func followPlanAfterAction() async {
        do {
            try await followPlan()
        } catch {
            planFailure = "Could not follow today’s plan: \(error.localizedDescription)"
            await broadcast()
        }
    }

    /// "I need more time" on the running block. Recorded only; the block
    /// still ends at its planned end until replanning (D10) exists.
    public func requestMoreTime() async throws {
        guard let active = session, !active.hasEnded else { throw SessionError.noCurrentTask }
        planRun = try await repository.requestMoreTime(for: active.id)
        await broadcast()
    }

    /// Takes every step today's approved plan asks for now, then notes when
    /// it next asks. Called at launch, at every deadline, after the owner
    /// ends or resumes a session, and after plan edits. Owner sessions,
    /// strict ones included, are never replaced: a block that starts during
    /// one waits for it to end, then runs for the time it has left.
    func followPlan() async throws {
        planFailure = nil
        let timeZone = timeZone()
        // A step can lead to another: a block starting during its own lunch
        // starts on a break. Bounded so a bug cannot spin.
        for _ in 0..<4 {
            let now = now()
            let date = LocalDate(containing: now, in: timeZone)
            let (plan, runs) = try await repository.planToFollow(on: date)
            guard let plan, let step = PlanSessions.step(plan: plan, runs: runs, session: session, at: now, timeZone: timeZone)
            else { break }
            do {
                switch step {
                case .startSession(let block):
                    let run = PlanRun(blockID: block.blockID, sessionID: UUID(), startedAt: now)
                    let request = SessionRequest(id: run.sessionID, taskID: block.taskID, action: block.title, mode: .normal,
                                                 duration: block.end.timeIntervalSince(now))
                    try await handle(.start(request), planChange: .started(run, planDate: date, taskID: block.taskID))
                    await notices.deliver(.planBlockStarted(title: block.title, end: block.end))
                case .startBreak(let due, let sessionID):
                    try await handle(.startBreak(duration: due.end.timeIntervalSince(now)),
                                     planChange: .breakStarted(sessionID: sessionID, breakID: due.blockID))
                }
            } catch is FocusEngineError {
                // Another step got in first (the owner started, paused or
                // ended a session meanwhile): look again at the new state.
                continue
            }
        }
        // Worked out after the steps, however many there were.
        let now = now()
        let date = LocalDate(containing: now, in: timeZone)
        let (plan, runs) = try await repository.planToFollow(on: date)
        planDeadline = plan.flatMap { PlanSessions.nextDeadline(plan: $0, runs: runs, at: now, timeZone: timeZone) }
        if let active = session, !active.hasEnded {
            planRun = try await repository.planRun(for: active.id)
        } else {
            planRun = nil
        }
        await broadcast()
    }
}
