import FocusPilotCore
import SwiftUI

/// Settings › General: palette and appearance, menu bar, focus panel and login.
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
                .onChange(of: display.appearance) { display.applyAppearance() }
            }
            Section("Menu bar") {
                Toggle("Show time left in the menu bar", isOn: $preferences.showsTime)
            }
            Section("Sessions") {
                Toggle("Show the focus panel during sessions", isOn: $preferences.showsFocusPanel)
                    .onChange(of: preferences.showsFocusPanel) { model.focusPanel.update() }
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
