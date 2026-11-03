import FocusPilotCore
import SwiftUI

/// The one way to add to Today's plan (#29): a new task, typed and read
/// like quick capture ("Write NLP report by Friday 5pm"), an open task from
/// the list, or a break, from one time to another. A new task and its block
/// are saved together, and the task joins the task list too. The plan's
/// rules are checked on save; an overlap with a fixed block asks first.
struct AddToPlanSheet: View {
    enum Choice: Hashable, CaseIterable {
        case newTask, existingTask, breakTime

        var title: String {
            switch self {
            case .newTask: "New Task"
            case .existingTask: "Existing Task"
            case .breakTime: "Break"
            }
        }
    }

    struct Draft: Identifiable {
        let id = UUID()
        /// The day of the plan the sheet was opened on; the save goes there
        /// even if the page moves on to a new day meanwhile.
        var date: LocalDate
        var start: ClockTime
        var minutes: Int
        /// A task to start with, chosen from the plan page's task list.
        var taskID: Int64?
        /// Whether a new task also goes on today's plan; off, it only joins
        /// the task list. On by default on Today's plan.
        var schedules = true

        /// The first free hour (see `BlockEditorSheet.Draft(newIn:)`).
        init(in plan: DayPlan, taskID: Int64? = nil, schedules: Bool = true) {
            let slot = BlockEditorSheet.Draft(newIn: plan).block
            date = plan.date
            start = slot.start
            minutes = max(slot.span.minutes, TimelinePlacement.snapMinutes)
            self.taskID = taskID
            self.schedules = schedules
        }

        /// Before today's plan has loaded: an hour from the next quarter hour.
        init(on date: LocalDate, schedules: Bool) {
            let now = Calendar.current.dateComponents([.hour, .minute], from: .now)
            let next = min(((now.hour ?? 9) * 60 + (now.minute ?? 0) + 14) / 15 * 15, 23 * 60)
            self.date = date
            start = ClockTime(minutes: next)
            minutes = 60
            self.schedules = schedules
        }
    }


    let model: AppModel
    private let date: LocalDate
    @State private var choice: Choice
    @State private var text = ""
    /// Split and parsed once per text change, as in quick capture; Add saves exactly this.
    @State private var capture = CaptureDraft()
    @State private var taskID: Int64?
    @State private var start: ClockTime
    @State private var minutes: Int
    @State private var schedules: Bool
    @State private var isSaving = false
    /// Blocks the new block would overlap, while the owner is asked to confirm.
    @State private var overlapping: [DayBlock]?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    init(model: AppModel, draft: Draft) {
        self.model = model
        date = draft.date
        _choice = State(initialValue: draft.taskID == nil ? .newTask : .existingTask)
        _taskID = State(initialValue: draft.taskID)
        _start = State(initialValue: draft.start)
        _minutes = State(initialValue: draft.minutes)
        _schedules = State(initialValue: draft.schedules)
    }

