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
        guard let moment = RaccoonMoments.next(mode: displayPreferences.raccoonMode, session: session, plan: raccoonPlan,
                                               runs: raccoonRuns, blockedVisitAt: lastBlockedVisitAt,
                                               shown: raccoonShownMoments, at: now, timeZone: .autoupdatingCurrent)
        else { return }
        if let current = raccoon.moment, current.kind >= moment.kind { return }
        // A day on, every moment shown is stale anyway, so the memory stays small.
        raccoonShownMoments = raccoonShownMoments.filter { now.timeIntervalSince($0.value) < 86_400 }
        raccoonShownMoments[moment.id] = now
        raccoon.show(moment)
    }

    /// A blocked app was hidden, or Chrome showed its blocked page.
    func noteBlockedVisit() {
        lastBlockedVisitAt = .now
        evaluateRaccoonMoments()
    }

    /// Reads today's plan again; a plan change also changes the snapshot.
    func refreshRaccoonPlan() async {
        guard displayPreferences.raccoonMode != .off, let coordinator,
              let (plan, runs) = try? await coordinator.planToFollowToday()
        else { return }
        if plan != raccoonPlan { raccoonPlan = plan }
        raccoonPlanRuns = runs
    }

    func refreshRaccoonMoments() async {
        await refreshRaccoonPlan()
        raccoon.update()
        evaluateRaccoonMoments()
    }

    /// Time-based moments (ten minutes left, a break or block coming up)
    /// have no event of their own, so they are looked for every 15 seconds
    /// while a session or an approved plan is under way.
    func followRaccoonMoments() {
        Task { [weak self] in
            while let self {
                try? await Task.sleep(for: .seconds(15), tolerance: .seconds(5))
                guard displayPreferences.raccoonMode != .off,
                      snapshot.activeSession != nil || raccoonPlan?.state == .approved || raccoon.moment != nil
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
        case .backToTask:
            raccoon.endPeek(reevaluating: false)
            Task { await endBreak() }
        }
    }
}
