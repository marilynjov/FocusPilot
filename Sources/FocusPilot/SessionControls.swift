import FocusPilotCore
import SwiftUI

/// Take a Break (Back to Task on a break, Resume if paused), +10 min, and
/// Complete, for the active session, and Keep Going for a minute after one
/// reached its end. Shared by the menu bar popover, the focus panel and the Now card,
/// so they behave the same.
///
/// Completing a strict session before its planned end first asks for
/// confirmation, then waits `StrictEarlyEnd.wait` with a countdown; the
/// session keeps running until the owner completes. The coordinator decides
/// when confirmation is needed, so the Task menu asks too.
///
/// A session started by a plan block (D3) offers "Done early", which ends
/// the block and the session, and "I need more time", which is recorded
/// for replanning (D10) while the block keeps its end. "+10 min" on a
/// block's session records that too, and moves the session's end.
struct SessionControls: View {
    let model: AppModel
    /// Off where the return cue is already on screen, as in the Now card.
    var showsReturnCue = true

    var body: some View {
        if let session = model.snapshot.activeSession {
            if let availableAt = model.snapshot.earlyEndAvailableAt {
                waiting(until: availableAt)
            } else if model.isConfirmingEarlyEnd {
                confirming
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    // Resuming shows the return cue first (#20).
                    if showsReturnCue, case .paused = session.phase, let wrapUp = model.task(session.taskID)?.wrapUp {
                        ReturnCueView(wrapUp: wrapUp, isCompact: true)
                    }
                    HStack(spacing: 8) {
                        pauseButton(session)
                        Button { Task { await model.extend(minutes: RaccoonMoments.extraMinutes) } } label: {
                            Text("+\(RaccoonMoments.extraMinutes) min").frame(maxWidth: .infinity)
                        }
                        .help("Adds \(RaccoonMoments.extraMinutes) minutes to this session")
                        Button { Task { await model.complete() } } label: {
                            Label(planRun == nil ? "Complete" : "Done early", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .accentProminentButton()
                    }
                    .controlSize(.large)
                    if let planRun {
                        moreTime(planRun)
                    }
                }
            }
        } else if model.keepGoingOffer != nil {
            // Also on the raccoon's "Time's up", which is easy to miss.
            Button { Task { await model.keepGoing(minutes: RaccoonMoments.extraMinutes) } } label: {
                Label("Keep Going +\(RaccoonMoments.extraMinutes) min", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .help("Starts \(RaccoonMoments.extraMinutes) more minutes on the same task")
        }
    }

    private var planRun: PlanRun? {
        model.snapshot.activePlanRun
    }

    @ViewBuilder
    private func moreTime(_ run: PlanRun) -> some View {
        if run.moreTimeRequestedAt == nil {
            Button { Task { await model.requestMoreTime() } } label: { wide("I need more time") }
                .help("Notes that this block needs more time. The block still ends on time for now.")
        } else {
            Label("More time noted for when the plan is changed.", systemImage: "clock.badge.checkmark")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func pauseButton(_ session: FocusSession) -> some View {
        if case .onBreak = session.phase {
            Button { Task { await model.endBreak() } } label: {
                Label("Back to Task", systemImage: "arrow.uturn.backward").frame(maxWidth: .infinity)
            }
            .help("Ends the break")
        } else if case .paused = session.phase {
            Button { Task { await model.resume() } } label: {
                Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
        } else {
            // Take a Break replaces Pause (owner request, 2026-11-03): the
            // countdown stands still for the break. A session paused before
            // this still shows Resume above.
            Menu {
                ForEach(RaccoonMoments.breakChoices, id: \.self) { minutes in
                    Button("\(minutes) minutes") { Task { await model.takeBreak(minutes: minutes) } }
                }
            } label: {
                Label("Break", systemImage: "cup.and.saucer").frame(maxWidth: .infinity)
            }
            // A short title fits beside +10 min and Complete; the menu says
            // the rest.
            .menuIndicator(.hidden)
            .help("Take a break: stops the countdown")
            .accessibilityLabel("Take a Break")
            .disabled(session.phase != .running)
        }
    }

    private var confirming: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("End this strict session early?")
                .font(.headline)
            Text("Strict sessions wait \(StrictEarlyEnd.waitText) before ending. Rules stay on until then.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { model.isConfirmingEarlyEnd = false } label: { wide("Keep focusing") }
                Button { Task { await model.complete(confirmed: true) } } label: { wide("End early") }
            }
        }
    }

    private func waiting(until availableAt: Date) -> some View {
        let ready = model.now >= availableAt
        return VStack(alignment: .leading, spacing: 8) {
            Text(SessionText.earlyEnd(availableAt: availableAt, now: model.now))
                .font(.callout)
                .monospacedDigit()
            HStack(spacing: 8) {
                Button { Task { await model.cancelEarlyEnd() } } label: { wide("Keep focusing") }
                Button { Task { await model.complete() } } label: { wide("Complete") }
                    .accentProminentButton()
                    .disabled(!ready)
            }
        }
    }

    private func wide(_ title: String) -> some View {
        Text(title).frame(maxWidth: .infinity)
    }
}

/// "Focusing · Strict" and the time left, as the popover and panel show it.
struct SessionHeader: View {
    let session: FocusSession
    let now: Date
    var timeFont: Font = .title.weight(.medium)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette

    var body: some View {
        let text = SessionText(session)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle()
                .fill(session.phase == .running ? palette.color(.accent) : Color.secondary)
                .frame(width: 7, height: 7)
                .contrastOutline()
                .accessibilityHidden(true)
            Text(text.phase)
                .font(.callout.weight(.medium))
                .contrastEmphasis()
                .foregroundStyle(.secondary)
            if session.mode == .strict {
                Label("Strict", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(reduceMotion ? text.minutesLeft(at: now) : text.timeLeft(at: now))
                .font(timeFont)
                .monospacedDigit()
                .accessibilityLabel("\(text.minutesLeft(at: now))")
        }
    }
}
