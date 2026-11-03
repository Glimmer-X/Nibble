import SwiftUI

/// The colours text and controls use, from the palette.
struct PanelColors {
    let ink: Color
    let ink2: Color
    let ink3: Color
    let accent: Color
    let pink: Color
    let onAccent: Color
    let rose: Color
    let code: Color
    let ground: Color
    /// The hairline just inside the panel's edge.
    let rim: Color

    init(_ p: Palette) {
        ink = p.t[4].color
        ink2 = p.t[3].color
        ink3 = p.t[2].color
        accent = p.accent.color
        pink = p.pink.color
        onAccent = p.onAccent.color
        rose = p.roseText.color
        code = p.t[4].mixed(with: p.accent, 0.5).color
        ground = p.ground.color
        rim = p.appearance == .dark ? Color.white.opacity(0.07) : Color(.sRGB, red: 40 / 255, green: 20 / 255, blue: 90 / 255).opacity(0.08)
    }
}

/// A 32 pt key with a dot-matrix icon; its light is a round glow on the board.
struct IconKey: View {
    @Environment(AppModel.self) private var model
    let id: String
    let icon: DotIcon
    let label: String
    var place: LightRegistry.Place = .chat
    var pressed = false
    var size: CGFloat = 32
    /// How bright the icon is at rest (it lights fully under the pointer).
    var rest = 0.72
    /// A colour of its own (rose for a key that is about to delete something).
    var tint: Color?
    let action: () -> Void
    @State private var hot = false

    var body: some View {
        let colors = model.colors
        Button(action: action) {
            DotIconView(icon: icon)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? (hot || pressed ? colors.ink : colors.ink.opacity(rest)))
        .onHover { hot = $0 }
        .boardLight(id, .key, in: place, pressed: pressed)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A small text button in the pixel face (copy, retry, allow); its light is a feathered glow.
struct TextKey: View {
    @Environment(AppModel.self) private var model
    let id: String
    let title: String
    var place: LightRegistry.Place = .log
    /// A colour of its own (rose for a key that is about to delete something).
    var tint: Color?
    let action: () -> Void
    @State private var hot = false

    var body: some View {
        let colors = model.colors
        Button(action: action) {
            Text(title)
                .pixelText()
                .padding(.horizontal, 8)
                .frame(height: Typeface.keyHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? (hot ? colors.ink : colors.ink2))
        .onHover { hot = $0 }
        .boardLight(id, .segment, in: place)
    }
}

/// One choice of a group: the chosen one is a lit chip, so it stands out at a glance.
struct Choice: View {
    @Environment(AppModel.self) private var model
    let id: String
    let title: String
    let selected: Bool
    var place: LightRegistry.Place = .main("body")
    /// A small lit square of a colour beside the title (the colour choices).
    var swatch: Color?
    let action: () -> Void
    @State private var hot = false

    var body: some View {
        let colors = model.colors
        Button(action: action) {
            HStack(spacing: 6) {
                if let swatch { Rectangle().fill(swatch).frame(width: 8, height: 8) }
                Text(title).pixelText().lineLimit(1)
            }
                .padding(.horizontal, 8)
                .frame(height: Typeface.keyHeight)
                .background(selected ? colors.accent.opacity(0.36) : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected || hot ? colors.ink : colors.ink2)
        .onHover { hot = $0 }
        .boardLight(id, .segment, in: place, pressed: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// An on/off switch drawn as a dot display, like the send key's: a 3 × 3 knob of dots that slides
/// along a track of faint dots, lit in the accent when on.
struct DotSwitch: View {
    @Environment(AppModel.self) private var model
    let id: String
    let isOn: Bool
    let label: String
    var place: LightRegistry.Place = .main("body")
    let action: () -> Void
    /// The knob's column while it slides; nil when it rests at an end.
    @State private var sliding: Int?
    @State private var hot = false

    private static let columns = 7
    private static let knob = 3

    var body: some View {
        let colors = model.colors
        let end = Self.columns - Self.knob
        let column = sliding ?? (isOn ? end : 0)
        let knobColor = isOn ? colors.accent : (hot ? colors.ink : colors.ink2)
        let track = (isOn ? colors.accent : colors.ink).opacity(isOn ? 0.3 : 0.16)
        Button(action: action) {
            Canvas { context, _ in
                for c in 0..<Self.columns {
                    for r in 0..<3 {
                        let dot = Path(CGRect(x: CGFloat(c) * 4, y: CGFloat(r) * 4, width: 3, height: 3))
                        context.fill(dot, with: .color(c >= column && c < column + Self.knob ? knobColor : track))
                    }
                }
            }
            .frame(width: CGFloat(Self.columns) * 4 - 1, height: 11)
            .padding(.horizontal, 8)
            .frame(height: Typeface.keyHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hot = $0 }
        .onChange(of: isOn) { old, new in slide(from: old ? end : 0, to: new ? end : 0) }
        .boardLight(id, .segment, in: place)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "1" : "0")
        .accessibilityAddTraits(.isToggle)
    }

    /// The knob steps from dot to dot, as the board's light moves cell by cell.
    private func slide(from: Int, to: Int) {
        Task { @MainActor in
            let step = to > from ? 1 : -1
            var c = from
            while c != to {
                c += step
                sliding = c
                try? await Task.sleep(for: .milliseconds(30))
            }
            sliding = nil
        }
    }
}

extension View {
    /// Text on the 24 pt rhythm: a 14 pt system line is about 17 pt, so the extra goes half above,
    /// half below, and between lines.
    func rhythm(fontSize: CGFloat? = nil, line: CGFloat? = nil) -> some View {
        let font = NSFont.systemFont(ofSize: fontSize ?? Typeface.messageSize)
        let line = line ?? Typeface.line
        let natural = (font.ascender - font.descender + font.leading).rounded(.up)
        let extra = max(0, line - natural)
        return lineSpacing(extra).padding(.vertical, extra / 2)
    }
}

/// Lays its children out in lines, left to right, starting a new line when one is full.
struct Flow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let frames = place(subviews, width: width)
        let right = frames.map(\.maxX).max() ?? 0
        let bottom = frames.map(\.maxY).max() ?? 0
        return CGSize(width: proposal.width ?? right, height: bottom)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, place(subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += line + lineSpacing
                line = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            line = max(line, size.height)
        }
        return frames
    }
}
