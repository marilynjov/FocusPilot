import Foundation
import Observation

/// Owner choices about the menu bar item. Stored in UserDefaults: they are
/// display conveniences, not owner data the database must keep.
@MainActor
@Observable
public final class MenuBarPreferences {
    private static let showsTimeKey = "menuBarShowsTime"
    private static let hidesFocusPanelKey = "hidesFocusPanel"
    private static let mutesTimeUpSoundKey = "mutesTimeUpSound"

    private let defaults: UserDefaults

    /// Show the time left next to the glyph while a session is active. Off by
    /// default, so the menu bar item stays a single icon (the logo design
    /// keeps it narrow enough not to be hidden behind the notch).
    public var showsTime: Bool {
        didSet { defaults.set(showsTime, forKey: Self.showsTimeKey) }
    }

    /// Show the floating focus panel during sessions. On by default; it is
    /// optional (#11), so the owner can rely on the menu bar alone.
    public var showsFocusPanel: Bool {
        didSet { defaults.set(!showsFocusPanel, forKey: Self.hidesFocusPanelKey) }
    }

    /// Play a short sound when time is up, and a softer one shortly
    /// before (owner request, 2026-11-03). On by default: notifications are
    /// quiet, so this is the sign that reaches the owner in another app.
    public var playsTimeUpSound: Bool {
        didSet { defaults.set(!playsTimeUpSound, forKey: Self.mutesTimeUpSoundKey) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showsTime = defaults.bool(forKey: Self.showsTimeKey)
        showsFocusPanel = !defaults.bool(forKey: Self.hidesFocusPanelKey)
        playsTimeUpSound = !defaults.bool(forKey: Self.mutesTimeUpSoundKey)
    }
}
