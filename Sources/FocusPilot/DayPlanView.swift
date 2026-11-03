import AppKit
import FocusPilotCore
import SwiftUI

/// Today's plan (D1): the day's blocks on a timeline across working hours,
/// with the open tasks beside it. The owner adds a new or existing task or a
/// break with Add to Plan, or drags a task onto the timeline (#29); drags
/// blocks to move them and their bottom edge to resize them; edits or
/// deletes them from the context menu; and approves the plan. Fixed blocks
/// such as lunch come from Settings › Day; moving or skipping one here
/// changes today only. Blocks follow the pointer and snap to 15 minutes on
/// release. Times read in the Mac's 12- or 24-hour clock.
struct DayPlanView: View {
    let model: AppModel
    @State private var editing: BlockEditorSheet.Draft?
    @State private var adding: AddToPlanSheet.Draft?
    /// A dragged or dropped block waiting for the owner to confirm its overlap.
    @State private var confirming: PendingOverlap?
    /// A task dropped on the timeline, shown where it landed until the save answers.
    @State private var placing: DayBlock?
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(palette.color(.line)).frame(height: 1)
            if let plan = model.dayPlan {
                HStack(spacing: 0) {
                    ScrollView {
                        // Each edit names the day it was made on (see AppModel+DayPlan).
                        DayTimeline(plan: plan, held: confirming?.block, placing: placingGhost,
                                    edit: { editing = .init($0, on: plan.date) },
                                    save: { await save($0, on: plan.date) },
                                    drop: { await drop($0, on: plan.date) },
                                    delete: { id in Task { await model.deleteBlock(id, on: plan.date) } })
                            .padding(20)
                    }
                    Rectangle().fill(palette.color(.line)).frame(width: 1)
                    PlanTaskPanel(tasks: model.today) { adding = .init(in: plan, taskID: $0) }
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
        .sheet(item: $adding) { draft in
            AddToPlanSheet(model: model, draft: draft)
        }
        .confirmationDialog(
            confirming.map { DayPlanText.confirmation($0.overlapping, in: model.dayPlan) } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })
        ) {
            Button("Place It Anyway") {
                guard let pending = confirming else { return }
                Task {
                    if pending.block.id == nil {
                        _ = await model.addBlock(pending.block, on: pending.date, confirmed: true)
                    } else {
                        _ = await model.updateBlock(pending.block, on: pending.date, confirmed: true)
                    }
                    confirming = nil
                }
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        }
    }

    /// A dropped task's block, with its title, while it is saved or waits
    /// for confirmation.
    private var placingGhost: (block: DayBlock, title: String)? {
        let pending = confirming.flatMap { $0.block.id == nil ? $0.block : nil }
        guard let block = placing ?? pending else { return nil }
        let title = block.taskID.flatMap { id in model.today.first { $0.id == id }?.title } ?? block.kind.title
        return (block, title)
    }

    /// Saves a dragged block; an overlap waits for confirmation, and the
    /// block stays where it was dropped meanwhile.
    private func save(_ block: DayBlock, on date: LocalDate) async {
        if case .needsConfirmation(let overlapping) = await model.updateBlock(block, on: date) {
            confirming = PendingOverlap(block: block, date: date, overlapping: overlapping)
        }
    }

    /// Adds a block for a task dropped on the timeline, with the same checks
    /// and confirmation as any other new block.
    private func drop(_ block: DayBlock, on date: LocalDate) async {
        placing = block
        defer { placing = nil }
        if case .needsConfirmation(let overlapping) = await model.addBlock(block, on: date) {
            confirming = PendingOverlap(block: block, date: date, overlapping: overlapping)
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
                        .foregroundStyle(palette.color(.muted))
                }
                Spacer()
                Button("Add to Plan", systemImage: "plus") {
                    if let plan = model.dayPlan { adding = .init(in: plan) }
                }
                .disabled(model.dayPlan == nil)
                .help("Add a new task, one from your list, or a break to today’s plan.")
                Button("Approve Plan", systemImage: "checkmark") {
                    if let date = model.dayPlan?.date { Task { await model.approveDayPlan(on: date) } }
                }
                    .accentProminentButton()
                    .disabled(model.dayPlan?.state != .draft)
                    .help("Approving marks this plan as the one you’ll follow today: task blocks start focus sessions on time.")
            }
            if model.dayPlan?.state == .approved {
                Text("Approved. Each task block starts a focus session with your session rules when its time comes and ends with the block. Blocks without a task start nothing. Changing a block makes the plan a draft again, and drafts start nothing.")
                    .font(.callout)
                    .foregroundStyle(palette.color(.muted))
            }
            SettingsError(message: model.dayPlanError ?? model.snapshot.planFailure)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

/// A block edit or a new block held until the owner confirms its overlap.
struct PendingOverlap {
    /// No ID for a task dropped on the timeline: confirming adds it.
    var block: DayBlock
    /// The day of the plan it was dragged on.
    var date: LocalDate
    var overlapping: [DayBlock]
}

struct PlanStateBadge: View {
    let state: DayPlan.State
    @Environment(\.palette) private var palette

