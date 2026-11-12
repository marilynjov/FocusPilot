import AppKit
import FocusPilotCore
import SwiftUI

/// The planning window (design 01, 07, 15 and 16): a sidebar with Today,
/// Today's plan (D1), Projects, Review queue and Settings, and the quick capture sheet. A
/// selected task shows its Agent section in the inspector; the rest of the
/// task detail pane arrives with its ticket. The sidebar footer shows
/// protection status (#17).
struct PlanningView: View {
    static let windowID = "planning"

    enum Page: Hashable {
        case today, dayPlan, projects, review, settings
    }

    let model: AppModel
    @State private var page: Page?
    @State private var isCapturing = false
    @State private var todaySelection: Int64?
    @Environment(\.palette) private var palette

    init(model: AppModel, page: Page = .today) {
        self.model = model
        _page = State(initialValue: page)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Label("Today", systemImage: "sun.max").tag(Page.today)
                Label("Today’s plan", systemImage: "calendar.day.timeline.left").tag(Page.dayPlan)
                Label("Projects", systemImage: "folder").tag(Page.projects)
                // The tag goes last, on the whole row: after it, the badge
                // left the row unselectable once the page had been left
                // (owner report, 2026-11-10).
                Label("Review queue", systemImage: "tray.full")
                    .badge(model.reviewItems.count)
                    .tag(Page.review)
                Label("Settings", systemImage: "gearshape").tag(Page.settings)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { SidebarProtectionFooter(model: model) }
        } detail: {
            content
                // The window background in the owner's palette (#14); lists
                // and forms show it instead of drawing their own.
                .scrollContentBackground(.hidden)
                .background(palette.color(.bg))
                // On Today the raccoon is inside the Now card instead; an
                // empty Today has none, so it stays in the corner there.
                .overlay(alignment: .bottomTrailing) {
                    if raccoonSpot == .corner { RaccoonWindowView(model: model, showsNote: page != .review) }
                }
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .toolbar {
                    Button("Add", systemImage: "plus") { isCapturing = true }
                        .help(page == .dayPlan ? "Add a task or break to today’s plan (⌘N)" : "New task (⌘N)")
                }
        }
        .frame(minWidth: 760, minHeight: 420)
        .focusedSceneValue(\.quickCapture, { isCapturing = true })
        .sheet(item: sheet) { sheet in
            switch sheet {
            // One way to add (owner request, 2026-11-02): a task for the
            // list, or on Today's plan a task or break with its times.
            case .capture: AddToPlanSheet(model: model, draft: captureDraft)
            case .startFocus: StartFocusSheet(model: model)
            case .wrapUp:
                if let pending = model.wrapUp { WrapUpSheet(model: model, prompt: pending.prompt) }
            }
        }
        .alert(model.ownWindowOffer.map { "\($0.label) isn’t in its own window" } ?? "",
               isPresented: Binding(get: { model.ownWindowOffer != nil }, set: { if !$0 { model.ownWindowOffer = nil } }),
               presenting: model.ownWindowOffer) { agent in
            Button("Open in Its Own Window") { model.openOfferedWindow(agent) }
            Button("Just Show Warp") { model.showWarp(for: agent) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It doesn’t have a window FocusPilot opened, so FocusPilot can’t pick its tab and Warp would show the window you used last. Opening it in its own window continues the same chat there, and Go to agent goes straight to it from then on. Close the old tab afterwards so you don’t type in both.")
        }
        .environment(model)
        .task { await model.refresh() }
        .onChange(of: model.requestedPage, initial: true) {
            if let requested = model.requestedPage {
                page = requested
                model.requestedPage = nil
            }
        }
        // LSUIElement keeps the app out of the Dock, but while the planning
        // window is open the owner should be able to find it there and with
        // Command-Tab like any other window.
        // The raccoon follows: here while the window is open, on screen
        // while it is closed.
        .onAppear {
            NSApplication.shared.setActivationPolicy(.regular)
            model.isPlanningWindowOpen = true
        }
        .onDisappear {
            NSApplication.shared.setActivationPolicy(.accessory)
            model.isPlanningWindowOpen = false
        }
    }

    /// One sheet modifier, so a wrap-up and Start focus wanted at once show
    /// one after the other instead of one being dropped (see `PlanningSheet`).
    /// Closing a sheet clears only what that sheet was showing. A wrap-up is
    /// never dropped this way: only Skip and Save end it, so its draft stays.
    private var sheet: Binding<PlanningSheet?> {
        Binding(
            get: { PlanningSheet.showing(isCapturing: isCapturing, wrapUp: model.wrapUp, isStartingFocus: model.isStartingFocus) },
            set: { newValue in
                guard newValue == nil else { return }
                switch PlanningSheet.showing(isCapturing: isCapturing, wrapUp: model.wrapUp, isStartingFocus: model.isStartingFocus) {
                case .capture: isCapturing = false
                case .wrapUp: break
                case .startFocus: model.isStartingFocus = false
                case nil: break
                }
            }
        )
    }

