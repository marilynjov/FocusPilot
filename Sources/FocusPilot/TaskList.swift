import FocusPilotCore
import SwiftUI

/// Now, Next and Later in the owner's manual order. Used by Today and,
/// filtered to one project, by Projects. Rows are reordered by dragging
/// within a section, or with the Task menu and context menu.
struct TaskList: View {
    let items: [TodayItem]
    let showsProject: Bool
    var nowCaption: String? = nil
    /// Today shows an empty Now card; a project whose tasks do not include
    /// the one Now leaves it out rather than claim there is none.
    var showsEmptyNow = true
    var nextCaption = "Manual order · drag to reorder"
    let move: (Int64, TaskStatus, TaskPlacement) -> Void
    /// Removes a task added from Herdr; nil hides Undo.
    var undoHerdrAdd: ((Int64) -> Void)?
    /// Undo is not offered for the task a session is running on.
    var activeSessionTaskID: Int64?
    @Binding var selection: Int64?
    @Environment(AppModel.self) private var model: AppModel?

    var body: some View {
        let sections = TaskSections(items)
        // Relative labels ("Due today 17:00", "Overdue …") change with time.
        TimelineView(.everyMinute) { context in
            List(selection: $selection) {
                if sections.now != nil || showsEmptyNow {
                    Section {
                        NowCard(item: sections.now, caption: nowCaption, showsProject: showsProject, now: context.date)
                            // The list measures a row once; a new identity when
                            // the card's session controls change makes it
                            // measure again instead of cutting the card off.
                            .id(model.map { NowCard.layoutKey($0, item: sections.now) })
                            .transaction { $0.animation = nil }
                            .tag(sections.now?.id)
                            .listRowSeparator(.hidden)
                    }
                }
                section(.next, "Next", caption: nextCaption, sections, context.date)
                section(.later, "Later", caption: nil, sections, context.date)
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: Int64.self) { ids in
                if let id = ids.first {
                    Button("Make Current (Now)") { perform(.now, on: id) }
                    Button("Move to Next") { perform(.next, on: id) }
                    Button("Move to Later") { perform(.later, on: id) }
                    if let undoHerdrAdd,
                       items.first(where: { $0.id == id })?.offersHerdrUndo(activeSessionTaskID: activeSessionTaskID) == true {
                        Divider()
                        Button("Undo Add from Herdr") { undoHerdrAdd(id) }
                    }
                }
            }
        }
        .focusedSceneValue(\.taskActions, TaskActions(
            placement: { action in selection.flatMap { placement(for: action, of: $0) } },
            perform: { move in selection.map { perform(move, on: $0) } }
        ))
    }

    @ViewBuilder
    private func section(_ status: TaskStatus, _ title: String, caption: String?, _ sections: TaskSections,
                         _ now: Date) -> some View {
        let members = sections.items(in: status)
        if !members.isEmpty {
            Section {
                ForEach(members) { item in
                    TaskRow(item: item, showsProject: showsProject, now: now,
                            undo: item.offersHerdrUndo(activeSessionTaskID: activeSessionTaskID)
                                ? undoHerdrAdd.map { undo in { undo(item.id) } } : nil)
                }
                .onMove { offsets, destination in
                    guard let source = offsets.first else { return }
                    let ids = members.map(\.id)
                    if let placement = TaskPlacement.drop(ids[source], at: destination, in: ids) {
                        move(ids[source], status, placement)
                    }
                }
            } header: {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                    if let caption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private func perform(_ action: TaskActions.Move, on id: Int64) {
        if let target = placement(for: action, of: id) {
            move(target.id, target.status, target.placement)
        }
    }

    /// Moving into a section puts the task at its top, where it is seen, and
    /// is unavailable when the task is already there. Move Up and Down stay
    /// within the section, among the visible rows.
    private func placement(for action: TaskActions.Move, of id: Int64)
        -> (id: Int64, status: TaskStatus, placement: TaskPlacement)? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        let sections = TaskSections(items)
        let visible = sections.items(in: item.status).map(\.id)
        func toTop(_ status: TaskStatus) -> (id: Int64, status: TaskStatus, placement: TaskPlacement)? {
            TaskPlacement.toTop(of: status, moving: id, from: item.status, visible: visible).map { (id, status, $0) }
        }
        switch action {
        case .now: return toTop(.now)
        case .next: return toTop(.next)
        case .later: return toTop(.later)
        case .up: return TaskPlacement.up(id, in: visible).map { (id, item.status, $0) }
        case .down: return TaskPlacement.down(id, in: visible).map { (id, item.status, $0) }
        }
    }
}