    var body: some View {
        // The label in a text color; only the Approved seal takes the
        // Ready status color, held to 3:1 as a mark.
        Label {
            Text(state == .approved ? "Approved" : "Draft")
        } icon: {
            Image(systemName: state == .approved ? "checkmark.seal.fill" : "pencil")
                .foregroundStyle(palette.color(state == .approved ? .ready : .muted))
        }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(palette.color(state == .approved ? .ink : .muted))
            .background(palette.color(.surface), in: Capsule())
            .overlay(Capsule().stroke(palette.color(.line)))
    }
}

/// The open tasks beside the timeline. Each can be dragged onto it to plan
/// an hour at the drop time, or added with Add to Plan from its context menu
/// or accessibility action, which also works by keyboard and VoiceOver.
private struct PlanTaskPanel: View {
    let tasks: [TodayItem]
    let add: (Int64) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tasks")
                .font(.headline)
                .foregroundStyle(palette.color(.ink))
            Text(tasks.isEmpty ? "No open tasks. Use Add to Plan to create one."
                 : "Drag a task onto the timeline to plan an hour for it.")
                .font(.callout)
                .foregroundStyle(palette.color(.muted))
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(tasks) { row($0) }
                }
            }
        }
        .padding(16)
        .frame(width: 240)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ item: TodayItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(palette.color(.muted))
                .accessibilityHidden(true)
            Text(item.title)
                .lineLimit(2)
                .foregroundStyle(palette.color(.ink))
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(palette.color(.surface), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.color(.line)))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .draggable(PlanTaskDrag.payload(for: item.id)) {
            Text(item.title)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .foregroundStyle(palette.color(.ink))
                .background(palette.color(.surface), in: RoundedRectangle(cornerRadius: 6))
        }
        .onTapGesture(count: 2) { add(item.id) }
        .contextMenu { Button("Add to Plan…") { add(item.id) } }
        .help("Drag onto the timeline, or double-click to choose a time.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(.isButton)
        // VO-Space on the button opens the sheet, like a double-click.
        .accessibilityAction { add(item.id) }
        .accessibilityAction(named: "Add to Plan") { add(item.id) }
    }
}

/// The hour grid, the blocks placed on it, and where a dragged task would land.
private struct DayTimeline: View {
    let plan: DayPlan
    /// A block shown where it was dropped while its overlap is confirmed.
    let held: DayBlock?
    /// A dropped task's new block while it is saved or confirmed.
    let placing: (block: DayBlock, title: String)?
    let edit: (DayBlock) -> Void
    let save: (DayBlock) async -> Void
    let drop: (DayBlock) async -> Void
    let delete: (Int64) -> Void

    /// Drags measure in this space, which does not move with the block.
    static let space = "dayTimeline"
    static let pointsPerMinute: CGFloat = 1.2
    private let labelWidth: CGFloat = 64
    /// Where a task being dragged over the timeline would land.
    @State private var dropPreview: DayBlock?
    @Environment(\.palette) private var palette

    /// Whole hours around the working hours.
    private var gridStart: Int { plan.workingHours.start.minutes / 60 * 60 }
    private var gridEnd: Int { (plan.workingHours.end.minutes + 59) / 60 * 60 }
    private var scale: TimelineScale { TimelineScale(gridStart: gridStart, pointsPerMinute: Self.pointsPerMinute) }

    private func y(_ minutes: Int) -> CGFloat {
        CGFloat(scale.y(Double(minutes)))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(stride(from: gridStart, through: gridEnd, by: 60)), id: \.self) { minutes in
                HStack(alignment: .center, spacing: 8) {
                    Text(DayPlanText.time(minutesAfterMidnight: minutes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(palette.color(.muted))
                        .frame(width: labelWidth, alignment: .trailing)
                    Rectangle().fill(palette.color(.line)).frame(height: 1)
                }
                .frame(height: 12)
                .offset(y: y(minutes) - 6)
            }
            // Outside working hours is shaded.
            Rectangle().fill(palette.color(.chrome))
                .frame(height: y(plan.workingHours.start.minutes))
                .padding(.leading, labelWidth + 8)
            Rectangle().fill(palette.color(.chrome))
                .frame(height: max(0, y(gridEnd) - y(plan.workingHours.end.minutes)))
                .padding(.leading, labelWidth + 8)
                .offset(y: y(plan.workingHours.end.minutes))
            ForEach(plan.blocks) { block in
                TimelineBlock(plan: plan, block: block, held: held?.id == block.id ? held : nil,
                              scale: scale, edit: edit, save: save, delete: delete)
                    .padding(.leading, labelWidth + 12)
            }
            if let ghost = dropPreview.map({ (block: $0, title: "New block") }) ?? placing {
                GhostBlock(block: ghost.block, title: ghost.title)
                    .offset(y: y(ghost.block.start.minutes))
                    .padding(.leading, labelWidth + 12)
                    .zIndex(2)
            }
        }
        .frame(height: y(gridEnd), alignment: .top)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
        .onDrop(of: [.plainText], delegate: TaskDropDelegate(
            scale: scale, hours: plan.workingHours, preview: $dropPreview,
            drop: { block in Task { await drop(block) } }))
    }
}

