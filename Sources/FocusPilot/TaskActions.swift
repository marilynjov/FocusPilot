import FocusPilotCore
import SwiftUI

/// What the Task menu can do in the focused planning list.
struct TaskActions {
    enum Move {
        case now, next, later, up, down
    }

    /// The move the selected task allows, or nil if there is no selection
    /// or the move would change nothing.
    let placement: (Move) -> (id: Int64, status: TaskStatus, placement: TaskPlacement)?
    let perform: (Move) -> Void
}

extension FocusedValues {
    @Entry var taskActions: TaskActions?
    /// Opens the capture sheet. Published by the planning window itself, so
    /// ⌘N works even when no task list is shown (first launch, Projects
    /// with no projects).
    @Entry var quickCapture: (() -> Void)?
}

/// The Task menu (design 09). Open Context and Locate arrive with #18.
struct TaskCommands: Commands {
    let model: AppModel
    @FocusedValue(\.taskActions) private var actions
    @FocusedValue(\.quickCapture) private var quickCapture
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Task") {
            sessionItems
            Divider()
            Button("New Task…") { quickCapture?() }
                .keyboardShortcut("n")
                .disabled(quickCapture == nil)
            Divider()
            item("Make Current (Now)", .now, KeyboardShortcut("1"))
            item("Move to Next", .next, KeyboardShortcut("2"))
            item("Move to Later", .later, KeyboardShortcut("3"))
            item("Move Up", .up, KeyboardShortcut(.upArrow, modifiers: [.command, .option]))
            item("Move Down", .down, KeyboardShortcut(.downArrow, modifiers: [.command, .option]))
        }
    }

    /// Start Focus ⌘⏎, Pause ⌥⌘P (Resume while paused), Complete ⇧⌘⏎.
    /// Complete on a strict session ending early asks for confirmation like
    /// every other Complete; it shows in the planning window's Now card (and
    /// the popover and panel), so that window is brought forward.
    @ViewBuilder private var sessionItems: some View {
        let session = model.snapshot.activeSession
        Button("Start Focus…") {
            model.requestStartFocus()
            openWindow(id: PlanningView.windowID)
        }
        .keyboardShortcut(.return)
        .disabled(session != nil || model.nowTask == nil)
        if case .paused = session?.phase {
            Button("Resume") { Task { await model.resume() } }
                .keyboardShortcut("p", modifiers: [.command, .option])
        } else {
            Button("Pause") { Task { await model.pause() } }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(session?.phase != .running)
        }
        Button("Complete") {
            Task {
                if await model.complete() { openWindow(id: PlanningView.windowID) }
            }
        }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(session == nil)
    }

    private func item(_ title: String, _ move: TaskActions.Move, _ shortcut: KeyboardShortcut) -> some View {
        Button(title) { actions?.perform(move) }
            .keyboardShortcut(shortcut)
            .disabled(actions?.placement(move) == nil)
    }
}