    private var captureDraft: AddToPlanSheet.Draft {
        let schedules = page == .dayPlan
        if let plan = model.dayPlan, plan.date == model.todayDate {
            return AddToPlanSheet.Draft(in: plan, schedules: schedules)
        }
        return AddToPlanSheet.Draft(on: model.todayDate, schedules: schedules)
    }

    private var title: String {
        switch page {
        case .dayPlan: "Today’s plan"
        case .projects: "Projects"
        case .review: "Review queue"
        case .settings: "Settings"
        case .today, nil: "Today"
        }
    }

    private var subtitle: String {
        switch page {
        case .projects, .settings: return ""
        case .review:
            let count = model.reviewItems.count
            let approvals = model.reviewItems.filter { $0.kind == .approval }.count
            let results = count == 1 ? "1 result" : "\(count) results"
            return count == 0 ? "Nothing queued"
                : approvals == 0 ? results : "\(results) · \(approvals) need\(approvals == 1 ? "s" : "") your approval"
        case .today, .dayPlan, nil: return Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
    }

    /// Where the raccoon is drawn in this window while it is in front.
    private var raccoonSpot: RaccoonPresence.WindowSpot? {
        RaccoonPresence.windowSpot(isInFront: model.raccoonIsInWindow, isToday: page == .today || page == nil,
                                   isTodayEmpty: model.today.isEmpty || model.startupError != nil)
    }

    @ViewBuilder private var content: some View {
        if let startupError = model.startupError {
            ContentUnavailableView("Database unavailable", systemImage: "exclamationmark.triangle", description: Text(startupError))
        } else if page == .dayPlan {
            DayPlanView(model: model)
        } else if page == .projects {
            ProjectsView(model: model, showReviewQueue: { page = .review })
        } else if page == .review {
            ReviewQueueView(model: model)
        } else if page == .settings {
            SettingsPage(model: model)
        } else {
            todayPage
        }
    }

    /// Today (owner request, 2026-11-03): the current task across the top;
    /// under it the rest of the list with the Quick timer at the bottom, and
    /// the selected task's Agent column to the right of both.
    @ViewBuilder private var todayPage: some View {
        if model.today.isEmpty {
            VStack(spacing: 0) {
                todayTasks
                quickTimer
            }
        } else {
            VStack(spacing: 0) {
                TimelineView(.everyMinute) { context in
                    let now = TaskSections(model.today).now
                    let isSelected = now != nil && todaySelection == now?.id
                    NowCard(item: now, caption: nil, showsProject: true, now: context.date,
                            showsRaccoon: raccoonSpot == .nowCard, isSelected: isSelected)
                        .contentShape(Rectangle())
                        .onTapGesture { todaySelection = now?.id }
                        // Reachable without a pointer: Return selects it, and
                        // VoiceOver offers the same.
                        .focusable(now != nil)
                        .onKeyPress(.return) {
                            guard let now else { return .ignored }
                            todaySelection = now.id
                            return .handled
                        }
                        .accessibilityAction(named: "Show Agent Panel") { todaySelection = now?.id }
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                VStack(spacing: 0) {
                    todayTasks
                    quickTimer
                }
                .taskInspector(model: model, items: model.today, selection: $todaySelection,
                               showReviewQueue: { page = .review })
            }
        }
    }

    private var quickTimer: some View {
        QuickTimerCard(model: model)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
    }

    /// Today's tasks under the Now card, above the Quick timer card (D2).
    @ViewBuilder private var todayTasks: some View {
        if model.today.isEmpty {
            ContentUnavailableView(
                "No tasks yet",
                systemImage: "sun.max",
                description: Text("Press ⌘N to capture one. Closing this window keeps FocusPilot running in the menu bar.")
            )
        } else {
            TaskList(items: model.today, showsProject: true,
                     move: { id, status, placement in Task { await model.move(id, to: status, placement) } },
                     undoHerdrAdd: { id in Task { await model.undoHerdrAdd(id) } },
                     activeSessionTaskID: model.snapshot.activeSession?.taskID,
                     selection: $todaySelection, showsNow: false)
        }
    }
}

extension View {
    /// The selected task's Agent section in a column beside the list, shown
    /// while a task is selected. A plain column, not a window inspector, so
    /// it sits under whatever is above the list (the Quick timer on Today)
    /// and leaves the title bar whole (owner feedback, 2026-11-03).
    func taskInspector(model: AppModel, items: [TodayItem], selection: Binding<Int64?>,
                       showReviewQueue: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            self
            if let task = items.first(where: { $0.id == selection.wrappedValue }) {
                Divider()
                TaskAgentInspector(model: model, task: task, showReviewQueue: showReviewQueue)
                    .frame(width: 300)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}