    /// Existing tasks and breaks are always placed on the plan.
    private var isScheduling: Bool { choice != .newTask || schedules }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isScheduling ? "Add to Today’s Plan" : "New Task")
                .font(.title3.weight(.semibold))
            Picker("Add", selection: $choice) {
                ForEach(Choice.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Form {
                switch choice {
                case .newTask: newTaskFields
                case .existingTask: existingTaskField
                case .breakTime: EmptyView()
                }
                if choice == .newTask {
                    Toggle("Add to today’s plan", isOn: $schedules)
                }
                if isScheduling { Section {
                    // From and To, with the length worked out (owner request,
                    // 2026-11-02). Changing From keeps the length.
                    DatePicker("From", selection: startDate, displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: endDate, displayedComponents: .hourAndMinute)
                    LabeledContent("Length", value: Self.lengthText(block.span.minutes))
                } }
            }
            .formStyle(.grouped)
            SettingsError(message: model.dayPlanError)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { Task { await save(confirmed: false) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd || isSaving)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { model.dayPlanError = nil }
        .onChange(of: text) {
            capture.setText(text, now: .now, timeZone: .current, isKnownWord: SpellingDictionary.isKnown)
        }
        .confirmationDialog(
            overlapping.map { DayPlanText.confirmation($0, in: model.dayPlan) } ?? "",
            isPresented: Binding(get: { overlapping != nil }, set: { if !$0 { overlapping = nil } })
        ) {
            Button("Place It Anyway") { Task { await save(confirmed: true) } }
            Button("Cancel", role: .cancel) { overlapping = nil }
        }
    }

    @ViewBuilder private var newTaskFields: some View {
        Section {
            TextField("Task", text: $text, prompt: Text("Write NLP report by Friday 5pm"))
            if let hint = capture.unrecognizedDateHint {
                Label(hint, systemImage: "questionmark.circle")
                    .foregroundStyle(palette.color(.muted))
            }
            TextField("Title", text: $capture.title, prompt: Text(""))
            LabeledContent("Deadline") {
                VStack(alignment: .trailing, spacing: 4) {
                    DeadlinePreview(deadlineText: capture.deadlineText, deadline: capture.deadline)
                    if capture.deadline != nil || capture.deadlineText != nil {
                        Button("Remove deadline") { capture.removeDeadline() }
                            .buttonStyle(.link)
                    }
                }
            }
            ProjectPicker(projectTitles: model.projectTitles, projectName: $capture.projectName)
            TextField("Next action", text: Binding(get: { capture.nextAction ?? "" },
                                                   set: { capture.nextAction = $0.isEmpty ? nil : $0 }),
                      prompt: Text("Optional"))
        } footer: {
            Text(schedules ? "The task is also added to your task list." : "The task joins your task list without a time.")
                .font(.callout)
                .foregroundStyle(palette.color(.muted))
        }
    }

    @ViewBuilder private var existingTaskField: some View {
        if taskChoices.isEmpty {
            Text("No open tasks yet. Choose New Task to add one.")
                .foregroundStyle(palette.color(.muted))
        } else {
            Picker("Task", selection: $taskID) {
                Text("Choose a task").tag(Int64?.none)
                ForEach(taskChoices, id: \.id) { Text($0.title).tag(Optional($0.id)) }
            }
        }
    }

    /// Open tasks, plus the chosen one if it closed meanwhile.
    private var taskChoices: [(id: Int64, title: String)] {
        var choices = model.today.map { (id: $0.id, title: $0.title) }
        if let id = taskID, !choices.contains(where: { $0.id == id }) {
            choices.append((id: id, title: model.dayPlan?.taskTitles[id] ?? "Task"))
        }
        return choices
    }

    /// "45 min", "1 hr", "1 hr 30 min".
    static func lengthText(_ minutes: Int) -> String {
        let (hours, rest) = (minutes / 60, minutes % 60)
        switch (hours, rest) {
        case (0, _): return "\(rest) min"
        case (_, 0): return "\(hours) hr"
        default: return "\(hours) hr \(rest) min"
        }
    }

    private var canAdd: Bool {
        switch choice {
        case .newTask: capture.newTask != nil
        case .existingTask: taskID != nil
        case .breakTime: true
        }
    }

    /// The block to add. The end stays within the day; the plan's rules
    /// refuse one outside working hours with a reason.
    private var block: DayBlock {
        let end = ClockTime(minutes: min(start.minutes + minutes, 24 * 60 - 1))
        switch choice {
        case .newTask: return DayBlock(kind: .task, start: start, end: end)
        case .existingTask: return DayBlock(kind: .task, start: start, end: end, taskID: taskID)
        case .breakTime: return DayBlock(kind: .break, start: start, end: end)
        }
    }

    /// Stays open until the plan answers: closes once saved, asks first
    /// about an overlap, and shows why an addition was refused.
    private func save(confirmed: Bool) async {
        guard canAdd, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        let outcome: BlockEditOutcome
        if choice == .newTask, !schedules, let newTask = capture.newTask {
            if await model.capture(newTask) { dismiss() }
            return
        } else if choice == .newTask, let newTask = capture.newTask {
            outcome = await model.addBlock(block, forNew: newTask, on: date, confirmed: confirmed)
        } else {
            outcome = await model.addBlock(block, on: date, confirmed: confirmed)
        }
        overlapping = nil
        switch outcome {
        case .saved: dismiss()
        case .needsConfirmation(let blocks): overlapping = blocks
        case .failed: break
        }
    }

    /// The end as a Date for the picker. Setting it sets the length; an end
    /// at or before From leaves the block 5 minutes long.
    private var endDate: Binding<Date> {
        Binding(
            get: { Self.date(block.end) },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                minutes = max((parts.hour ?? 0) * 60 + (parts.minute ?? 0) - start.minutes, 5)
            }
        )
    }

    private static func date(_ time: ClockTime) -> Date {
        Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: .now) ?? .now
    }

    /// The start as a Date on today's date in this Mac's zone, for the picker.
    private var startDate: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: start.hour, minute: start.minute, second: 0, of: .now) ?? .now },
            set: {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: $0)
                start = ClockTime(parts.hour ?? 0, parts.minute ?? 0)
            }
        )
    }
}
