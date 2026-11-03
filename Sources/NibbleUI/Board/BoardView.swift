import AppKit
import MetalKit

/// Draws the light board with Metal: the board computes one colour per cell on the CPU (a few
/// thousand cells, well under a millisecond), the view uploads them as a small texture and one
/// fragment shader draws every cell as a lit square with the ground showing in the gap.
///
/// The view is as tall as the tallest the panel can get and pinned to the panel's top, so its
/// drawable never changes size while the panel unfolds or folds; rows below the panel's height are
/// simply not seen. `shift` draws the board that many points higher and further left, so the panel
/// can keep its cells put relative to the side that stays still while its size changes.
///
/// Frames come from a display link the view owns, which follows the screen the view is on; the
/// view draws when it fires. MTKView's own timer is never used: after hours of running it could
/// stop delivering frames for good (its dispatch source ended up cancelled while its display link
/// kept running), leaving the board frozen with no way to notice.
@MainActor
final class BoardView: MTKView {
    let board: Board
    /// Called once per frame before drawing; returns the scene, or nil to keep the last frame.
    var onFrame: (() -> BoardScene?)?

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var cellTexture: MTLTexture?
    private let renderer = Renderer()
    /// Set when the drawable may have lost its picture (resized, shown again).
    var needsRedraw = true
    /// How far left of and above the view's top left corner the board's first column and row
    /// start, in points (0 … one cell each).
    var shift = CGPoint.zero {
        didSet { if shift != oldValue { needsRedraw = true } }
    }
    /// Whether frames come at all (false while the window is hidden).
    var running = false {
        didSet { link?.isPaused = !running }
    }
    /// How many frames a second to ask for.
    var framesPerSecond = 60 {
        didSet { if framesPerSecond != oldValue { link?.preferredFrameRateRange = Self.range(framesPerSecond) } }
    }
    private var link: CADisplayLink?

    init?(board: Board) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let pipeline = Self.makePipeline(device)
        else { return nil }
        self.board = board
        self.queue = queue
        self.pipeline = pipeline
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        // Explicit drawing: the view draws only when `draw()` is called (from the link below).
        enableSetNeedsDisplay = false
        isPaused = true
        autoResizeDrawable = true
        // The cells' colours are sRGB values; tell the compositor so.
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer?.isOpaque = true
        renderer.view = self
        delegate = renderer
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsRedraw = true
    }

    /// A display link belongs to the view's window; a new one is made whenever the view moves to
    /// a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = Self.range(framesPerSecond)
        link.isPaused = !running
        // Common modes, so frames keep coming while the reader drags, resizes or holds a menu.
        link.add(to: .main, forMode: .common)
        self.link = link
        needsRedraw = true
    }

    @objc private func tick(_ link: CADisplayLink) {
        // MTKView's draw() asks the delegate for the frame, then lets go of the drawable.
        draw()
    }

    private static func range(_ fps: Int) -> CAFrameRateRange {
        let f = Float(max(1, fps))
        return CAFrameRateRange(minimum: f, maximum: f, preferred: f)
    }

    /// Clicks go to the controls above; the board only shows light.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Drawing

    fileprivate func drawFrame() {
        guard let scene = onFrame?() else { return }
        board.render(scene)
        // Slow light, quantised to 24 levels, often leaves every cell as it was: nothing to draw.
        guard board.changed || needsRedraw else { return }
        needsRedraw = false
        guard board.rows > 0,
              let drawable = currentDrawable,
              let pass = currentRenderPassDescriptor,
              let texture = texture(),
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        board.cellColors.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, board.cols, board.rows),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: board.cols * 4
            )
        }
        let look = board.look
        let square = max(1, look.pitch - look.gap)
        let ground = board.groundFill
        var uniforms = Uniforms(
            pitch: Float(look.pitch),
            square: Float(square),
            offset: Float(((look.pitch - square) / 2).rounded(.down)),
            scale: Float(window?.backingScaleFactor ?? 2),
            ground: SIMD4(Float(ground.x) / 255, Float(ground.y) / 255, Float(ground.z) / 255, 1),
            shift: SIMD2(Float(shift.x), Float(shift.y)),
            cols: Int32(board.cols),
            rows: Int32(board.rows)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private func texture() -> MTLTexture? {
        if let cellTexture, cellTexture.width == board.cols, cellTexture.height >= board.rows {
            return cellTexture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: max(1, board.cols),
            height: max(1, board.maxRows),
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        cellTexture = device?.makeTexture(descriptor: descriptor)
        return cellTexture
    }

    // MARK: - Pipeline

    private struct Uniforms {
        var pitch: Float
        var square: Float
        var offset: Float
        var scale: Float
        var ground: SIMD4<Float>
        var shift: SIMD2<Float>
        var cols: Int32
        var rows: Int32
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float pitch;
        float square;
        float offset;
        float scale;
        float4 ground;
        float2 shift;
        int cols;
        int rows;
    };

    vertex float4 boardVertex(uint id [[vertex_id]]) {
        // One triangle that covers the whole view.
        float2 p = float2((id << 1) & 2, id & 2);
        return float4(p * 2.0 - 1.0, 0.0, 1.0);
    }

    fragment float4 boardFragment(float4 position [[position]],
                                  constant Uniforms &u [[buffer(0)]],
                                  texture2d<float, access::read> cells [[texture(0)]]) {
        // Points from the top left, like the board's own coordinates.
        float2 pt = position.xy / u.scale + u.shift;
        int2 cell = int2(floor(pt / u.pitch));
        if (cell.x < 0 || cell.y < 0 || cell.x >= u.cols || cell.y >= u.rows) return u.ground;
        float2 f = pt - float2(cell) * u.pitch;
        bool lit = f.x >= u.offset && f.x < u.offset + u.square && f.y >= u.offset && f.y < u.offset + u.square;
        return lit ? cells.read(uint2(cell)) : u.ground;
    }
    """

    private static func makePipeline(_ device: MTLDevice) -> MTLRenderPipelineState? {
        do {
            let library = try device.makeLibrary(source: shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "boardVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "boardFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            return nil
        }
    }

    /// MTKView's delegate, kept apart so the view does not have to be its own delegate.
    private final class Renderer: NSObject, MTKViewDelegate {
        weak var view: BoardView?

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            MainActor.assumeIsolated { self.view?.drawFrame() }
        }
    }
}
