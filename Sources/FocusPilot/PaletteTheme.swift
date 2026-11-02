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
    /// panel, resolved for its appearance and Increase Contrast, and tints
    /// selection, toggles, links and prominent buttons with its accent.
    /// Apply once at each root (planning window, menu bar panel, floating
    /// panels).
    func paletteTheme(_ preferences: DisplayPreferences) -> some View {
        modifier(PaletteThemeModifier(preferences: preferences))
    }

    /// The prominent button in the palette's accent. Native when the
    /// palette's text on the accent is white, as native prominent buttons
    /// draw it; otherwise (the light accents of dark palettes) a custom
    /// style with the palette's dark `onAccent` text, so the label keeps
    /// 4.5:1 in every palette.
    func accentProminentButton() -> some View {
        modifier(AccentProminentButton())
    }
}

private struct PaletteThemeModifier: ViewModifier {
    let preferences: DisplayPreferences
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let colors = preferences.colors(system: colorScheme == .dark ? .dark : .light,
                                        increaseContrast: contrast == .increased)
        content
            .tint(colors.color(.accent))
            .environment(\.palette, colors)
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

private struct AccentProminentButton: ViewModifier {
    @Environment(\.palette) private var palette
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        if palette[.onAccent] as PaletteColor == .white {
            content.buttonStyle(.borderedProminent)
        } else {
            content
                .buttonStyle(AccentButtonStyle(outlined: contrast == .increased))
                // Full Keyboard Access: the system ring, drawn here because
                // a custom style has none of its own.
                .focused($isFocused)
                .focusEffectDisabled()
                .overlay {
                    if isFocused {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                            .padding(-3)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

/// A prominent button filled with the palette's accent and labeled in
/// `onAccent`, sized like the native one for the control size, with a
/// text-colored border under Increase Contrast.
private struct AccentButtonStyle: ButtonStyle {
    let outlined: Bool
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let large = controlSize == .large || controlSize == .extraLarge
        configuration.label
            .font(large ? .body.weight(.medium) : nil)
            .foregroundStyle(palette.color(.onAccent))
            .padding(.horizontal, large ? 14 : 10)
            .frame(minHeight: large ? 30 : 22)
            .background(palette.color(.accent), in: .rect(cornerRadius: large ? 8 : 6))
            .overlay {
                if outlined {
                    RoundedRectangle(cornerRadius: large ? 8 : 6).strokeBorder(palette.color(.ink), lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.8 : isEnabled ? 1 : 0.45)
            .contentShape(.rect(cornerRadius: large ? 8 : 6))
    }
}
