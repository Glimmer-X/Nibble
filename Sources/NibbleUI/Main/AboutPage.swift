import AppKit
import SwiftUI

/// About: Nibble's card on a plate of lit cells, with the icon, the name, what Nibble is and the
/// version. Opened from the foot of the sidebar or the app menu.
struct AboutPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.strings
        let colors = model.colors
        let version = model.version
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 28) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Nibble").font(Typeface.pixelLarge)
                    Text(s.tagline)
                        .font(Typeface.message)
                        .rhythm()
                        .foregroundStyle(colors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(s.version(version.version, build: version.build)).pixelText().foregroundStyle(colors.ink3)
                }
            }
            .padding(28)
            .frame(maxWidth: 560, alignment: .leading)
            .boardPlate("about", page: "main", clip: nil)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
