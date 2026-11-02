import Foundation
import Observation

/// The owner's Palette and Appearance. Stored in UserDefaults like the menu
/// bar choices: a display preference, not owner data, and not a cache, so
/// clearing caches leaves it alone.
@MainActor
@Observable
public final class DisplayPreferences {
    private static let paletteKey = "paletteName"
    private static let appearanceKey = "appearanceSetting"

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

    /// Called with the setting after each change.
    @ObservationIgnored public var appearanceDidChange: (@MainActor (AppearanceSetting) -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        palette = defaults.string(forKey: Self.paletteKey).flatMap(Palette.init(rawValue:)) ?? .default
        appearance = defaults.string(forKey: Self.appearanceKey).flatMap(AppearanceSetting.init(rawValue:)) ?? .followMac
    }

    /// The colors to show on a Mac in `system` appearance.
    public func colors(system: Appearance, increaseContrast: Bool) -> PaletteColors {
        .resolve(palette: palette, appearance: appearance, system: system, increaseContrast: increaseContrast)
    }
}
