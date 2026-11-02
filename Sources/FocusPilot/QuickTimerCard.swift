import FocusPilotCore
import SwiftUI

/// The Quick timer card on Today (D2): presets and a custom length with an
/// optional label, or the running timer with Finish and Stop. The card
/// itself shows "2 minutes left" and "Time’s up"; Notification Center gets
/// the same notices. A timer blocks nothing.
struct QuickTimerCard: View {
    let model: AppModel
    @State private var label = ""
    @State private var customMinutes = 15
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("Quick timer").foregroundStyle(palette.color(.muted))
            } icon: {
                Image(systemName: "timer").foregroundStyle(palette.color(.accent))
            }
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            if let timer = model.snapshot.quickTimer {
                running(timer)
            } else {
                idle
            }
            if let error = model.quickTimerError {
                Text(error).font(.callout).foregroundStyle(palette.color(.muted))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .foregroundStyle(palette.color(.ink))
        .background(palette.color(.surface), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.color(.line)))
        .accessibilityElement(children: .contain)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("What’s it for? (optional)", text: $label)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
                .onSubmit { start(customMinutes) }
            HStack(spacing: 8) {
                ForEach(QuickTimer.presetMinutes, id: \.self) { minutes in
                    Button("\(minutes) min") { start(minutes) }
                        .accessibilityLabel("Start a \(minutes)-minute timer")
                }
                Divider().frame(height: 18)
                Stepper(value: $customMinutes, in: QuickTimer.minutesRange) {
                    TextField("Minutes", value: $customMinutes, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 48)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel("Custom length in minutes")
                }
                Text("min").foregroundStyle(palette.color(.muted))
                Button("Start") { start(customMinutes) }
                    .accessibilityLabel("Start a \(customMinutes)-minute timer")
            }
            Text("A timer doesn’t block anything. Start focus for that.")
                .font(.callout)
                .foregroundStyle(palette.color(.muted))
        }
    }

    private func running(_ timer: QuickTimer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(QuickTimerText.title(timer)).font(.title3.weight(.semibold))
                Text(QuickTimerText.planned(timer)).font(.callout).foregroundStyle(palette.color(.muted))
            }
            QuickTimerStatus(timer: timer, now: model.now, timeFont: .title.weight(.medium))
            HStack(spacing: 8) {
                Button("Finish") { Task { await model.finishQuickTimer() } }
                    .accentProminentButton()
                    .help("It’s done. Records how long it took.")
                Button("Stop") { Task { await model.stopQuickTimer() } }
                    .help("Stop without finishing.")
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
    }

    private func start(_ minutes: Int) {
        let label = label
        Task {
            if await model.startQuickTimer(minutes: minutes, label: label) { self.label = "" }
        }
    }
}

/// The time left and a progress bar; "2 minutes left" and "Time’s up" stand
/// out, so the in-app notice does not depend on Notification Center.
struct QuickTimerStatus: View {
    let timer: QuickTimer
    let now: Date
    var timeFont: Font = .title3.weight(.medium)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.palette) private var palette

    var body: some View {
        let remaining = timer.remaining(at: now)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(reduceMotion ? QuickTimerText.minutesStatus(timer, at: now) : QuickTimerText.status(timer, at: now))
                    .font(timeFont)
                    .monospacedDigit()
                    .accessibilityLabel(QuickTimerText.minutesStatus(timer, at: now))
                if remaining > 0, remaining <= QuickTimer.warning {
                    badge("Almost up")
                }
            }
            ProgressView(value: min(1, max(0, 1 - remaining / timer.plannedLength)))
                .tint(palette.color(.accent))
                .accessibilityHidden(true)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(palette.color(.onAccent))
            .background(palette.color(.accent), in: Capsule())
    }
}
