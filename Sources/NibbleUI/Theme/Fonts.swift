import AppKit
import CoreText
import NibbleCore
import Observation
import SwiftUI

/// The panel's type: Fusion Pixel 12 (OFL, bundled) for labels, controls and the status line, and
/// its 10 px cut for a smaller second line; the system face for messages (14/24) and the input
/// (15/24); a monospace face for code.
@MainActor
enum Typeface {
    static let pixelName = "Fusion-Pixel-12px-Prop-zh-Hans-Regular"
    static let pixelSmallName = "Fusion-Pixel-10px-Prop-zh-Hans-Regular"

    /// Registers the bundled pixel fonts for this process. Safe to call more than once.
    @MainActor static func register() {
        guard !registered else { return }
        registered = true
        for name in ["fusion-pixel-12px-proportional-zh_hans.otf", "fusion-pixel-10px-proportional-zh_hans.otf"] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "woff2") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    @MainActor private static var registered = false

    /// The reader's text size (a setting).
    static var size: TextSize { TextScale.shared.size }

    /// How much larger reading text is than at the small size: 14, 16 or 18 pt messages.
    static var factor: CGFloat {
        switch size {
        case .small: 1
        case .medium: 16.0 / 14
        case .large: 18.0 / 14
        }
    }

    static var messageSize: CGFloat { 14 * factor }
    static var inputSize: CGFloat { (15 * factor * 2).rounded() / 2 }
    static var codeSize: CGFloat { (12.5 * factor * 2).rounded() / 2 }
    static var headingSize: CGFloat { (15 * factor * 2).rounded() / 2 }
    static var tableSize: CGFloat { (13 * factor * 2).rounded() / 2 }

    static var message: Font { .system(size: messageSize) }
    static var code: Font { .system(size: codeSize, design: .monospaced) }
    static var heading: Font { .system(size: headingSize, weight: .semibold) }
    static var table: Font { .system(size: tableSize) }

    /// The text rhythm: every line of message text is 24 pt at the small size.
    static var line: CGFloat { (24 * factor).rounded() }

    /// The empty bar's height: six cells at the small and medium sizes, seven at the large, where
    /// the input's line would crowd six.
    static var barHeight: CGFloat { size == .large ? 70 : 60 }

    /// The pixel face: 12 pt at the small size (two device pixels a face pixel on a Retina
    /// screen), 15 at the medium, 18 at the large (three).
    static var pixelSize: CGFloat {
        switch size {
        case .small: 12
        case .medium: 15
        case .large: 18
        }
    }
    static var pixel: Font { .custom(pixelName, fixedSize: pixelSize) }
    /// The 10 px cut for a second, smaller line (the persona under the service): 10 pt at the small
    /// size, growing with the labels.
    static var pixelSmall: Font { .custom(pixelSmallName, fixedSize: pixelSize * 10 / 12) }
    /// Section titles: half as large again as the labels, then a little less as they grow.
    static var pixelSection: Font { .custom(pixelName, fixedSize: 18 + (pixelSize - 12)) }
    /// Page titles: twice the labels.
    static var pixelLarge: Font { .custom(pixelName, fixedSize: 2 * pixelSize) }
    /// Keys and chips that hold a pixel label.
    static var keyHeight: CGFloat { 12 + pixelSize }
    /// A settings row.
    static var rowHeight: CGFloat { 40 + (pixelSize - 12) * 4 / 3 }
    /// The settings' column of row names.
    static var rowLabelWidth: CGFloat { 96 + (pixelSize - 12) * 8 }
}

/// The reader's text size, observed: views that read `Typeface` while drawing redraw when it
/// changes, in place.
@MainActor
@Observable
final class TextScale {
    static let shared = TextScale()
    var size: TextSize = .small
}

extension View {
    /// A pixel label. The face's own line is 16 px (ascent 13, descent 3).
    func pixelText() -> some View {
        font(Typeface.pixel)
    }
}
