import Foundation
import FocusPilotCore

/// The raccoon's moments (D12): `RaccoonMoments` decides which one is due;
/// this asks it when a snapshot arrives, on a blocked visit and every 15
/// seconds while a session or an approved plan is under way, and shows the
/// answer. What was shown is kept in memory only. Bubble buttons run the
/// same commands as the menu bar and focus panel.
extension AppModel {
    /// Today's runs, with the active session's run as the snapshot has it,
    /// which may be newer than the last read.
    var raccoonRuns: [PlanRun] {
        guard let current = snapshot.planRun else { return raccoonPlanRuns }
        return raccoonPlanRuns.filter { $0.blockID != current.blockID } + [current]
    }

    /// Shows the moment due now, if any. A peek on screen gives way only to
    /// a more pressing kind; one about an earlier session is withdrawn once
    /// another session is the latest.
    func evaluateRaccoonMoments() {
        let session = snapshot.session
        if let shown = raccoon.moment?.sessionID, shown != session?.id {
            raccoon.endPeek(reevaluating: false)
        }
        let now = Date.now
        guard let moment = RaccoonMoments.next(mode: displayPreferences.raccoonMode, session: session,
                                               extended: session.flatMap { raccoonExtensions[$0.id] } ?? 0,
                                               endedBreak: raccoonEndedBreak, quickTimer: snapshot.quickTimer,
                                               plan: raccoonPlan, runs: raccoonRuns, blockedVisitAt: lastBlockedVisitAt,
                                               agentsNeedingYou: agentsNeedingYou, shown: raccoonShownMoments, at: now, timeZone: .autoupdatingCurrent)
        else { return }
        if let current = raccoon.moment, current.kind >= moment.kind { return }
        // A day on, every moment shown is stale anyway, so the memory stays small.
        raccoonShownMoments = raccoonShownMoments.filter { now.timeIntervalSince($0.value) < 86_400 }
        raccoonShownMoments[moment.id] = now
        raccoon.show(moment)
        // The end and break-ending warnings' sound comes with their peek, once.
        if moment.kind == .endWarning || moment.kind == .breakEnding { playTimeUpSound(.soon) }
    }

    /// Notes a break the owner took that ran out, for "Break's over". One
    /// ended with Back to Task, before its end, is not noted.
    func noteRaccoonBreakEnd(from old: FocusSession?, to new: FocusSession?) {
        guard let old, let new, old.id == new.id, case .onBreak(let until, true) = old.phase else { return }
        if case .onBreak = new.phase { return }
        if Date.now >= until { raccoonEndedBreak = RaccoonMoments.EndedBreak(sessionID: new.id, until: until) }
    }

    /// A blocked app was hidden, or Chrome showed its blocked page.
    func noteBlockedVisit() {
        lastBlockedVisitAt = .now
        evaluateRaccoonMoments()
    }

    /// Reads today's plan again; a plan change also changes the snapshot.
    /// Reads from the snapshot loop and the timer can overlap, so a read
    /// that finishes after a later one is dropped.
    func refreshRaccoonPlan() async {
        guard displayPreferences.raccoonMode != .off, let coordinator else { return }
        raccoonPlanReads += 1
        let read = raccoonPlanReads
        guard let (plan, runs) = try? await coordinator.planToFollowToday(), read == raccoonPlanReads else { return }
        if plan != raccoonPlan { raccoonPlan = plan }
        raccoonPlanRuns = runs
    }

    func refreshRaccoonMoments() async {
        await refreshRaccoonPlan()
        raccoon.update()
        evaluateRaccoonMoments()
    }

    /// Time-based moments (ten minutes left, a break or block coming up)
    /// have no event of their own: they are looked for when the next one
    /// falls due, and at least every 15 seconds while a session or an
    /// approved plan is under way.
    func followRaccoonMoments() {
        raccoonMomentsTask?.cancel()
        raccoonMomentsTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let due = RaccoonMoments.nextDue(session: snapshot.session, quickTimer: snapshot.quickTimer,
                                                 plan: raccoonPlan, runs: raccoonRuns, at: .now, timeZone: .current)
                let wait = min(15, max(0.2, (due?.timeIntervalSinceNow ?? 15) + 0.2))
                try? await Task.sleep(for: .seconds(wait), tolerance: .seconds(wait < 15 ? 0.2 : 5))
                guard displayPreferences.raccoonMode != .off,
                      snapshot.activeSession != nil || snapshot.quickTimer != nil || raccoonPlan?.state == .approved
                        || raccoon.moment != nil
                else { continue }
                await refreshRaccoonMoments()
            }
        }
    }

    /// A bubble button: the same commands as the menu bar and focus panel.
    /// A command's snapshot looks for the next moment once it took effect.
    func performRaccoonAction(_ action: RaccoonPeekAction) {
        switch action {
        case .gotIt, .done:
            raccoon.endPeek()
        case .extend(let minutes):
            raccoon.endPeek(reevaluating: false)
            Task { await extend(minutes: minutes) }
        case .keepGoing(let minutes):
            raccoon.endPeek(reevaluating: false)
            Task { await keepGoing(minutes: minutes) }
        case .takeBreak(let minutes):
            raccoon.endPeek(reevaluating: false)
            Task { await takeBreak(minutes: minutes) }
        case .backToTask:
            raccoon.endPeek(reevaluating: false)
            Task { await endBreak() }
        case .goToAgent(let agentID):
            raccoon.endPeek()
            Task { await goToAgent(agentID, from: .raccoon) }
        }
    }
}
