import AppKit
import FocusPilotCore
import SwiftUI

/// Today's plan (D1): the day's blocks on a timeline across working hours.
/// The owner adds blocks, drags them to move, drags their bottom edge to
/// resize, edits or deletes them from the context menu, and approves the
/// plan. Fixed blocks such as lunch come from Settings › Day; moving or
/// skipping one here changes today only. Times snap to 15 minutes and read
/// in the Mac's 12- or 24-hour clock.
struct DayPlanView: View {
    let model: AppModel
    @State private var editing: BlockEditorSheet.Draft?
    /// A dragged block waiting for the owner to confirm its overlap.
    @State private var confirming: PendingOverlap?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let plan = model.dayPlan {
                ScrollView {
                    DayTimeline(plan: plan, held: confirming?.block, edit: { editing = .init($0) },
                                save: { await save($0) }, delete: { id in Task { await model.deleteBlock(id) } })
                        .padding(20)
                }
            } else {
                Spacer()
            }
        }
        .task { await model.loadDayPlan() }
        // The date may have changed under the page: at midnight, after the
        // clock or time zone changes, or after a sleep across midnight.
        .task { await reload(after: .NSCalendarDayChanged) }
        .task { await reload(after: .NSSystemClockDidChange) }
        .task { await reload(after: .NSSystemTimeZoneDidChange) }
        .task { await reload(after: NSApplication.didBecomeActiveNotification) }
        .sheet(item: $editing) { draft in
            BlockEditorSheet(model: model, draft: draft)
        }
        .confirmationDialog(
            confirming.map { DayPlanText.confirmation($0.overlapping, in: model.dayPlan) } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
        ) {
            Button("Place It Anyway") {
                guard let pending = confirming else { return }
                Task {
                    _ = await model.updateBlock(pending.block, confirmed: true)
                    confirming = nil
                }
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        }
    }

    /// Saves a dragged block; an overlap waits for confirmation, and the
    /// block stays where it was dropped meanwhile.
    private func save(_ block: DayBlock) async {
        if case .needsConfirmation(let overlapping) = await model.updateBlock(block) {
            confirming = PendingOverlap(block: block, overlapping: overlapping)
        }
    }

    private func reload(after name: Notification.Name) async {
        for await _ in NotificationCenter.default.notifications(named: name) {
            await model.reloadDayPlanIfDayChanged()
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

/// A block edit held until the owner confirms its overlap.
struct PendingOverlap {
    var block: DayBlock
    var overlapping: [DayBlock]
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
    /// A block shown where it was dropped while its overlap is confirmed.
    let held: DayBlock?
    let edit: (DayBlock) -> Void
    let save: (DayBlock) async -> Void
    let delete: (Int64) -> Void

    static let pointsPerMinute: CGFloat = 1.2
    static let snapMinutes = 15
    private let labelWidth: CGFloat = 64

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
                    Text(DayPlanText.time(minutesAfterMidnight: minutes))
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
                TimelineBlock(plan: plan, block: block, held: held?.id == block.id ? held : nil,
                              top: y(block.start.minutes), edit: edit, save: save, delete: delete)
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
    let held: DayBlock?
    let top: CGFloat
    let edit: (DayBlock) -> Void
    let save: (DayBlock) async -> Void
    let delete: (Int64) -> Void

    /// Snapped minutes of the drag in progress.
    @State private var moveBy = 0
    @State private var resizeBy = 0
    /// Where the block was dropped, shown until the save answers, so it
    /// does not jump back and forth.
    @State private var saving: DayBlock?

    private static func snapped(_ translation: CGFloat) -> Int {
        let step = DayTimeline.snapMinutes
        return Int((translation / DayTimeline.pointsPerMinute / CGFloat(step)).rounded()) * step
    }

    private var shown: DayBlock {
        saving ?? held ?? dragged(moveBy: moveBy, resizeBy: resizeBy)
    }

    /// The block as it would be after the drag so far, kept within working
    /// hours and at least one snap long.
    private func dragged(moveBy: Int, resizeBy: Int) -> DayBlock {
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
            .gesture(moveGesture)
            .onTapGesture(count: 2) { edit(block) }
            .contextMenu { menu }
            .help(block.isFixed
                  ? "Fixed every day in Settings › Day. Moving or skipping it here changes today only."
                  : "Drag to move, drag the bottom edge to resize, double-click to edit.")
            .offset(y: CGFloat(shown.start.minutes - block.start.minutes) * DayTimeline.pointsPerMinute + top)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(DayPlanText.name(block, in: plan))
            .accessibilityAction(named: "Edit") { edit(block) }
    }

    private func label(_ shown: DayBlock) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if block.isFixed {
                Image(systemName: "pin.fill").imageScale(.small)
                    .help("Fixed every day")
            }
            Text(plan.title(of: block)).fontWeight(.medium).lineLimit(1)
            Spacer(minLength: 4)
            Text(DayPlanText.times(shown.span)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    private var resizeHandle: some View {
        Rectangle().fill(.clear).frame(height: 8).contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .bottom))
            .gesture(resizeGesture)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { moveBy = Self.snapped($0.translation.height) }
            .onEnded { commit(dragged(moveBy: Self.snapped($0.translation.height), resizeBy: 0)) }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { resizeBy = Self.snapped($0.translation.height) }
            .onEnded { commit(dragged(moveBy: 0, resizeBy: Self.snapped($0.translation.height))) }
    }

    @ViewBuilder private var menu: some View {
        Button(block.isFixed ? "Change for Today…" : "Edit…") { edit(block) }
        Button(block.isFixed ? "Skip Today" : "Delete", role: .destructive) {
            if let id = block.id { delete(id) }
        }
    }

    /// Saves where the drag ended, showing the block there until the save
    /// answers. A refused edit puts it back where it is stored.
    private func commit(_ moved: DayBlock) {
        moveBy = 0
        resizeBy = 0
        guard moved != block else { return }
        saving = moved
        Task {
            await save(moved)
            saving = nil
        }
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
