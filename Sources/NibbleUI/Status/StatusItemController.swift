import AppKit

/// Nibble's menu bar item: its mark (two spots of light, see `NibbleMark`). A click opens the menu
/// panel, drawn in Nibble's own look (see `MenuPanelController`).
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu: MenuPanelController

    init(interface: Interface) {
        let app = interface.app
        menu = MenuPanelController(app: app, actions: MenuActions(
            newChat: { [unowned interface] in interface.newChat(nil) },
            showPanel: { [unowned interface] in interface.showPanel(nil) },
            openMain: { [unowned interface] in interface.openMain() },
            openPage: { [unowned interface] page in interface.openMain(page) },
            open: { conversation in app.continueInPanel(conversation) },
            quit: { NSApp.terminate(nil) }
        ))
        super.init()
        item.button?.image = Self.glyph()
        item.button?.setAccessibilityLabel("Nibble")
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
    }

    @objc func clicked() {
        guard let button = item.button, let window = button.window else { return }
        let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
        menu.toggle(under: rect)
    }

    var menuIsOpen: Bool { menu.isOpen }

    /// The mark as a template image, 2 pt dots on a 3 pt pitch, centred in the menu bar's 18 pt.
    static func glyph() -> NSImage {
        let pitch: CGFloat = 3
        let dot: CGFloat = 2
        let side: CGFloat = 18
        let origin = ((side - NibbleMark.side(pitch: pitch, dot: dot)) / 2).rounded(.down)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            for (rect, alpha) in NibbleMark.dots(pitch: pitch, dot: dot, origin: CGPoint(x: origin, y: origin)) {
                NSColor.black.withAlphaComponent(alpha).setFill()
                rect.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