/// Places a task dragged from the task panel: shows where it would land
/// while hovering, and on drop asks for an hour-long block at the snapped
/// drop time.
private struct TaskDropDelegate: DropDelegate {
    let scale: TimelineScale
    let hours: TimeSpan
    @Binding var preview: DayBlock?
    let drop: @MainActor @Sendable (DayBlock) -> Void

    private func block(at location: CGPoint, taskID: Int64? = nil) -> DayBlock {
        TimelinePlacement.dropped(taskID: taskID, at: scale.minutes(atY: Double(location.y)), within: hours)
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        preview = block(at: info.location)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        preview = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        preview = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let landing = block(at: info.location)
        let drop = drop
        _ = provider.loadTransferable(type: String.self) { result in
            guard case .success(let text) = result, let taskID = PlanTaskDrag.taskID(from: text) else { return }
            var block = landing
            block.taskID = taskID
            Task { @MainActor in drop(block) }
        }
        return true
    }
}

/// Where a dragged task would land, or a dropped one waiting for its save:
/// outlined, not filled, so it does not read as a saved block.
private struct GhostBlock: View {
    let block: DayBlock
    let title: String
    @Environment(\.palette) private var palette

    var body: some View {
        let height = max(CGFloat(block.span.minutes) * DayTimeline.pointsPerMinute, 18)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(title).fontWeight(.medium).lineLimit(1)
            Spacer(minLength: 4)
            Text(DayPlanText.times(block.span)).font(.caption.monospacedDigit())
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .foregroundStyle(palette.color(.ink))
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .background(palette.color(.surface), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(palette.color(.accent), style: StrokeStyle(lineWidth: 2, dash: [5, 3])))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One block: drag to move, drag the bottom edge to resize. The block
/// follows the pointer and shows the snapped times it will take; on release
/// it settles there with a short animation (none under Reduce motion) and is
/// saved; the plan's rules decide whether it stands.
private struct TimelineBlock: View {
    let plan: DayPlan
    let block: DayBlock
    let held: DayBlock?
    let scale: TimelineScale
    let edit: (DayBlock) -> Void
    let save: (DayBlock) async -> Void
    let delete: (Int64) -> Void

    /// The drag in progress, in unsnapped minutes of pointer travel.
    private enum Drag: Equatable {
        case move(Double)
        case resize(Double)
    }

    @State private var drag: Drag?
    /// Where the block was dropped, shown until the save answers, so it
    /// does not jump back and forth.
    @State private var saving: DayBlock?
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hours: TimeSpan { plan.workingHours }

    /// Where the block rests when no drag is in progress.
    private var settled: DayBlock {
        saving ?? held ?? block
    }

    /// The times the drag would save, snapped to 15 minutes.
    private var snapped: DayBlock {
        switch drag {
        case .move(let minutes): TimelinePlacement.moved(block, by: minutes, within: hours)
        case .resize(let minutes): TimelinePlacement.resized(block, by: minutes, within: hours)
        case nil: settled
        }
    }

    /// Start and length in minutes as drawn: following the pointer while
    /// dragging, otherwise the settled block.
    private var drawn: (start: Double, length: Double) {
        switch drag {
        case .move(let minutes):
            (Double(block.start.minutes) + TimelinePlacement.clampedMove(block, by: minutes, within: hours),
             Double(block.span.minutes))
        case .resize(let minutes):
            (Double(block.start.minutes),
             Double(block.span.minutes) + TimelinePlacement.clampedResize(block, by: minutes, within: hours))
        case nil:
            (Double(settled.start.minutes), Double(settled.span.minutes))
        }
    }

    var body: some View {
        let snapped = snapped
        let drawn = drawn
        let height = max(CGFloat(drawn.length) * DayTimeline.pointsPerMinute, 18)
        let colors = plan.colors(of: block)
        // Opaque, in the block's palette pair, so its text keeps 4.5:1 while
        // it rests, is dragged over other blocks or waits for confirmation.
        label(snapped)
            .foregroundStyle(palette.color(colors.text))
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background(palette.color(colors.background), in: RoundedRectangle(cornerRadius: 6))
            // Keeps touching blocks of the same color apart.
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(palette.color(.line), lineWidth: 1))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(palette.color(colors.text)).frame(width: 3).padding(.vertical, 3)
            }
            .overlay(alignment: .bottom) { resizeHandle }
            .overlay(alignment: .topTrailing) {
                if drag != nil { snappedTimeLabel(snapped) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .gesture(moveGesture)
            .onTapGesture(count: 2) { edit(block) }
            .contextMenu { menu }
            .help(block.isFixed
                  ? "Fixed every day in Settings › Day. Moving or skipping it here changes today only."
                  : "Drag to move, drag the bottom edge to resize, double-click to edit.")
            .offset(y: CGFloat(scale.y(drawn.start)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(DayPlanText.name(settled, in: plan))
            .accessibilityAction(named: "Edit") { edit(block) }
            .accessibilityAction(named: "Move 15 Minutes Earlier") { step(.move(-15)) }
            .accessibilityAction(named: "Move 15 Minutes Later") { step(.move(15)) }
            .accessibilityAction(named: "Make 15 Minutes Longer") { step(.resize(15)) }
            .accessibilityAction(named: "Make 15 Minutes Shorter") { step(.resize(-15)) }
            // A moved block is drawn above the blocks it passes over.
            .zIndex(drag != nil || settled != block ? 1 : 0)
    }

    private func label(_ shown: DayBlock) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if block.isFixed {
                Image(systemName: "pin.fill").imageScale(.small)
                    .help("Fixed every day")
            }
            Text(plan.title(of: block)).fontWeight(.medium).lineLimit(1)
            Spacer(minLength: 4)
            Text(DayPlanText.times(shown.span)).font(.caption.monospacedDigit())
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
    }

    /// The snapped start and end, just above the block while it is dragged,
    /// so it stays readable on a short block.
    private func snappedTimeLabel(_ snapped: DayBlock) -> some View {
        Text(DayPlanText.times(snapped.span))
            .font(.caption.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(palette.color(.ink))
            .background(palette.color(.surface), in: Capsule())
            .overlay(Capsule().stroke(palette.color(.line)))
            .offset(x: -6, y: -20)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var resizeHandle: some View {
        Rectangle().fill(.clear).frame(height: 8).contentShape(Rectangle())
            .pointerStyle(.frameResize(position: .bottom))
            .gesture(resizeGesture)
    }

    /// Minutes of pointer travel, measured in the timeline's space so the
    /// block moving under the pointer does not feed back into the drag.
    private static func minutes(_ value: DragGesture.Value) -> Double {
        Double(value.translation.height / DayTimeline.pointsPerMinute)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(DayTimeline.space))
            .onChanged { drag = .move(Self.minutes($0)) }
            .onEnded { commit(TimelinePlacement.moved(block, by: Self.minutes($0), within: hours)) }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(DayTimeline.space))
            .onChanged { drag = .resize(Self.minutes($0)) }
            .onEnded { commit(TimelinePlacement.resized(block, by: Self.minutes($0), within: hours)) }
    }

    @ViewBuilder private var menu: some View {
        Button(block.isFixed ? "Change for Today…" : "Edit…") { edit(block) }
        Button(block.isFixed ? "Skip Today" : "Delete", role: .destructive) {
            if let id = block.id { delete(id) }
        }
    }

    /// A 15-minute step from VoiceOver or the keyboard, saved like a drag.
    /// It starts from where the block shows, so a step before the last save
    /// answers still adds up, and says the new times or that nothing changed.
    private func step(_ change: Drag) {
        let from = settled
        let moved = switch change {
        case .move(let minutes): TimelinePlacement.moved(from, by: minutes, within: hours)
        case .resize(let minutes): TimelinePlacement.resized(from, by: minutes, within: hours)
        }
        let announcement = moved.span == from.span ? "No change" : DayPlanText.times(moved.span)
        AccessibilityNotification.Announcement(announcement).post()
        guard moved.span != from.span else { return }
        commit(moved)
    }

    /// Settles the block at its snapped times and saves them, showing it
    /// there until the save answers. A refused edit puts it back where it
    /// is stored.
    private func commit(_ moved: DayBlock) {
        let animation: Animation? = reduceMotion ? nil : .snappy(duration: 0.18)
        withAnimation(animation) {
            drag = nil
            if moved != block { saving = moved }
        }
        guard moved != block else { return }
        Task {
            await save(moved)
            withAnimation(animation) { saving = nil }
        }
    }
}
