import NibbleCore
import SwiftUI

/// A colour in OKLab: lightness, and the two opponent axes.
struct OKLab: Equatable, Sendable {
    var L: Double
    var a: Double
    var b: Double

    /// An OKLCH colour: lightness, chroma, hue in degrees.
    static func lch(_ L: Double, _ C: Double, _ h: Double) -> OKLab {
        let r = h * .pi / 180
        return OKLab(L: L, a: C * cos(r), b: C * sin(r))
    }

    /// Straight interpolation in OKLab.
    func mixed(with q: OKLab, _ t: Double) -> OKLab {
        OKLab(L: L + (q.L - L) * t, a: a + (q.a - a) * t, b: b + (q.b - b) * t)
    }

    /// A cell lit to `t` (0–1) toward `ink`: lightness moves in step with t, colour comes in sooner
    /// (by `bloom` < 1), so dim light stays a saturated violet instead of going grey.
    static func glow(_ unlit: OKLab, _ ink: OKLab, _ t: Double, bloom: Double) -> OKLab {
        let c = pow(t, bloom)
        return OKLab(L: unlit.L + (ink.L - unlit.L) * t, a: unlit.a + (ink.a - unlit.a) * c, b: unlit.b + (ink.b - unlit.b) * c)
    }

    /// The same colour with its hue turned by `angle` radians.
    func rotated(_ angle: Double) -> OKLab {
        OKLab(L: L, a: a * cos(angle) - b * sin(angle), b: a * sin(angle) + b * cos(angle))
    }

    /// sRGB, gamma-encoded, each channel 0–255.
    var rgb8: SIMD3<UInt8> {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.291485548 * b, 3)
        let linear = [
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s,
        ]
        let encoded = linear.map { x -> UInt8 in
            let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
            return UInt8((min(1, max(0, v)) * 255).rounded())
        }
        return SIMD3(encoded[0], encoded[1], encoded[2])
    }

    var color: Color {
        let c = rgb8
        return Color(.sRGB, red: Double(c.x) / 255, green: Double(c.y) / 255, blue: Double(c.z) / 255)
    }

    var nsColor: NSColor {
        let c = rgb8
        return NSColor(srgbRed: CGFloat(c.x) / 255, green: CGFloat(c.y) / 255, blue: CGFloat(c.z) / 255, alpha: 1)
    }
}

/// Light or dark: the board and the text follow the system unless the reader picks one.
enum Appearance: String, Sendable {
    case light
    case dark
}

/// The hues of one colour theme: the base hue, the turn (degrees) to the hot end of the board's hue
/// axis, and the accent's lightness and chroma in each appearance.
struct ThemeHues: Sendable {
    let hue: Double
    let turn: Double
    let dark: (L: Double, C: Double)
    let light: (L: Double, C: Double)
}

extension ColorTheme {
    /// Violet is Nibble's own (hue 284, turning 72° to a rose). The others were picked from a study
    /// of each hue's full set of board fills: each turns toward a neighbour that keeps the lit cells
    /// clean (teal toward blue, orange toward red, amber toward orange), with the accent's chroma
    /// kept inside the sRGB gamut at its lightness. Green was left out: every path from it went muddy.
    var hues: ThemeHues {
        switch self {
        case .violet: ThemeHues(hue: 284, turn: 72, dark: (0.72, 0.155), light: (0.47, 0.17))
        case .teal: ThemeHues(hue: 195, turn: 70, dark: (0.78, 0.1134), light: (0.5, 0.0731))
        case .blue: ThemeHues(hue: 252, turn: 60, dark: (0.7, 0.1377), light: (0.48, 0.1235))
        case .rose: ThemeHues(hue: 350, turn: 30, dark: (0.74, 0.1523), light: (0.5, 0.1681))
        case .orange: ThemeHues(hue: 55, turn: -35, dark: (0.74, 0.1551), light: (0.55, 0.1168))
        case .amber: ThemeHues(hue: 82, turn: -42, dark: (0.82, 0.1355), light: (0.58, 0.0963))
        }
    }
}

/// Nibble's colour in every shade a panel needs for one appearance.
///
/// Each lit cell's hue sits on one axis from the theme's hue through its bright lean to a hot end:
/// for Violet (hue 284 at 0.86 of the trial saturation) that is violet, pink (318), rose (356). The
/// brightest light leans along the axis, and warmth (a failed request, a fast answer) turns lit
/// cells toward its end. Defined in OKLCH, mixed in OKLab, handed out as sRGB, so the board's cells
/// and the text use the same values.
struct Palette: Equatable, Sendable {
    static let chroma = 1.1
    static let defaultSaturation = 0.86

    let appearance: Appearance
    let theme: ColorTheme
    let saturation: Double
    /// The tonal ramp: t[0] is the ground, t[4] the strongest ink.
    let t: [OKLab]
    let accent: OKLab
    let onAccent: OKLab
    /// The board behind the cells (in dark it sits a little above t[0], so the panel keeps its edge
    /// on a dark desktop).
    let ground: OKLab
    /// The colour the board is muted toward: a dark haze in dark mode, a pale one in light mode.
    let veil: OKLab
    /// An error message: a quiet rose.
    let roseText: OKLab
    /// The colour of warnings and errors on the board (a plate under an error, a conflict's lamp):
    /// Violet's rose, a red for the other themes, so a warning reads as one whatever the theme.
    let alert: OKLab
    /// The accent turned toward its pink.
    let pink: OKLab
    /// Radians from the accent's hue to the rose at the warm end of the board's hue axis.
    let roseTurn: Double

    init(_ appearance: Appearance, theme: ColorTheme = .violet, saturation: Double = Palette.defaultSaturation) {
        self.appearance = appearance
        self.theme = theme
        self.saturation = saturation
        let hues = theme.hues
        let hue = hues.hue
        // Violet's accent chroma follows the saturation knob; the others were fitted at 0.86.
        let accentScale = theme == .violet ? saturation : saturation / Palette.defaultSaturation
        let k = Self.chroma * saturation
        let ramp: (L: [Double], C: [Double]) = appearance == .light
            ? ([0.975, 0.92, 0.76, 0.5, 0.2], [0.014, 0.03, 0.06, 0.08, 0.06])
            : ([0.15, 0.24, 0.41, 0.72, 0.95], [0.03, 0.04, 0.06, 0.07, 0.02])
        let t = zip(ramp.L, ramp.C).map { OKLab.lch($0, $1 * k, hue) }
        self.t = t
        let (aL, aC) = appearance == .light ? hues.light : hues.dark
        accent = OKLab.lch(aL, aC * accentScale, hue)
        let degree = Double.pi / 180
        roseTurn = hues.turn * degree
        // The bright lean sits a little under half way along the axis (Violet's pink, 318°).
        pink = accent.rotated(hues.turn * 34 / 72 * degree * 0.7)
        onAccent = appearance == .light ? .lch(0.985, 0.01, hue) : .lch(0.17, 0.04 * saturation, hue)
        ground = appearance == .light ? t[0] : t[0].mixed(with: t[1], 0.3)
        veil = appearance == .light ? .lch(0.99, 0.004, hue) : .lch(0.07, 0.02 * saturation, hue)
        let alertHue = theme == .violet ? hue + hues.turn : 22
        roseText = appearance == .light ? .lch(0.45, 0.13 * saturation, alertHue) : .lch(0.84, 0.08 * saturation, alertHue)
        alert = appearance == .light ? .lch(0.5, 0.16 * saturation, alertHue) : .lch(0.68, 0.15 * saturation, alertHue)
    }
}
