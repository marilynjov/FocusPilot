import Foundation

/// The color palettes (#14, decision 0004): Raccoon, Neutral, Colorful,
/// Forest and System, each with a light and a dark version. Views read
/// colors by role (`PaletteRole`), never as raw values; this file is the
/// one table of role → color.
public enum Palette: String, CaseIterable, Identifiable, Sendable {
    case raccoon, neutral, colorful, forest, system

    /// A new install starts with Colorful, following the Mac's appearance.
    public static let `default` = Palette.colorful

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .raccoon: "Raccoon"
        case .neutral: "Neutral"
        case .colorful: "Colorful"
        case .forest: "Forest"
        case .system: "System"
        }
    }

    public var blurb: String {
        switch self {
        case .raccoon: "Warm and cozy: cream fur, charcoal mask, a clay accent."
        case .neutral: "Quiet grays with one slate-blue accent."
        case .colorful: "Pastels in light mode and rich color in dark mode."
        case .forest: "Calm sage greens and soft earth tones."
        case .system: "The Phase 1 macOS look, with a softer dark mode."
        }
    }
}

/// What a color is for. Task 1–3, lunch and break come in background and
/// text pairs; agent Working uses `accent`.
public enum PaletteRole: String, CaseIterable, Sendable {
    /// The canvas behind windows in the design; window background, sidebar,
    /// title bar area and cards.
    case page, bg, chrome, side, surface
    /// Text and secondary text.
    case ink, muted
    /// Separators, and the unfilled part of progress tracks.
    case line, track
    /// The accent, and text drawn on it.
    case accent, onAccent
    case t1bg, t1fg, t2bg, t2fg, t3bg, t3fg
    case lunchbg, lunchfg, breakbg, breakfg
    /// Agent statuses: Blocked, Ready, Unknown (Working is `accent`).
    case blocked, ready, unknown
}

/// The owner's Appearance setting.
public enum AppearanceSetting: String, CaseIterable, Identifiable, Sendable {
    case followMac, light, dark

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .followMac: "Follow Mac"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The appearance shown when the Mac is in `system`.
    public func resolved(system: Appearance) -> Appearance {
        switch self {
        case .followMac: system
        case .light: .light
        case .dark: .dark
        }
    }
}

public enum Appearance: Sendable, Hashable {
    case light, dark
}

/// An opaque sRGB color.
public struct PaletteColor: Hashable, Sendable, CustomStringConvertible {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// "#RRGGBB".
    public init(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        precondition(digits.count == 6, "Palette colors are #RRGGBB: \(hex)")
        let value = UInt32(digits, radix: 16)!
        self.init(red: UInt8(value >> 16 & 0xFF), green: UInt8(value >> 8 & 0xFF), blue: UInt8(value & 0xFF))
    }

    public var description: String { String(format: "#%02X%02X%02X", red, green, blue) }

