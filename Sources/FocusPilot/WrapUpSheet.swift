import FocusPilotCore
import SwiftUI

/// The session wrap-up sheet (design 06), shown when a session ends: what
/// got done, what remains, and what to start with next time, which becomes
/// the task's next action and the return cue shown first on resuming.
///
/// The text and the "Mark task complete" box live in `AppModel.wrapUp`, not
/// here, so they survive the sheet being dismissed and shown again. It must
/// take seconds: the fields start from what the task already says, Return moves to the next field and saves from the last, ⌘⏎ saves from
/// anywhere, and Esc skips without writing anything. Fields are vertical
/// text fields rather than text editors so Tab and Return move between them.
struct WrapUpSheet: View {
    let model: AppModel
    let prompt: WrapUpPrompt
    @State private var isSaving = false
    @State private var error: String?
    @FocusState private var focused: Field?

    private enum Field: Hashable {
        case outcome, remainingWork, returnCue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(prompt.title)
                    .font(.headline)
                Text(prompt.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                row("What got done", text: draft(\.outcome), field: .outcome, next: .remainingWork)
                row("What remains", text: draft(\.remainingWork), field: .remainingWork, next: .returnCue)
                row("Next time, start with", text: draft(\.returnCue), field: .returnCue, next: nil,
                    note: "Becomes the task's next action and is shown first when you resume.")
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Divider()
            HStack(spacing: 8) {
                Toggle("Mark task complete", isOn: draft(\.marksTaskDone))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Skip") { model.skipWrapUp() }
                    .keyboardShortcut(.cancelAction)
                    .help("Close without saving (Esc)")
                Button("Save", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accentProminentButton()
                    .disabled(isSaving)
                    .help("Save (⌘⏎)")
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { focused = .outcome }
    }

    /// A value of the model's draft for this prompt.
    private func draft<Value>(_ field: WritableKeyPath<WrapUpDraft, Value>) -> Binding<Value> {
        Binding(get: { (model.wrapUp?.draft ?? WrapUpDraft())[keyPath: field] },
                set: { if model.wrapUp?.id == prompt.id { model.wrapUp?.draft[keyPath: field] = $0 } })
    }

    private func row(_ title: String, text: Binding<String>, field: Field, next: Field?, note: String? = nil) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                TextField(title, text: text, axis: .vertical)
                    .labelsHidden()
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: field)
                    .onSubmit { if let next { focused = next } else { save() } }
                if let note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            error = await model.saveWrapUp()
            isSaving = false
        }
    }
}
