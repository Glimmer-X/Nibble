import Foundation

/// What the interface asks of the system: a picture of the screen, images ready to send, opening
/// at login.
/// NibbleSystem implements it; the panel only sees this protocol.
@MainActor
public protocol SystemServices: AnyObject {
    /// Whether Nibble may capture the screen. Asking may show the system's prompt.
    func canCaptureScreen(ask: Bool) -> Bool
    /// The display under `point` (global screen coordinates, origin bottom left) without Nibble's
    /// own windows, as an image ready to send.
    func captureScreen(at point: CGPoint) async throws -> PreparedImage
    /// An image file's bytes, scaled down and re-encoded for sending; nil if it is not an image.
    func prepareImage(_ data: Data) -> PreparedImage?
    /// Opens System Settings where the reader allows screen capture.
    func openScreenCaptureSettings()
    /// Shows a file or folder in Finder.
    func reveal(_ url: URL)
    /// What else answers this key combination (see `HotKeyConflict`).
    func hotKeyConflicts(_ combo: KeyCombo) async -> [HotKeyConflict]
    /// Whether Nibble opens when the reader logs in.
    var opensAtLogin: Bool { get }
    /// Adds Nibble to the login items, or removes it.
    func setOpensAtLogin(_ on: Bool) throws
}

public struct PreparedImage: Sendable {
    public let data: Data
    public let mediaType: String

    public init(data: Data, mediaType: String) {
        self.data = data
        self.mediaType = mediaType
    }
}
