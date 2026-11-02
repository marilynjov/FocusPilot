import FocusPilotCore
import SwiftUI

/// Settings › Day: working hours and the blocks fixed every day, such as
/// lunch. Each change is saved once it passes the plan's rules; a new day's
/// plan starts from what is saved here, and today's takes the new hours.
struct DaySettings: View {
    let model: AppModel
    @State private var draft = DayPreferences.standard
    @State private var isLoaded = false
    /// The latest save; each one waits for the one before.
    @State private var saving: Task<Void, Never>?
    /// What the latest queued save writes; nil before the first.
    @State private var queued: DayPreferences?

    var body: some View {
        Form {
            if let error = model.dayPreferencesError {
                Section { SettingsError(message: error) }
            }
            Section("Working hours") {
                DatePicker("Start", selection: time($draft.workingHours.start), displayedComponents: .hourAndMinute)
                DatePicker("End", selection: time($draft.workingHours.end), displayedComponents: .hourAndMinute)
            }
            Section {
                ForEach(draft.fixedBlocks.indices, id: \.self) { index in
                    HStack(spacing: 12) {
                        Picker("Kind", selection: fixedBlock(index).kind) {
                            ForEach(DayPreferences.FixedBlock.kinds, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        DatePicker("From", selection: time(fixedBlock(index).start), displayedComponents: .hourAndMinute)
                        DatePicker("To", selection: time(fixedBlock(index).end), displayedComponents: .hourAndMinute)
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { draft.fixedBlocks.remove(at: index) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Remove this fixed block")
                    }
                }
                Button("Add Fixed Block", systemImage: "plus") { draft.fixedBlocks.append(newFixedBlock) }
                    .buttonStyle(.borderless)
            } header: {
                Text("Fixed every day")
            } footer: {
                Text("New days start with these hours and blocks. Today’s plan takes new working hours too, unless one of its blocks would fall outside them; it keeps its fixed blocks. To skip or move lunch just for today, change it on Today’s plan.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            await model.loadDayPreferences()
            draft = model.dayPreferences
            isLoaded = true
        }
        .onChange(of: draft) { save(draft) }
    }

    /// Saves a valid draft after any save still running, so saves land in
    /// the order they were made and the last one wins. An invalid draft is
    /// kept on screen, not saved, with the reason above the list.
    private func save(_ preferences: DayPreferences) {
        guard isLoaded else { return }
        if let problem = preferences.problem {
            model.dayPreferencesError = "Not saved: \(DayPlanText.message(problem))"
            return
        }
        model.dayPreferencesError = nil
        // Compared with the last save queued, not the last one finished: going
        // A → B → A while B is still saving must queue A again, or B would win.
        guard preferences != (queued ?? model.dayPreferences) else { return }
        queued = preferences
        let previous = saving
        saving = Task {
            await previous?.value
            await model.saveDayPreferences(preferences)
        }
    }

    /// A 15-minute break an hour after work starts.
    private var newFixedBlock: DayPreferences.FixedBlock {
        let start = min(draft.workingHours.start.minutes + 60, 23 * 60)
        return .init(kind: .break, start: ClockTime(minutes: start), end: ClockTime(minutes: start + 15))
    }

    /// A row's block, safe to read while a removal redraws the list.
    private func fixedBlock(_ index: Int) -> Binding<DayPreferences.FixedBlock> {
        Binding(
            get: { draft.fixedBlocks.indices.contains(index) ? draft.fixedBlocks[index] : newFixedBlock },
            set: { if draft.fixedBlocks.indices.contains(index) { draft.fixedBlocks[index] = $0 } }
        )
    }

    /// A Date binding for a ClockTime on today's date in this Mac's zone.
    private func time(_ value: Binding<ClockTime>) -> Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: value.wrappedValue.hour, minute: value.wrappedValue.minute,
                                      second: 0, of: .now) ?? .now
            },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                value.wrappedValue = ClockTime(parts.hour ?? 0, parts.minute ?? 0)
            }
        )
    }
}
