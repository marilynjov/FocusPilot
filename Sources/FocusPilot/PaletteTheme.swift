import AppKit
import FocusPilotCore
import SwiftUI

extension EnvironmentValues {
    /// The owner's palette in this view's appearance. Views read roles,
    /// `palette.color(.surface)`, never raw colors.
    @Entry var palette = PaletteColors.resolve(palette: .default, appearance: .followMac, system: .light,
                                                increaseContrast: false)
}

extension PaletteColors {
    func color(_ role: PaletteRole) -> Color {
        let color: PaletteColor = self[role]
        return Color(.sRGB, red: Double(color.red) / 255, green: Double(color.green) / 255,
                     blue: Double(color.blue) / 255)
    }
}

extension View {
    /// Puts the owner's palette in the environment for this window or
    /// panel, resolved for its appearance and Increase Contrast. Apply once
    /// at each root (planning window, menu bar panel, floating panels).
    func paletteTheme(_ preferences: DisplayPreferences) -> some View {
        modifier(PaletteThemeModifier(preferences: preferences))
    }
}

private struct PaletteThemeModifier: ViewModifier {
    let preferences: DisplayPreferences
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.environment(\.palette, preferences.colors(system: colorScheme == .dark ? .dark : .light,
                                                           increaseContrast: contrast == .increased))
    }
}

extension DisplayPreferences {
    /// Pins every window, the menu bar panel and the floating panels to
    /// Light or Dark, or lets them follow the Mac. AppKit then updates each
    /// open window's appearance, and SwiftUI its color scheme.
    func applyAppearance() {
        NSApplication.shared.appearance = switch appearance {
        case .followMac: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// The prominent button in the palette's accent, with `onAccent` text so the
/// label keeps its contrast in every palette (native prominent buttons draw
/// white text, which is too faint on the light dark-mode accents).
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(palette.color(.onAccent))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(palette.color(.accent), in: .rect(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : isEnabled ? 1 : 0.45)
            .contentShape(.rect(cornerRadius: 8))
    }
}
