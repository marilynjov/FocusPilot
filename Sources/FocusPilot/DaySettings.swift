import FocusPilotCore
import SwiftUI

/// Settings › Day: working hours and the blocks fixed every day, such as
/// lunch. Each change is saved once it passes the plan's rules; a new day's
/// plan starts from what is saved here.
struct DaySettings: View {
    let model: AppModel
    @State private var draft = DayPreferences.standard
    @State private var isLoaded = false

    var body: some View {
        Form {
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
                VStack(alignment: .leading, spacing: 6) {
                    SettingsError(message: model.dayPreferencesError)
                    Text("New days start with these hours and blocks. Today’s plan keeps the ones it started with.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await model.loadDayPreferences()
            draft = model.dayPreferences
            isLoaded = true
        }
        .onChange(of: draft) {
            guard isLoaded, draft != model.dayPreferences else { return }
            let preferences = draft
            Task { await model.saveDayPreferences(preferences) }
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
