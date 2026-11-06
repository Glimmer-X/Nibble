import AppKit
import UniformTypeIdentifiers

/// Images handed to the panel, pasted or dropped, in each form apps hand them over: image files
/// (Finder), files the source app writes only once the drop lands (the screenshot thumbnail,
/// Photos), and image data (a browser, a copied screenshot).
enum ImageIntake {
    struct Item: Sendable {
        let data: Data
        let name: String?
    }

    static let dataTypes: [NSPasteboard.PasteboardType] = [.png, .init("public.jpeg"), .init("public.heic"), .tiff]

    /// The types a drop target registers for.
    static var draggedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } + dataTypes
    }

    /// Whether the pasteboard holds an image in one of those forms. Files that are not images
    /// make it hold none: a file copied in Finder also carries its icon as image data.
    static func carriesImages(_ board: NSPasteboard) -> Bool {
        let urls = fileURLs(board)
        if !urls.isEmpty { return urls.contains(where: isImage) }
        return !promises(board).isEmpty || board.availableType(from: dataTypes) != nil
    }

    /// Hands over the pasteboard's images: files and data at once, promised files once their app
    /// has written them (into a folder of their own that is removed after). False when it holds no
    /// image.
    @MainActor @discardableResult
    static func read(_ board: NSPasteboard, deliver: @escaping @MainActor @Sendable ([Item]) -> Void) -> Bool {
        let urls = fileURLs(board)
        if !urls.isEmpty {
            let items = urls.filter(isImage).compactMap { url in
                (try? Data(contentsOf: url)).map { Item(data: $0, name: url.lastPathComponent) }
            }
            guard !items.isEmpty else { return false }
            deliver(items)
            return true
        }
        let promised = promises(board)
        if !promised.isEmpty {
            receive(promised, deliver)
            return true
        }
        guard let type = board.availableType(from: dataTypes), let data = board.data(forType: type) else { return false }
        deliver([Item(data: data, name: nil)])
        return true
    }

    // MARK: - Forms

    private static func fileURLs(_ board: NSPasteboard) -> [URL] {
        (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    private static func isImage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) ?? false
    }

    private static func promises(_ board: NSPasteboard) -> [NSFilePromiseReceiver] {
        let receivers = (board.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]) ?? []
        return receivers.filter { $0.fileTypes.contains { UTType($0)?.conforms(to: .image) ?? false } }
    }

    /// Asks the source app for its promised files, reads each as it arrives and removes it.
    private static func receive(_ receivers: [NSFilePromiseReceiver], _ deliver: @escaping @MainActor @Sendable ([Item]) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Nibble drops/\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return }
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        // A receiver stands for one promised file.
        let left = Countdown(receivers.count)
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
                let data = error == nil ? try? Data(contentsOf: url) : nil
                try? FileManager.default.removeItem(at: url)
                // The last file in takes the folder with it.
                if left.tick() { try? FileManager.default.removeItem(at: folder) }
                guard let data else { return }
                let item = Item(data: data, name: url.lastPathComponent)
                Task { @MainActor in deliver([item]) }
            }
        }
    }

    /// Counts the promised files still to come.
    private final class Countdown: @unchecked Sendable {
        private let lock = NSLock()
        private var left: Int

        init(_ count: Int) { left = count }

        /// One more has come; true for the last.
        func tick() -> Bool {
            lock.withLock {
                left -= 1
                return left == 0
            }
        }
    }
}
