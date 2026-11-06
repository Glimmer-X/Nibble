import AppKit
import Foundation
import Testing
@testable import NibbleUI

/// Images pasted or dropped on the panel: which pasteboards hold one, and what is read from them.
/// (Files promised by the source app need a real drag; they are tried with one by hand.)
@MainActor
@Suite struct ImageIntakeTests {
    /// A pasteboard of its own, emptied, and a PNG file to put on it.
    final class Rig {
        let board = NSPasteboard(name: NSPasteboard.Name("nibble-tests-\(UUID().uuidString)"))
        let folder = FileManager.default.temporaryDirectory.appending(path: "nibble-tests-\(UUID().uuidString)")
        let png: Data

        init() throws {
            board.clearContents()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
                NSColor.systemPurple.setFill()
                rect.fill()
                return true
            }
            let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
            png = rep.representation(using: .png, properties: [:])!
        }

        func file(_ name: String, _ data: Data) throws -> URL {
            let url = folder.appending(path: name)
            try data.write(to: url)
            return url
        }

        deinit {
            board.releaseGlobally()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// What `read` hands over, and whether it said there were images.
    func read(_ board: NSPasteboard) -> (found: Bool, items: [ImageIntake.Item]) {
        var items: [ImageIntake.Item] = []
        let found = ImageIntake.read(board) { items += $0 }
        return (found, items)
    }

    @Test func anImageFileIsReadWithItsName() throws {
        let rig = try Rig()
        let url = try rig.file("photo.png", rig.png)
        rig.board.writeObjects([url as NSURL])
        #expect(ImageIntake.carriesImages(rig.board))
        let (found, items) = read(rig.board)
        #expect(found)
        #expect(items.map(\.name) == ["photo.png"])
        #expect(items.first?.data == rig.png)
    }

    @Test func aFileThatIsNotAnImageIsNone() throws {
        // Finder puts a file's icon on the pasteboard as image data too: that is not the file.
        let rig = try Rig()
        let url = try rig.file("notes.txt", Data("hello".utf8))
        rig.board.writeObjects([url as NSURL])
        rig.board.setData(rig.png, forType: .png)
        #expect(!ImageIntake.carriesImages(rig.board))
        let (found, items) = read(rig.board)
        #expect(!found)
        #expect(items.isEmpty)
    }

    @Test func onlyTheImagesAmongSeveralFilesAreRead() throws {
        let rig = try Rig()
        let image = try rig.file("a.png", rig.png)
        let text = try rig.file("b.txt", Data("hello".utf8))
        rig.board.writeObjects([image as NSURL, text as NSURL])
        #expect(ImageIntake.carriesImages(rig.board))
        #expect(read(rig.board).items.map(\.name) == ["a.png"])
    }

    @Test func imageDataIsReadWithoutAName() throws {
        // A browser's image, a copied screenshot.
        let rig = try Rig()
        rig.board.setData(rig.png, forType: .png)
        #expect(ImageIntake.carriesImages(rig.board))
        let (found, items) = read(rig.board)
        #expect(found)
        #expect(items.count == 1)
        #expect(items.first?.name == nil)
        #expect(items.first?.data == rig.png)
    }

    @Test func textIsNoImage() throws {
        let rig = try Rig()
        rig.board.setString("just words", forType: .string)
        #expect(!ImageIntake.carriesImages(rig.board))
        #expect(!read(rig.board).found)
    }

    @Test func dropTargetsTakeEveryFormAnImageComesIn() {
        let types = Set(ImageIntake.draggedTypes)
        #expect(types.contains(.fileURL))
        #expect(types.contains(.png) && types.contains(.tiff))
        // The form a promised file is dragged in.
        #expect(!Set(NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }).isDisjoint(with: types))
    }

    // MARK: The lit edge only adds light

    @Test func aPlateThatAddsLightNeverDarkensACell() {
        let board = Board(width: 200, maxHeight: 100)
        board.now = { 0 }
        board.setPalette(Palette(.dark))
        board.setMotion(nil)
        let cell = BoardScene.Rect(x0: 50, y0: 50, x1: 60, y1: 60)
        func colours(_ plates: [BoardScene.Plate]) -> [UInt32] {
            var scene = BoardScene(width: 200, height: 100)
            scene.plates = plates
            board.render(scene)
            return board.cellColors
        }
        let lit = BoardScene.Plate(rect: cell, clip: nil, rose: false, value: 0.4, snap: true)
        let alone = colours([lit])
        // Dimmer light on top leaves the cell as bright as it was.
        #expect(colours([lit, BoardScene.Plate(rect: cell, clip: nil, rose: false, value: 0.1, snap: true, adds: true)]) == alone)
        // A plate that sets its value darkens it.
        #expect(colours([lit, BoardScene.Plate(rect: cell, clip: nil, rose: false, value: 0.1, snap: true)]) != alone)
        // Brighter light on top shows.
        let bright = colours([BoardScene.Plate(rect: cell, clip: nil, rose: false, value: 0.6, snap: true)])
        #expect(colours([lit, BoardScene.Plate(rect: cell, clip: nil, rose: false, value: 0.6, snap: true, adds: true)]) == bright)
    }
}
