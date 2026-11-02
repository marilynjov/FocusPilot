import FocusPilotCore
import SwiftUI

/// Settings › General: palette and appearance, menu bar, focus panel, raccoon and login.
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
                Toggle("Show the focus panel during sessions", isOn: $preferences.showsFocusPanel)
                    .onChange(of: preferences.showsFocusPanel) { model.focusPanel.update() }
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
                Text("While a task is under way, the raccoon is in the corner of this window: working, sitting while paused, or with coffee on a break. When you switch to another app, it moves to the bottom-right corner of the screen this window is on, above other windows, and clicks go through it. With this window closed, it uses the screen you choose here. With Reduce Motion on, it stays still.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if display.raccoonMode != .off, let problem = model.raccoon.problem {
                    Text(problem).font(.callout).foregroundStyle(.secondary)
                }
            }
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
