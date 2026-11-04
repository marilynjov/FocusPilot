import FocusPilotCore
import SwiftUI

/// Settings › General: palette and appearance, menu bar, focus panel,
/// raccoon, agent monitoring with the Claude Code hooks setup, and login.
struct GeneralSettings: View {
    let model: AppModel

    var body: some View {
        @Bindable var preferences = model.menuBarPreferences
        @Bindable var display = model.displayPreferences
        Form {
            Section("Appearance") {
                Picker("Palette", selection: $display.palette) {
                    ForEach(Palette.allCases) { Text($0.name).tag($0) }
                }
                PalettePreview(palette: display.palette)
                Picker("Appearance", selection: $display.appearance) {
                    ForEach(AppearanceSetting.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Menu bar") {
                Toggle("Show time left in the menu bar", isOn: $preferences.showsTime)
            }
            Section("Sessions") {
                Toggle("Play a sound when time is up", isOn: $preferences.playsTimeUpSound)
                    .help("A short sound when a session, a break or a quick timer is up, and a softer one shortly before")
                Toggle("Show the focus panel during sessions", isOn: $preferences.showsFocusPanel)
                    .onChange(of: preferences.showsFocusPanel) { model.focusPanel.update() }
                    .disabled(display.raccoonMode == .staysOnScreen && model.raccoon.problem == nil)
                if display.raccoonMode == .staysOnScreen && model.raccoon.problem == nil {
                    Text("The raccoon stands in for the focus panel: click it to open the panel.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Raccoon companion") {
                Picker("Raccoon", selection: $display.raccoonMode) {
                    ForEach(RaccoonCompanionMode.allCases) { Text($0.title).tag($0) }
                }
                if display.raccoonMode == .staysOnScreen {
                    Picker("Screen", selection: $display.raccoonScreen) {
                        Text("Main display").tag(String?.none)
                        ForEach(RaccoonScreenChoice.connected(besides: display.raccoonScreen)) { choice in
                            Text(choice.name).tag(Optional(choice.id))
                        }
                    }
                }
                Text("While a task is under way, the raccoon is in the corner of this window: working, sitting while paused, or with coffee on a break. When you switch to another app, it moves to the bottom-right corner of the screen this window is on, above other windows. With this window closed, it uses the screen you choose here. On screen it replaces the focus panel: point at it to see the time left, and click it to open the panel. With Reduce Motion on, it stays still.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if display.raccoonMode != .off, let problem = model.raccoon.problem {
                    Text(problem).font(.callout).foregroundStyle(.secondary)
                }
            }
            AgentMonitoringSection(model: model)
            Section("General") {
                Toggle("Open at Login", isOn: Binding(
                    get: { model.loginItem.isEnabled },
                    set: { model.loginItem.setEnabled($0) }
                ))
                if let message = model.loginItem.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Agent monitoring (decision 0005, step 1), off by default, and the hooks
/// block for Claude Code with a Copy button. FocusPilot never edits the
/// owner's Claude Code settings itself.
private struct AgentMonitoringSection: View {
    let model: AppModel
    @State private var copied = false

    /// The focuspilot command inside this app, so the hooks work without a
    /// PATH link; "focuspilot" for a bare debug build.
    private var snippet: String {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/focuspilot")
        let command = FileManager.default.isExecutableFile(atPath: helper.path) ? helper.path : "focuspilot"
        return ClaudeHookSnippet.settings(command: command)
    }

    var body: some View {
        Section("Agent monitoring") {
            Toggle("Agent monitoring", isOn: Binding(
                get: { model.isAgentMonitoringOn },
                set: { on in Task { await model.setAgentMonitoring(on) } }
            ))
            Text("Agents that report through the focuspilot command or Claude Code hooks show in a task’s Agent panel, and their results go to Review queue. FocusPilot only listens: it never prompts, answers or stops an agent. While this is off, reports are refused. Herdr agents are not affected by this setting yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.agentMonitoringError {
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
        }
        Section("Claude Code hooks") {
            Text("To hear from Claude Code, add this to the \"hooks\" in ~/.claude/settings.json (merge it with any hooks you already have), then start a new Claude Code session. It reports a new session, a prompt, a request for your permission or input, and a finished turn. No usage or token figures are read.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView(.horizontal) {
                Text(verbatim: snippet)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
            }
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
            HStack {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                }
                Spacer()
                Text("Steps and details: docs/agents/claude-code-hooks.md")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The palette's light and dark versions side by side: background, text,
/// accent and the Task 1–3 colors.
private struct PalettePreview: View {
    let palette: Palette

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                strip(.light)
                strip(.dark)
            }
        } label: {
            Text(palette.blurb)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func strip(_ appearance: Appearance) -> some View {
        let colors = PaletteColors.resolve(palette: palette, appearance: appearance == .light ? .light : .dark,
                                           system: appearance, increaseContrast: false)
        return HStack(spacing: 4) {
            Text(verbatim: "Aa")
                .font(.caption.weight(.semibold))
                .foregroundStyle(colors.color(.ink))
            ForEach([PaletteRole.accent, .t1bg, .t2bg, .t3bg], id: \.self) { role in
                Circle()
                    .fill(colors.color(role))
                    .overlay(Circle().strokeBorder(colors.color(.line)))
                    .frame(width: 12, height: 12)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(colors.color(.bg), in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .accessibilityHidden(true)
    }
}

/// A display the floating raccoon can go on, for the Screen picker.
struct RaccoonScreenChoice: Identifiable {
    let id: String
    let name: String

    /// The connected displays, plus `chosen` if it is disconnected, so the
    /// picker still shows the saved choice.
    @MainActor
    static func connected(besides chosen: String?) -> [RaccoonScreenChoice] {
        var choices = NSScreen.screens.compactMap { screen in
            screen.displayUUID.map { RaccoonScreenChoice(id: $0, name: screen.localizedName) }
        }
        if let chosen, !choices.contains(where: { $0.id == chosen }) {
            choices.append(RaccoonScreenChoice(id: chosen, name: "Disconnected display (using main display)"))
        }
        return choices
    }
}
