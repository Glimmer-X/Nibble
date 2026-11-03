// Records a region of the main screen showing only one app's windows (nothing else on the screen
// shows: other windows, the desktop, the pointer), until the app says it is done. Used by
// scripts/demo.sh, which builds it into build/tools/record.
//
//   record BUNDLE_ID SIGNALS_FOLDER OUTPUT.mp4
//
// The app writes SIGNALS_FOLDER/region ("x y width height": points from the main screen's top
// left) and, before it, SIGNALS_FOLDER/backdrop ("r g b", 0–255: the colour behind the windows;
// optional), the recorder writes SIGNALS_FOLDER/recording once frames are being kept, and the app
// writes SIGNALS_FOLDER/done when it has finished.
import AppKit
import AVFoundation
import ScreenCaptureKit

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: record BUNDLE_ID SIGNALS_FOLDER OUTPUT.mp4\n".utf8))
    exit(2)
}
let bundleID = arguments[1]
let signals = URL(filePath: arguments[2])
let output = URL(filePath: arguments[3])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("record: \(message)\n".utf8))
    exit(1)
}

func waitFor(_ name: String, seconds: Double) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if FileManager.default.fileExists(atPath: signals.appending(path: name).path) { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

/// Says when the file is complete.
final class Finish: NSObject, SCRecordingOutputDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private var finished = false
    private let lock = NSLock()

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) { done() }
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        FileHandle.standardError.write(Data("record: \(error.localizedDescription)\n".utf8))
        done()
    }

    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            if finished { lock.unlock(); c.resume(); return }
            continuation = c
            lock.unlock()
        }
    }

    private func done() {
        lock.lock()
        finished = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}

guard await waitFor("region", seconds: 60),
      let text = try? String(contentsOf: signals.appending(path: "region"), encoding: .utf8)
else { fail("the app never said where to record") }
let numbers = text.split(separator: " ").compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
guard numbers.count == 4 else { fail("cannot read the region: \(text)") }
let region = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])

let content: SCShareableContent
do {
    content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
} catch {
    fail("no screen recording permission for this terminal (\(error.localizedDescription))")
}
guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { fail("no main display") }
guard let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else { fail("\(bundleID) is not running") }

let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
let scale = CGFloat(filter.pointPixelScale)
let configuration = SCStreamConfiguration()
configuration.sourceRect = region
configuration.width = Int(region.width * scale)
configuration.height = Int(region.height * scale)
configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
configuration.showsCursor = false
configuration.captureResolution = .best
configuration.colorSpaceName = CGColorSpace.sRGB
// The colour behind the panel, from the app (a deep grey in its theme's hue), or a deep violet grey.
// The configuration does not keep the colour, so it is held here for the whole run.
let backdrop = (try? String(contentsOf: signals.appending(path: "backdrop"), encoding: .utf8))?
    .split(separator: " ").compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
let background = if let backdrop, backdrop.count == 3 {
    CGColor(srgbRed: backdrop[0] / 255, green: backdrop[1] / 255, blue: backdrop[2] / 255, alpha: 1)
} else {
    CGColor(srgbRed: 0.10, green: 0.094, blue: 0.13, alpha: 1)
}
configuration.backgroundColor = background

let recording = SCRecordingOutputConfiguration()
recording.outputURL = output
recording.outputFileType = .mp4
recording.videoCodecType = .h264
let finish = Finish()
let recorder = SCRecordingOutput(configuration: recording, delegate: finish)
let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
do {
    try? FileManager.default.removeItem(at: output)
    try stream.addRecordingOutput(recorder)
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
        stream.startCapture { error in if let error { c.resume(throwing: error) } else { c.resume() } }
    }
} catch {
    fail("cannot start recording (\(error.localizedDescription))")
}
// Let the first frames land before the app starts.
try? await Task.sleep(for: .milliseconds(300))
FileManager.default.createFile(atPath: signals.appending(path: "recording").path, contents: Data())

_ = await waitFor("done", seconds: 180)
await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in stream.stopCapture { _ in c.resume() } }
await finish.wait()
print(output.path)
