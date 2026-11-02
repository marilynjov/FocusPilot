import FocusPilotCore
import SwiftUI

/// Today's plan (D1): the day's blocks on a timeline across working hours.
/// The owner adds blocks, drags them to move, drags their bottom edge to
/// resize, edits or deletes them from the context menu, and approves the
/// plan. Fixed blocks such as lunch are shown locked; they change in
/// Settings › Day. Times snap to 15 minutes.
struct DayPlanView: View {
    let model: AppModel
    @State private var editing: BlockEditorSheet.Draft?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let plan = model.dayPlan {
                ScrollView {
                    DayTimeline(plan: plan, edit: { editing = .init($0) },
                                save: { block in Task { await model.updateBlock(block) } },
                                delete: { id in Task { await model.deleteBlock(id) } })
                        .padding(20)
                }
            } else {
                Spacer()
            }
        }
        .task { await model.loadDayPlan() }
        .sheet(item: $editing) { draft in
            BlockEditorSheet(model: model, draft: draft)
        }
        .confirmationDialog(
            model.blockEditToConfirm.map { DayPlanText.confirmation($0.overlapping) } ?? "",
            isPresented: Binding(get: { model.blockEditToConfirm != nil },
                                 set: { if !$0 { model.blockEditToConfirm = nil } })
        ) {
            Button("Place It Anyway") { Task { await model.confirmBlockEdit() } }
            Button("Cancel", role: .cancel) { model.blockEditToConfirm = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                if let plan = model.dayPlan {
                    PlanStateBadge(state: plan.state)
                    Text("Working hours \(DayPlanText.times(plan.workingHours))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Block", systemImage: "plus") {
                    if let plan = model.dayPlan { editing = .init(newIn: plan) }
                }
                .disabled(model.dayPlan == nil)
                Button("Approve Plan", systemImage: "checkmark") { Task { await model.approveDayPlan() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.dayPlan?.state != .draft)
                    .help("Approving marks this plan as the one you’ll follow today.")
            }
            if model.dayPlan?.state == .approved {
                Text("Approved. Changing a block makes the plan a draft again. Approved plans don’t start focus sessions yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            SettingsError(message: model.dayPlanError)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

struct PlanStateBadge: View {
    let state: DayPlan.State

    var body: some View {
        Label(state == .approved ? "Approved" : "Draft",
              systemImage: state == .approved ? "checkmark.seal.fill" : "pencil")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(state == .approved ? Color.green : Color.secondary)
            .background(.quaternary, in: Capsule())
    }
}

/// The hour grid and the blocks placed on it.
private struct DayTimeline: View {
    let plan: DayPlan
    let edit: (DayBlock) -> Void
    let save: (DayBlock) -> Void
    let delete: (Int64) -> Void

    static let pointsPerMinute: CGFloat = 1.2
    static let snapMinutes = 15
    private let labelWidth: CGFloat = 48

    /// Whole hours around the working hours.
    private var gridStart: Int { plan.workingHours.start.minutes / 60 * 60 }
    private var gridEnd: Int { (plan.workingHours.end.minutes + 59) / 60 * 60 }

    private func y(_ minutes: Int) -> CGFloat {
        CGFloat(minutes - gridStart) * Self.pointsPerMinute
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(stride(from: gridStart, through: gridEnd, by: 60)), id: \.self) { minutes in
                HStack(alignment: .center, spacing: 8) {
                    Text(ClockTime(minutes: min(minutes, 23 * 60 + 59)).description)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .trailing)
                    Rectangle().fill(.separator).frame(height: 1)
                }
                .frame(height: 12)
                .offset(y: y(minutes) - 6)
            }
            // Outside working hours is shaded.
            Rectangle().fill(.quaternary.opacity(0.5))
                .frame(height: y(plan.workingHours.start.minutes))
                .padding(.leading, labelWidth + 8)
            Rectangle().fill(.quaternary.opacity(0.5))
                .frame(height: max(0, y(gridEnd) - y(plan.workingHours.end.minutes)))
                .padding(.leading, labelWidth + 8)
                .offset(y: y(plan.workingHours.end.minutes))
            ForEach(plan.blocks) { block in
                TimelineBlock(plan: plan, block: block, top: y(block.start.minutes), edit: edit, save: save, delete: delete)
                    .padding(.leading, labelWidth + 12)
            }
        }
        .frame(height: y(gridEnd), alignment: .top)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// One block: drag to move, drag the bottom edge to resize. The change is
/// saved when the drag ends; the plan's rules decide whether it stands.
private struct TimelineBlock: View {
    let plan: DayPlan
    let block: DayBlock
    let top: CGFloat
    let edit: (DayBlock) -> Void
    let save: (DayBlock) -> Void
    let delete: (Int64) -> Void

    /// Snapped minutes of the drag in progress.
    @State private var moveBy = 0
    @State private var resizeBy = 0

    private static func snapped(_ translation: CGFloat) -> Int {
        let step = DayTimeline.snapMinutes
        return Int((translation / DayTimeline.pointsPerMinute / CGFloat(step)).rounded()) * step
    }

    /// The block as it would be after the drag so far, kept within working
    /// hours and at least one snap long.
    private var shown: DayBlock {
        shown(moveBy: moveBy, resizeBy: resizeBy)
    }

    private func shown(moveBy: Int, resizeBy: Int) -> DayBlock {
        var shown = block
        let hours = plan.workingHours
        let length = block.span.minutes
        let start = min(max(block.start.minutes + moveBy, hours.start.minutes), hours.end.minutes - length)
        shown.start = ClockTime(minutes: max(start, 0))
        let end = min(max(shown.start.minutes + length + resizeBy, shown.start.minutes + DayTimeline.snapMinutes),
                      hours.end.minutes)
        shown.end = ClockTime(minutes: end)
        return shown
    }

    var body: some View {
        let shown = shown
        let height = max(CGFloat(shown.span.minutes) * DayTimeline.pointsPerMinute, 18)
        label(shown)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background(color.opacity(block.isFixed ? 0.12 : 0.22), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3).padding(.vertical, 3)
            }
            .overlay(alignment: .bottom) { resizeHandle }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .gesture(moveGesture, isEnabled: !block.isFixed)
            .onTapGesture(count: 2) { if !block.isFixed { edit(block) } }
            .contextMenu { menu }
            .help(block.isFixed ? "Fixed every day. Change it in Settings › Day."
                  : "Drag to move, drag the bottom edge to resize, double-click to edit.")
            .offset(y: CGFloat(shown.start.minutes - block.start.minutes) * DayTimeline.pointsPerMinute + top)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(DayPlanText.name(block, in: plan))
            .accessibilityAction(named: "Edit") { if !block.isFixed { edit(block) } }
    }

    private func label(_ shown: DayBlock) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if block.isFixed {
                Image(systemName: "lock.fill").imageScale(.small)
            }
            Text(plan.title(of: block)).fontWeight(.medium).lineLimit(1)
            Spacer(minLength: 4)
            Text(DayPlanText.times(shown.span)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    @ViewBuilder private var resizeHandle: some View {
        if !block.isFixed {
            Rectangle().fill(.clear).frame(height: 8).contentShape(Rectangle())
                .pointerStyle(.frameResize(position: .bottom))
                .gesture(resizeGesture)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { moveBy = Self.snapped($0.translation.height) }
            .onEnded { commit(shown(moveBy: Self.snapped($0.translation.height), resizeBy: 0)) }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { resizeBy = Self.snapped($0.translation.height) }
            .onEnded { commit(shown(moveBy: 0, resizeBy: Self.snapped($0.translation.height))) }
    }

    @ViewBuilder private var menu: some View {
        if block.isFixed {
            Text("Fixed blocks are changed in Settings › Day.")
        } else {
            Button("Edit…") { edit(block) }
            Button("Delete", role: .destructive) { if let id = block.id { delete(id) } }
        }
    }

    /// Saves where the drag ended. The block shows its stored place again
    /// until the saved plan arrives, or for good if the edit is refused.
    private func commit(_ moved: DayBlock) {
        moveBy = 0
        resizeBy = 0
        guard moved != block else { return }
        save(moved)
    }

    private var color: Color {
        switch block.kind {
        case .task: .accentColor
        case .break: .green
        case .lunch: .orange
        case .wrapUp: .purple
        }
    }
}
