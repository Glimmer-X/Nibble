import AppKit
import SwiftUI

/// The composer's text field: an `NSTextView`, because SwiftUI's text editors cannot take a pasted
/// image and do not say where the caret is. Return sends and Shift-Return starts a new line, or,
/// with `sendsWithCommand`, ⌘Return sends and Return starts a new line. Return that confirms an
/// input method's candidate does neither.
struct ComposerInput: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let color: NSColor
    let caret: NSColor
    let focusRequest: Int
    /// ⌘Return sends instead of Return.
    var sendsWithCommand = false
    /// The number of lines the text takes (1 or more).
    let onLines: (Int) -> Void
    let onSubmit: () -> Void
    /// A character was typed; the caret's middle in window coordinates (origin bottom left).
    let onType: (NSPoint) -> Void
    let onImages: @MainActor @Sendable ([ImageIntake.Item]) -> Void
    /// An input method is composing (marked text not yet committed), or has stopped.
    var onComposing: (Bool) -> Void = { _ in }

    static var line: CGFloat { Typeface.line }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder

        let view = ComposerTextView()
        view.delegate = context.coordinator
        view.coordinator = context.coordinator
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        scroll.documentView = view
        apply(to: view)
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ComposerTextView else { return }
        context.coordinator.parent = self
        apply(to: view)
        if view.string != text, !view.hasMarkedText() {
            view.string = text
            // Not during this update: SwiftUI drops state changed while it updates views, and the
            // field would keep the height of the text it held (a long draft, sent or cleared).
            let coordinator = context.coordinator
            DispatchQueue.main.async { coordinator.reportLines(view) }
        }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    private func apply(to view: NSTextView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Self.line
        paragraph.maximumLineHeight = Self.line
        let offset = (Self.line - (font.ascender - font.descender)) / 2 - 1
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph, .baselineOffset: offset,
        ]
        view.typingAttributes = attributes
        view.defaultParagraphStyle = paragraph
        view.insertionPointColor = caret
        if let storage = view.textStorage, storage.length > 0, !view.hasMarkedText() {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerInput
        var focusRequest = -1
        private var lines = 1

        init(_ parent: ComposerInput) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            if parent.text != view.string { parent.text = view.string }
            reportLines(view)
        }

        func reportLines(_ view: NSTextView) {
            guard let manager = view.layoutManager, let container = view.textContainer else { return }
            manager.ensureLayout(for: container)
            let height = manager.usedRect(for: container).height
            let count = max(1, Int((height / ComposerInput.line).rounded()))
            if count != lines {
                lines = count
                parent.onLines(count)
            }
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                // With ⌘Return as the send key, a plain Return starts a new line.
                if parent.sendsWithCommand || NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false }
                parent.onSubmit()
                return true
            }
            return false
        }

        /// ⌘Return, when it is the send key.
        func commandReturn() -> Bool {
            guard parent.sendsWithCommand else { return false }
            parent.onSubmit()
            return true
        }

        func markedTextChanged(_ view: NSTextView) {
            parent.onComposing(view.hasMarkedText())
        }

        /// A character went in, or an input method's unfinished text changed: the board lights the
        /// cells at the caret.
        func typed(_ view: NSTextView) {
            let range = view.selectedRange()
            let rect = view.firstRect(forCharacterRange: range, actualRange: nil)
            guard let window = view.window, rect != .zero else { return }
            let inWindow = window.convertFromScreen(rect)
            parent.onType(NSPoint(x: inWindow.minX, y: inWindow.midY))
        }
    }
}

/// The text view: tells the board about each typed character and takes pasted images.
///
/// Only the text itself is for selecting and editing. A press on the field's empty part (all of
/// it while nothing is typed) moves the panel when dragged; a click there puts the caret at the
/// nearest place.
final class ComposerTextView: NSTextView {
    weak var coordinator: ComposerInput.Coordinator?
    private var grab: WindowGrab?
    private var pressedAt = NSPoint.zero

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let window, !hasMarkedText(), !isOverText(point) else { return super.mouseDown(with: event) }
        grab = WindowGrab(window, event)
        pressedAt = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grab else { return super.mouseDragged(with: event) }
        grab.follow(event)
    }

    override func mouseUp(with event: NSEvent) {
        guard let grab else { return super.mouseUp(with: event) }
        self.grab = nil
        guard !grab.moved else { return }
        window?.makeKey()
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: pressedAt), length: 0))
    }

    /// Whether `point` (view coordinates) is on a line of text, or within a few points of it.
    func isOverText(_ point: NSPoint) -> Bool {
        guard !string.isEmpty, let manager = layoutManager, let container = textContainer else { return false }
        let origin = textContainerOrigin
        let p = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        var hit = false
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, used, _, _, stop in
            if used.insetBy(dx: -8, dy: -2).contains(p) {
                hit = true
                stop.pointee = true
            }
        }
        return hit
    }

    override func keyDown(with event: NSEvent) {
        let returnKey = event.keyCode == 36 || event.keyCode == 76
        if returnKey, event.modifierFlags.contains(.command), !hasMarkedText(), coordinator?.commandReturn() == true { return }
        super.keyDown(with: event)
        // The input method's candidates come with the key.
        (window as? FloatingPanel)?.followInputMethod()
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        // Caps Lock shows the input source badge at the caret.
        (window as? FloatingPanel)?.followInputMethod()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let returnKey = event.keyCode == 36 || event.keyCode == 76
        if returnKey, event.modifierFlags.contains(.command), window?.firstResponder === self, !hasMarkedText(),
           coordinator?.commandReturn() == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        coordinator?.typed(self)
        coordinator?.markedTextChanged(self)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        // An input method takes several keys for one character (pinyin, kana): each key it turns
        // into unfinished text lights the board too, not only the character that finally goes in.
        let length = (string as? NSAttributedString)?.length ?? (string as? String)?.utf16.count ?? 0
        if length > 0 { coordinator?.typed(self) }
        coordinator?.markedTextChanged(self)
    }

    override func unmarkText() {
        super.unmarkText()
        coordinator?.markedTextChanged(self)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + ImageIntake.dataTypes + super.readablePasteboardTypes
    }

    /// Pasting: images become attachments; anything else pastes as text.
    override func paste(_ sender: Any?) {
        if let onImages = coordinator?.parent.onImages, ImageIntake.read(.general, deliver: onImages) { return }
        pasteAsPlainText(sender)
    }

    // MARK: - Images dragged onto the field

    // An image dragged here goes where the rest of the panel takes it, never into the text as a
    // file's path; text dragged here goes into the text as usual.

    private func imageTarget(_ sender: NSDraggingInfo?) -> PanelContentView? {
        guard let sender, ImageIntake.carriesImages(sender.draggingPasteboard) else { return nil }
        return window?.contentView as? PanelContentView
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageTarget(sender)?.draggingEntered(sender) ?? super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        imageTarget(sender)?.draggingUpdated(sender) ?? super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard let target = imageTarget(sender) else { return super.draggingExited(sender) }
        target.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        imageTarget(sender)?.prepareForDragOperation(sender) ?? super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        imageTarget(sender)?.performDragOperation(sender) ?? super.performDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        guard let target = imageTarget(sender) else { return super.concludeDragOperation(sender) }
        target.concludeDragOperation(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        guard let target = imageTarget(sender) else { return super.draggingEnded(sender) }
        target.draggingEnded(sender)
    }
}
