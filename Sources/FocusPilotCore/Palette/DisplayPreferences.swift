import Foundation
import Observation

/// The owner's Palette, Appearance and raccoon companion mode. Stored in UserDefaults like the menu
/// bar choices: a display preference, not owner data, and not a cache, so
/// clearing caches leaves it alone.
@MainActor
@Observable
public final class DisplayPreferences {
    private static let paletteKey = "paletteName"
    private static let appearanceKey = "appearanceSetting"
    private static let raccoonModeKey = "raccoonCompanionMode"
    private static let raccoonScreenKey = "raccoonCompanionScreen"

    private let defaults: UserDefaults

    public var palette: Palette {
        didSet { defaults.set(palette.rawValue, forKey: Self.paletteKey) }
    }

    /// Every change, from Settings or anywhere else, is saved and passed to
    /// `appearanceDidChange`, which applies it to the app's windows.
    public var appearance: AppearanceSetting {
        didSet {
            defaults.set(appearance.rawValue, forKey: Self.appearanceKey)
            appearanceDidChange?(appearance)
        }
    }

    /// Where the raccoon companion appears (D11). Off for a new install
    /// until the owner confirms a default (decision 0004 lists the modes as proposed).
    public var raccoonMode: RaccoonCompanionMode {
        didSet {
            defaults.set(raccoonMode.rawValue, forKey: Self.raccoonModeKey)
            raccoonModeDidChange?(raccoonMode)
        }
    }

    /// The display the floating raccoon goes on, by its display UUID; nil
    /// is the main display (the one with the menu bar), which is also used
    /// while the chosen display is disconnected.
    public var raccoonScreen: String? {
        didSet {
            defaults.set(raccoonScreen, forKey: Self.raccoonScreenKey)
            raccoonScreenDidChange?()
        }
    }

    /// Called after each change of `raccoonScreen`.
    @ObservationIgnored public var raccoonScreenDidChange: (@MainActor () -> Void)?

    /// Called with the mode after each change.
    @ObservationIgnored public var raccoonModeDidChange: (@MainActor (RaccoonCompanionMode) -> Void)?

    /// Called with the setting after each change.
    @ObservationIgnored public var appearanceDidChange: (@MainActor (AppearanceSetting) -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        palette = defaults.string(forKey: Self.paletteKey).flatMap(Palette.init(rawValue:)) ?? .default
        appearance = defaults.string(forKey: Self.appearanceKey).flatMap(AppearanceSetting.init(rawValue:)) ?? .followMac
        raccoonMode = defaults.string(forKey: Self.raccoonModeKey).flatMap(RaccoonCompanionMode.init(rawValue:)) ?? .default
        raccoonScreen = defaults.string(forKey: Self.raccoonScreenKey)
    }

    /// The colors to show on a Mac in `system` appearance.
    public func colors(system: Appearance, increaseContrast: Bool) -> PaletteColors {
        .resolve(palette: palette, appearance: appearance, system: system, increaseContrast: increaseContrast)
    }
}
