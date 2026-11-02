import FocusPilotCore
import SwiftUI

/// Pause or Resume, and Complete, for the active session. Shared by the menu
/// bar popover, the focus panel and the Now card, so they behave the same.
///
/// Completing a strict session before its planned end first asks for
/// confirmation, then waits `StrictEarlyEnd.wait` with a countdown; the
/// session keeps running until the owner completes. The coordinator decides
/// when confirmation is needed, so the Task menu asks too.
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
                        Button { Task { await model.complete() } } label: {
                            Label("Complete", systemImage: "checkmark.circle").frame(maxWidth: .infinity)
                        }
                        .accentProminentButton()
                    }
                    .controlSize(.large)
                }
            }
        }
    }

    @ViewBuilder
    private func pauseButton(_ session: FocusSession) -> some View {
        if case .paused = session.phase {
            Button { Task { await model.resume() } } label: {
                Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
        } else {
            Button { Task { await model.pause() } } label: {
                Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
            }
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
