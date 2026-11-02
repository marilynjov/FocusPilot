import Foundation
import Testing
@testable import FocusPilotCore

@Suite("Palettes")
struct PaletteTests {
    /// Every palette, appearance and contrast variant the app can show.
    static let variants: [PaletteColors] = Palette.allCases.flatMap { palette in
        [Appearance.light, .dark].flatMap { appearance in
            [false, true].map { contrast in
                PaletteColors.resolve(palette: palette, appearance: .followMac, system: appearance, increaseContrast: contrast)
            }
        }
    }

    private func name(_ colors: PaletteColors) -> String {
        "\(colors.palette.name) \(colors.appearance)\(colors.increasedContrast ? " increased contrast" : "")"
    }

    @Test func everyPaletteHasEveryRoleInBothAppearances() {
        for palette in Palette.allCases {
            for appearance in [Appearance.light, .dark] {
                #expect(Set(PaletteTable.hex(palette, appearance).keys) == Set(PaletteRole.allCases), "\(palette) \(appearance)")
            }
        }
    }

    @Test(arguments: variants)
    func textMeetsFourPointFiveToOne(colors: PaletteColors) {
        for (text, background) in PaletteContrast.textPairs {
            let ratio = colors[text].contrast(with: colors[background])
            #expect(ratio >= PaletteContrast.textMinimum,
                    "\(name(colors)): \(text) \(colors[text]) on \(background) \(colors[background]) is \(ratio):1")
        }
    }

    @Test(arguments: variants)
    func statusDotsAndAccentMeetThreeToOne(colors: PaletteColors) {
        for (mark, background) in PaletteContrast.graphicPairs {
            let ratio = colors[mark].contrast(with: colors[background])
            #expect(ratio >= PaletteContrast.graphicMinimum,
                    "\(name(colors)): \(mark) \(colors[mark]) on \(background) \(colors[background]) is \(ratio):1")
        }
    }

    @Test(arguments: Palette.allCases)
    func increasedContrastIsStrongerForTextAndSeparators(palette: Palette) {
        for appearance in [Appearance.light, .dark] {
            let normal = PaletteColors.resolve(palette: palette, appearance: .followMac, system: appearance, increaseContrast: false)
            let strong = PaletteColors.resolve(palette: palette, appearance: .followMac, system: appearance, increaseContrast: true)
            for (text, background) in PaletteContrast.textPairs where text != .onAccent {
                #expect(strong[text].contrast(with: strong[background]) > normal[text].contrast(with: normal[background]))
            }
            #expect(strong[.line].contrast(with: strong[.surface]) > normal[.line].contrast(with: normal[.surface]))
            #expect(strong[.ink].contrast(with: strong[.surface]) >= 7, "\(palette) \(appearance)")
        }
    }

    @Test func contrastRatioMatchesWCAG() {
        #expect(PaletteColor.black.contrast(with: .white) == 21)
        #expect(abs(PaletteColor(hex: "#007AFF").contrast(with: .white) - 4.02) < 0.01)
        #expect(PaletteColor(hex: "#A84B34").description == "#A84B34")
    }

    @Test func appearanceSettingPinsOrFollowsTheMac() {
        func shown(_ setting: AppearanceSetting, _ system: Appearance) -> Appearance {
            PaletteColors.resolve(palette: .raccoon, appearance: setting, system: system, increaseContrast: false).appearance
        }
        #expect(shown(.followMac, .light) == .light)
        #expect(shown(.followMac, .dark) == .dark)
        #expect(shown(.light, .dark) == .light)
        #expect(shown(.dark, .light) == .dark)
    }

    @Test func picksTheApprovedColorsForPaletteAndAppearance() {
        let raccoonDark = PaletteColors.resolve(palette: .raccoon, appearance: .dark, system: .light, increaseContrast: false)
        #expect(raccoonDark[.accent] == PaletteColor(hex: "#E58A6F"))
        let forestLight = PaletteColors.resolve(palette: .forest, appearance: .followMac, system: .light, increaseContrast: false)
        #expect(forestLight[.bg] == PaletteColor(hex: "#F4F6F1"))
    }
}

@MainActor
@Suite("Display preferences")
struct DisplayPreferencesTests {
    private let defaults = UserDefaults(suiteName: "FocusPilotTests-\(UUID().uuidString)")!

    @Test func newInstallsStartColorfulFollowingTheMac() {
        let preferences = DisplayPreferences(defaults: defaults)

        #expect(preferences.palette == .colorful)
        #expect(preferences.appearance == .followMac)
    }

    @Test func choicesAreRemembered() {
        let preferences = DisplayPreferences(defaults: defaults)
        preferences.palette = .forest
        preferences.appearance = .dark

        let reopened = DisplayPreferences(defaults: defaults)
        #expect(reopened.palette == .forest)
        #expect(reopened.appearance == .dark)
        #expect(reopened.colors(system: .light, increaseContrast: false).appearance == .dark)
    }
}