    /// WCAG 2.2 relative luminance.
    public var relativeLuminance: Double {
        func linear(_ component: UInt8) -> Double {
            let c = Double(component) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2.2 contrast ratio, from 1 to 21.
    public func contrast(with other: PaletteColor) -> Double {
        let (a, b) = (relativeLuminance, other.relativeLuminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// This color moved `amount` (0...1) of the way toward `other`.
    public func mixed(with other: PaletteColor, _ amount: Double) -> PaletteColor {
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8((Double(a) + (Double(b) - Double(a)) * amount).rounded())
        }
        return PaletteColor(red: mix(red, other.red), green: mix(green, other.green), blue: mix(blue, other.blue))
    }

    public static let black = PaletteColor(red: 0, green: 0, blue: 0)
    public static let white = PaletteColor(red: 255, green: 255, blue: 255)
}

/// One palette in one appearance: a color for every role.
public struct PaletteColors: Sendable, Equatable {
    public let palette: Palette
    public let appearance: Appearance
    public let increasedContrast: Bool
    private let colors: [PaletteRole: PaletteColor]

    public subscript(role: PaletteRole) -> PaletteColor { colors[role]! }

    /// The colors to show: the palette in the appearance the setting picks
    /// (the Mac's own with Follow Mac), in its higher-contrast variant when
    /// the Mac's Increase Contrast is on.
    public static func resolve(palette: Palette, appearance setting: AppearanceSetting,
                               system: Appearance, increaseContrast: Bool) -> PaletteColors {
        let appearance = setting.resolved(system: system)
        var colors = PaletteTable.colors(palette, appearance)
        if increaseContrast {
            colors = PaletteTable.increasedContrast(colors, appearance)
        }
        return PaletteColors(palette: palette, appearance: appearance, increasedContrast: increaseContrast, colors: colors)
    }
}

/// Text and background roles used together, and what contrast they need.
/// Checked by a test over every palette, appearance and contrast variant.
public enum PaletteContrast {
    /// Body text: 4.5:1 (WCAG 1.4.3).
    public static let textPairs: [(text: PaletteRole, background: PaletteRole)] =
        [PaletteRole.ink, .muted].flatMap { text in [PaletteRole.bg, .chrome, .side, .surface].map { (text, $0) } }
            + [(.onAccent, .accent), (.t1fg, .t1bg), (.t2fg, .t2bg), (.t3fg, .t3bg), (.lunchfg, .lunchbg), (.breakfg, .breakbg)]

    /// Status dots and the accent as a fill: 3:1 against every background
    /// they can sit on (WCAG 1.4.11, non-text contrast). Status labels
    /// themselves are drawn in text colors, never in these, so they are held
    /// to 4.5:1 as text.
    public static let graphicPairs: [(mark: PaletteRole, background: PaletteRole)] =
        [PaletteRole.accent, .blocked, .ready, .unknown].flatMap { mark in
            [PaletteRole.bg, .chrome, .side, .surface].map { (mark, $0) }
        }

    public static let textMinimum = 4.5
    public static let graphicMinimum = 3.0
}

enum PaletteTable {
    /// The higher-contrast variant for Increase Contrast: text moves toward
    /// black (light) or white (dark), separators toward secondary text, and
    /// the Unknown dot is stronger. Backgrounds and accents stay as approved.
    static func increasedContrast(_ colors: [PaletteRole: PaletteColor], _ appearance: Appearance)
        -> [PaletteRole: PaletteColor] {
        let extreme: PaletteColor = appearance == .light ? .black : .white
        var result = colors
        result[.ink] = colors[.ink]!.mixed(with: extreme, 0.6)
        result[.muted] = colors[.muted]!.mixed(with: extreme, 0.45)
        result[.line] = colors[.line]!.mixed(with: colors[.muted]!, 0.5)
        result[.unknown] = colors[.unknown]!.mixed(with: extreme, 0.3)
        for role in [PaletteRole.t1fg, .t2fg, .t3fg, .lunchfg, .breakfg] {
            result[role] = colors[role]!.mixed(with: extreme, 0.4)
        }
        return result
    }

    static func colors(_ palette: Palette, _ appearance: Appearance) -> [PaletteRole: PaletteColor] {
        hex(palette, appearance).mapValues(PaletteColor.init(hex:))
    }

    /// The owner-approved colors (screen 7 of the design canvas, 2026-11-02).
    static func hex(_ palette: Palette, _ appearance: Appearance) -> [PaletteRole: String] {
        switch (palette, appearance) {
        case (.raccoon, .light): [
            .page: "#EDE6DC",
            .bg: "#F7F2EB",
            .chrome: "#EFE7DC",
            .side: "#F2EBE1",
            .surface: "#FFFFFF",
            .ink: "#2B2320",
            .muted: "#6B5E55",
            .line: "#E2D7CA",
            .track: "#E8D2C8",
            .accent: "#A84B34",
            .onAccent: "#FFFFFF",
            .t1bg: "#F6E2D9",
            .t1fg: "#6E2F1E",
            .t2bg: "#E5EDDF",
            .t2fg: "#365C2E",
            .t3bg: "#E2E7F3",
            .t3fg: "#344A80",
            .lunchbg: "#F4E4C7",
            .lunchfg: "#6E4A12",
            .breakbg: "#EFE9E2",
            .breakfg: "#5A4E46",
            .blocked: "#A85F00",
            .ready: "#2E7A4C",
            .unknown: "#8C8079",
        ]
        case (.raccoon, .dark): [
            .page: "#141110",
            .bg: "#1E1A18",
            .chrome: "#25201D",
            .side: "#231E1B",
            .surface: "#2A2421",
            .ink: "#F3ECE4",
            .muted: "#B8ABA0",
            .line: "#3D3430",
            .track: "#4A3A33",
            .accent: "#E58A6F",
            .onAccent: "#1E1A18",
            .t1bg: "#4A2C22",
            .t1fg: "#F6C4B3",
            .t2bg: "#2C3A2A",
            .t2fg: "#BCD9B1",
            .t3bg: "#27304A",
            .t3fg: "#BCC9F0",
            .lunchbg: "#43361F",
            .lunchfg: "#EDCF95",
            .breakbg: "#2F2926",
            .breakfg: "#CBBFB5",
            .blocked: "#F2A541",
            .ready: "#6CCB91",
            .unknown: "#9A8E86",
        ]
        case (.neutral, .light): [
            .page: "#E9E9EA",
            .bg: "#F7F7F7",
            .chrome: "#EFEFF0",
            .side: "#F2F2F3",
            .surface: "#FFFFFF",
            .ink: "#1C1C1E",
            .muted: "#62626A",
            .line: "#DEDEE1",
            .track: "#DDE3EA",
            .accent: "#3B5B7A",
            .onAccent: "#FFFFFF",
            .t1bg: "#E3E9EF",
            .t1fg: "#24405A",
            .t2bg: "#EBEBEB",
            .t2fg: "#3F3F42",
            .t3bg: "#E8E6EF",
            .t3fg: "#454060",
            .lunchbg: "#EFECE6",
            .lunchfg: "#544D3F",
            .breakbg: "#F1F1F2",
            .breakfg: "#5A5A60",
            .blocked: "#8C5E12",
            .ready: "#36694C",
            .unknown: "#898990", // Approved #8A8A90; adjusted for contrast, pending owner approval.
        ]
        case (.neutral, .dark): [
            .page: "#0F0F10",
            .bg: "#18181A",
            .chrome: "#1F1F22",
            .side: "#1C1C1F",
            .surface: "#242427",
            .ink: "#EDEDEF",
            .muted: "#A3A3AA",
            .line: "#36363A",
            .track: "#2E3843",
            .accent: "#93B3D3",
            .onAccent: "#16181B",
            .t1bg: "#26323F",
            .t1fg: "#BCD0E3",
            .t2bg: "#2C2C2E",
            .t2fg: "#D2D2D4",
            .t3bg: "#2E2B38",
            .t3fg: "#CCC6DE",
            .lunchbg: "#33302A",
            .lunchfg: "#DCD4C2",
            .breakbg: "#262628",
            .breakfg: "#BBBBC0",
            .blocked: "#E3B261",
            .ready: "#7FC39C",
            .unknown: "#8E8E95",
        ]
        case (.colorful, .light): [
            .page: "#F6F1EC",
            .bg: "#FFFAF6",
            .chrome: "#FBF4EE",
            .side: "#FAF7FF",
            .surface: "#FFFFFF",
            .ink: "#25213A",
            .muted: "#615B73",
            .line: "#ECE6F2",
            .track: "#E4DEFA",
            .accent: "#6A52D4",
            .onAccent: "#FFFFFF",
            .t1bg: "#EFEBFF",
            .t1fg: "#46349E",
            .t2bg: "#FFECE3",
            .t2fg: "#8A4524",
            .t3bg: "#E0F6EF",
            .t3fg: "#1E5F4E",
            .lunchbg: "#FFF5D6",
            .lunchfg: "#68520F",
            .breakbg: "#F6F3FA",
            .breakfg: "#585170",
            .blocked: "#B4532A",
            .ready: "#2C7656",
            .unknown: "#8D879B",
        ]
        case (.colorful, .dark): [
            .page: "#0F0C1C",
            .bg: "#17142A",
            .chrome: "#1D1933",
            .side: "#1C1832",
            .surface: "#241F3B",
            .ink: "#F4F1FF",
            .muted: "#B7B0CD",
            .line: "#37315A",
            .track: "#3A2F70",
            .accent: "#A693FF",
            .onAccent: "#17142A",
            .t1bg: "#33285F",
            .t1fg: "#D3C9FF",
            .t2bg: "#4A2A1E",
            .t2fg: "#FFC6A8",
            .t3bg: "#173F36",
            .t3fg: "#9FE8CF",
            .lunchbg: "#463A12",
            .lunchfg: "#FFE290",
            .breakbg: "#2A2542",
            .breakfg: "#C7C0DC",
            .blocked: "#FF9A62",
            .ready: "#6EDCA8",
            .unknown: "#958EA8",
        ]
        case (.forest, .light): [
            .page: "#E6EAE3",
            .bg: "#F4F6F1",
            .chrome: "#ECF0E8",
            .side: "#EFF3EC",
            .surface: "#FFFFFF",
            .ink: "#1F2A22",
            .muted: "#5A675D",
            .line: "#DCE3D8",
            .track: "#CFE3D6",
            .accent: "#2F6E4F",
            .onAccent: "#FFFFFF",
            .t1bg: "#DCEDE2",
            .t1fg: "#1F533A",
            .t2bg: "#F1E8D6",
            .t2fg: "#634816",
            .t3bg: "#E0E8F1",
            .t3fg: "#2C4A68",
            .lunchbg: "#F3E6D8",
            .lunchfg: "#674423",
            .breakbg: "#EDF0EA",
            .breakfg: "#56625A",
            .blocked: "#9A5F0E",
            .ready: "#2E7046",
            .unknown: "#828C85", // Approved #87918A; adjusted for contrast, pending owner approval.
        ]
        case (.forest, .dark): [
            .page: "#0E1210",
            .bg: "#151B17",
            .chrome: "#1A221D",
            .side: "#18201B",
            .surface: "#1F2822",
            .ink: "#E9EFEA",
            .muted: "#A7B4AA",
            .line: "#2F3A32",
            .track: "#24402F",
            .accent: "#80C6A0",
            .onAccent: "#141A16",
            .t1bg: "#1F3A2B",
            .t1fg: "#ADDDC1",
            .t2bg: "#3A3020",
            .t2fg: "#E5D1A8",
            .t3bg: "#20303F",
            .t3fg: "#B2CAE2",
            .lunchbg: "#3E2F22",
            .lunchfg: "#E8C5A1",
            .breakbg: "#222B25",
            .breakfg: "#BBC6BE",
            .blocked: "#E8B15C",
            .ready: "#7CCB98",
            .unknown: "#8C978F",
        ]
        case (.system, .light): [
            .page: "#D4D4D6",
            .bg: "#FFFFFF",
            .chrome: "#F3F3F3",
            .side: "#F7F7F8",
            .surface: "#FFFFFF",
            .ink: "#1D1D1F",
            .muted: "#6E6E73",
            .line: "#DCDCDE",
            .track: "#E5E5EA",
            .accent: "#0072EF", // Approved #007AFF; adjusted for contrast, pending owner approval.
            .onAccent: "#FFFFFF",
            .t1bg: "#DCEBFF",
            .t1fg: "#0B3F85",
            .t2bg: "#FFEFD9",
            .t2fg: "#6E3C00",
            .t3bg: "#E3F4E7",
            .t3fg: "#1A5C2C",
            .lunchbg: "#F1ECE6",
            .lunchfg: "#4E3B2B",
            .breakbg: "#F4F4F6",
            .breakfg: "#5E5E63",
            .blocked: "#B25F00",
            .ready: "#1E7B34",
            .unknown: "#8C8C92", // Approved #8E8E93; adjusted for contrast, pending owner approval.
        ]
        case (.system, .dark): [
            .page: "#141416",
            .bg: "#1C1C1E",
            .chrome: "#262628",
            .side: "#212123",
            .surface: "#2A2A2D",
            .ink: "#EFEFF1",
            .muted: "#A3A3A8",
            .line: "#3A3A3D",
            .track: "#34343A",
            .accent: "#3B78C1", // Approved #3F7CC4; adjusted for contrast, pending owner approval.
            .onAccent: "#FFFFFF",
            .t1bg: "#1F3350",
            .t1fg: "#B6CDEE",
            .t2bg: "#1E3A3D",
            .t2fg: "#A5D3D5",
            .t3bg: "#22362B",
            .t3fg: "#ABD2B6",
            .lunchbg: "#3A2E3A",
            .lunchfg: "#E3C6DA",
            .breakbg: "#2C2C2F",
            .breakfg: "#BEBEC3",
            .blocked: "#D9A35A",
            .ready: "#73B98A",
            .unknown: "#96969C",
        ]
        }
    }
}
