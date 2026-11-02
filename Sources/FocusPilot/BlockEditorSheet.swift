import FocusPilotCore
import SwiftUI

/// Adds a block to today's plan or edits one: its kind, its task for a task
/// block, and its start and end. The plan's rules are checked on save; a
/// block that lands on lunch asks for confirmation on the timeline.
struct BlockEditorSheet: View {
    struct Draft: Identifiable {
        let id = UUID()
        var block: DayBlock

        init(_ block: DayBlock) {
            self.block = block
        }

        /// A new hour-long task block in the first free half-hour slot, or
        /// at the start of working hours if the day is full.
        init(newIn plan: DayPlan) {
            let hours = plan.workingHours
            let slots = stride(from: hours.start.minutes, through: hours.end.minutes - 60, by: 30).lazy.map {
                DayBlock(kind: .task, start: ClockTime(minutes: $0), end: ClockTime(minutes: $0 + 60))
            }
            let free = slots.first { DayPlanRules.check($0, among: plan.blocks, workingHours: hours) == .fits }
            self.init(free ?? DayBlock(kind: .task, start: hours.start,
                                       end: ClockTime(minutes: min(hours.start.minutes + 60, hours.end.minutes))))
        }
    }

    let model: AppModel
    @State private var block: DayBlock
    private let isNew: Bool
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, draft: Draft) {
        self.model = model
        _block = State(initialValue: draft.block)
        isNew = draft.block.id == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Add Block" : "Edit Block")
                .font(.title3.weight(.semibold))
            Form {
                Picker("Kind", selection: $block.kind) {
                    ForEach(DayBlock.Kind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if block.kind == .task {
                    Picker("Task", selection: $block.taskID) {
                        Text("None").tag(Int64?.none)
                        ForEach(taskChoices, id: \.id) { Text($0.title).tag(Optional($0.id)) }
                    }
                }
                DatePicker("Start", selection: time(\.start), displayedComponents: .hourAndMinute)
                DatePicker("End", selection: time(\.end), displayedComponents: .hourAndMinute)
            }
            .formStyle(.grouped)
            HStack {
                if !isNew, let id = block.id {
                    Button("Delete", role: .destructive) {
                        Task { await model.deleteBlock(id) }
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    let block = block
                    Task { await isNew ? model.addBlock(block) : model.updateBlock(block) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// Open tasks, plus the block's own task if it is no longer open.
    private var taskChoices: [(id: Int64, title: String)] {
        var choices = model.today.map { (id: $0.id, title: $0.title) }
        if let id = block.taskID, !choices.contains(where: { $0.id == id }) {
            choices.append((id: id, title: model.dayPlan?.taskTitles[id] ?? "Task"))
        }
        return choices
    }

    /// A Date binding for a ClockTime on today's date in this Mac's zone.
    private func time(_ keyPath: WritableKeyPath<DayBlock, ClockTime>) -> Binding<Date> {
        Binding(
            get: {
                let value = block[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: value.hour, minute: value.minute, second: 0, of: .now) ?? .now
            },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                block[keyPath: keyPath] = ClockTime(parts.hour ?? 0, parts.minute ?? 0)
            }
        )
    }
}
