import AppKit

/// The panel's content view. Its origin is at the top left, so the board stays pinned to the
/// panel's top edge while the height changes. It is also where images are dropped, anywhere on the
/// panel: the composer hands the image drags it gets here (see `ComposerTextView`), so one place
/// takes them in every form `ImageIntake` reads and lights the board where they are.
final class PanelContentView: NSView {
    /// Whether an image may be dropped now (not on the strip).
    var accepts: () -> Bool = { true }
    /// Where an image is dragged over the panel (points from its top left); nil once it has gone,
    /// landed or the drag has ended.
    var onHover: (CGPoint?) -> Void = { _ in }
    var onImages: @MainActor @Sendable ([ImageIntake.Item]) -> Void = { _ in }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(ImageIntake.draggedTypes)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { follow(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { follow(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) { onHover(nil) }

    override func draggingEnded(_ sender: NSDraggingInfo) { onHover(nil) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        accepts() && ImageIntake.carriesImages(sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHover(nil)
        return ImageIntake.read(sender.draggingPasteboard, deliver: onImages)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { onHover(nil) }

    private func follow(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(), ImageIntake.carriesImages(sender.draggingPasteboard) else {
            onHover(nil)
            return []
        }
        onHover(convert(sender.draggingLocation, from: nil))
        return .copy
    }
}
