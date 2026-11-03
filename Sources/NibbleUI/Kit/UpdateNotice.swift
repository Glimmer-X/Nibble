import NibbleCore
import SwiftUI

/// The notice of a newer version: a line on a plate of rose cells that a band of light runs
/// across every few seconds, with a key to the release's download page and one to dismiss it.
/// Dismissed, it leaves every window at once and stays away until the next version, or until the
/// reader checks again in settings.
///
/// It shows at the top of the panel's conversation page, the menu bar panel and settings; the
/// keys that lead to the first and last carry an `UpdateLamp`.
struct UpdateNotice: View {
    @Environment(AppModel.self) private var app
    let release: Release
    /// Names its plate and keys on the board.
    let id: String
    let place: LightRegistry.Place

    static var height: CGFloat { max(36, Typeface.keyHeight + 12) }

    var body: some View {
        let s = app.strings
        HStack(spacing: 0) {
            Text(s.newVersion(release.version.description))
                .pixelText()
                .foregroundStyle(app.colors.rose)
                .lineLimit(1)
            Spacer(minLength: 8)
            TextKey(id: "\(id)-download", title: s.download, place: place) { app.openRelease() }
            TextKey(id: "\(id)-ignore", title: s.ignore, place: place) {
                withAnimation(.easeOut(duration: 0.2)) { app.updates.ignore() }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: Self.height)
        .boardPlate("\(id)-plate", rose: true, page: place.page, clip: place.clip, glint: true)
        .transition(.opacity)
    }
}

/// One rose cell beside a key, while a newer version waits behind it.
struct UpdateLamp: View {
    @Environment(AppModel.self) private var app
    let id: String
    var page = "main"

    var body: some View {
        if app.updates.notice != nil {
            Color.clear
                .frame(width: 9, height: 9)
                .boardLamp(id, value: 0.6, rose: true, page: page, clip: nil)
                .allowsHitTesting(false)
        }
    }
}
