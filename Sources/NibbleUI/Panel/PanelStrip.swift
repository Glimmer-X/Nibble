import AppKit
import NibbleCore
import SwiftUI

/// The chat folded into its strip, at the chat's top right corner: the send key's display showing
/// what the reply is doing, the status line, Allow and Deny while the reply asks, then unfold and
/// close where the header's collapse and close keys were. A click anywhere else unfolds the chat; a
/// drag moves the strip. The board behind plays the panel's own light, in the strip's shapes.
struct PanelStrip: View {
    @Environment(PanelModel.self) private var model

    /// Four cells, the key's 32 pt with a little room above and below.
    static let height: CGFloat = 40
    /// Room kept after the words while the reply asks, where the cursor's light stands.
    static let caretGap: CGFloat = 12
    /// From the end of the words to the cursor's middle: half the room between them and Allow.
    static let caretOffset = Double(caretGap + 16) / 2
    /// The places the board's light starts from (the key) and stands at (after the words).
    static let keyAnchor = "strip-key"
    static let textAnchor = "strip-text"

    var body: some View {
        let colors = model.colors
        let s = model.strings
        let session = model.session
        let asking = if case .attention = session.phase { true } else { false }
        let failed = !session.isResponding && session.lastReply?.isFailed == true
        HStack(spacing: 8) {
            KeyDisplayView(dots: model.keyDots)
                .frame(width: 32, height: 32)
                .litKey(session.isResponding, colors: colors)
                .foregroundStyle(session.isResponding ? colors.onAccent : failed ? colors.rose : colors.ink3)
                .boardAnchor(Self.keyAnchor)
                .allowsHitTesting(false)
            TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
                Text(model.stripLine(at: timeline.date))
                    .pixelText()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(failed ? colors.rose : colors.ink)
                    .boardAnchor(Self.textAnchor)
            }
            .allowsHitTesting(false)
            Spacer(minLength: asking ? Self.caretGap : 0)
            if asking {
                TextKey(id: "strip-allow", title: s.allow, place: .strip) { model.answer(.allow) }
                TextKey(id: "strip-deny", title: s.deny, place: .strip) { model.answer(.deny) }
            }
            IconKey(id: "strip-expand", icon: .expand, label: s.expand, place: .strip) { model.expand() }
            IconKey(id: "strip-close", icon: .close, label: s.close, place: .strip) { model.controller?.dismiss() }
        }
        .padding(.leading, 4)
        .padding(.trailing, 16)
        .frame(width: Self.size(s).width, height: Self.height)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Size

    @MainActor private static var sizes: [String: CGSize] = [:]

    /// As wide as the line it shows while the reply asks needs (its words, the cursor's room, Allow
    /// and Deny) beside the key and the two keys at the end, in whole cells, at least 28.
    @MainActor static func size(_ s: Strings) -> CGSize {
        let key = "\(Typeface.size)-\(s.language)"
        if let size = sizes[key] { return size }
        let font = NSFont(name: Typeface.pixelName, size: Typeface.pixelSize) ?? .systemFont(ofSize: Typeface.pixelSize)
        func width(_ text: String) -> CGFloat {
            NSAttributedString(string: text, attributes: [.font: font]).size().width.rounded(.up)
        }
        // Leading 4, the key, the words, the cursor's room, Allow and Deny (8 pt inside each side),
        // the two keys, trailing 16, and 8 between each.
        let parts: [CGFloat] = [32, width(s.needsOK), caretGap, width(s.allow) + 16, width(s.deny) + 16, 32, 32]
        let total = 4 + parts.reduce(0, +) + 8 * CGFloat(parts.count - 1) + 16
        let size = CGSize(width: max(280, (total / 10).rounded(.up) * 10), height: height)
        sizes[key] = size
        return size
    }
}
