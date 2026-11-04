import Foundation
import Testing
@testable import FocusPilotCore

@MainActor
@Suite("Menu bar preferences")
struct MenuBarPreferencesTests {
    private let defaults = UserDefaults(suiteName: "FocusPilotTests-\(UUID().uuidString)")!

    @Test func timeLabelIsOffByDefault() {
        #expect(!MenuBarPreferences(defaults: defaults).showsTime)
    }

    @Test func turningTheTimeLabelOnIsRemembered() {
        MenuBarPreferences(defaults: defaults).showsTime = true

        #expect(MenuBarPreferences(defaults: defaults).showsTime)
    }

    @Test func focusPanelIsShownByDefaultAndCanBeTurnedOff() {
        #expect(MenuBarPreferences(defaults: defaults).showsFocusPanel)

        MenuBarPreferences(defaults: defaults).showsFocusPanel = false

        #expect(!MenuBarPreferences(defaults: defaults).showsFocusPanel)
    }

    @Test func theTimeUpSoundIsOnByDefaultAndCanBeTurnedOff() {
        #expect(MenuBarPreferences(defaults: defaults).playsTimeUpSound)

        MenuBarPreferences(defaults: defaults).playsTimeUpSound = false

        #expect(!MenuBarPreferences(defaults: defaults).playsTimeUpSound)
    }
}
