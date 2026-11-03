import AppKit
import ImageIO
import NibbleCore
import ScreenCaptureKit
import ServiceManagement
import UniformTypeIdentifiers

/// The system services the interface uses: capturing the screen without Nibble on it, preparing
/// images for sending (see docs/research/macos-platform.md, "Screen capture" and "Pasting and
/// dropping images"), and opening at login.
@MainActor
public final class SystemServicesProvider: SystemServices {
    /// Images are sent at most this long on their longer side.
    static let maxPixels = 1568

    public init() {}

    public func canCaptureScreen(ask: Bool) -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if ask { CGRequestScreenCaptureAccess() }
        return false
    }

    public func captureScreen(at point: CGPoint) async throws -> PreparedImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = Self.display(at: point)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApp, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = Int(filter.pointPixelScale)
        configuration.width = Int(filter.contentRect.width) * scale
        configuration.height = Int(filter.contentRect.height) * scale
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let prepared = Self.encode(image, as: .png) else { throw CaptureError.encoding }
        return prepared
    }

    public func prepareImage(_ data: Data) -> PreparedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
              type.conforms(to: .image)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Screenshots and drawings stay PNG; photos become JPEG.
        let keepsPNG = type.conforms(to: .png) || type.conforms(to: .gif) || type.conforms(to: .tiff)
        return Self.encode(image, as: keepsPNG ? .png : .jpeg)
    }

    public func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    public func reveal(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Shortcut conflicts

    public func hotKeyConflicts(_ combo: KeyCombo) async -> [HotKeyConflict] {
        var conflicts: [HotKeyConflict] = []
        let symbolic = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys") ?? [:]
        conflicts += HotKeyConflicts.system(combo, symbolicHotKeys: symbolic).map(HotKeyConflict.system)
        if let common = CommonShortcut.matching(combo) { conflicts.append(.common(common)) }
        let own = Bundle.main.bundleIdentifier.map { $0.hasSuffix(".dev") ? String($0.dropLast(4)) : $0 } ?? "com.glimmer.Nibble"
        let bundleIDs = await Task.detached { HotKeyConflicts.apps(combo, excluding: own) }.value
        for id in bundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let name = FileManager.default.displayName(atPath: url.path(percentEncoded: false))
            conflicts.append(.app(name.hasSuffix(".app") ? String(name.dropLast(4)) : name))
        }
        if conflicts.isEmpty, GlobalHotKey.isTaken(combo) { conflicts.append(.taken) }
        return conflicts
    }

    // MARK: - Opening at login

    /// The login item is the app itself (`SMAppService.mainApp`), listed under Open at Login in
    /// System Settings, where the reader can also remove it.
    public var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    public func setOpensAtLogin(_ on: Bool) throws {
        if on {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    // MARK: - Helpers

    private static func display(at point: CGPoint) -> CGDirectDisplayID? {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        return screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Scales an image down to `maxPixels` and encodes it in sRGB.
    static func encode(_ image: CGImage, as type: UTType) -> PreparedImage? {
        var image = image
        let longer = max(image.width, image.height)
        if longer > maxPixels {
            let factor = Double(maxPixels) / Double(longer)
            let width = Int(Double(image.width) * factor)
            let height = Int(Double(image.height) * factor)
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            image = scaled
        } else if let srgb = image.copy(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) {
            image = srgb
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return PreparedImage(data: data as Data, mediaType: type == .jpeg ? "image/jpeg" : "image/png")
    }

    enum CaptureError: LocalizedError {
        case noDisplay
        case encoding

        var errorDescription: String? {
            switch self {
            case .noDisplay: "No display to capture."
            case .encoding: "The capture could not be saved."
            }
        }
    }
}
