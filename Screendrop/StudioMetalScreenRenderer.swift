import CoreGraphics
import CoreVideo
import Metal
import MetalPerformanceShaders

/// Export-local GPU resources. One command buffer evaluates the complete
/// shutter; no full-resolution intermediate image is allocated per sample.
/// The caller may keep one frame in flight - submitting the next frame's
/// pass while it draws the previous frame's overlays - and must wait on each
/// submission before touching that frame's pixels on the CPU.
nonisolated final class StudioMetalScreenRenderer {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let backdropTexture: MTLTexture
    private let clipTexture: MTLTexture
    private let downsampler: MPSImageLanczosScale
    private var downsampledTexture: MTLTexture?

    init?(
        canvasSize: CGSize, backdrop: CGImage?, cardPath: CGPath,
        colorSpace: CGColorSpace, library: MTLLibrary? = nil
    ) {
        guard let device = library?.device ?? MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue(),
            let library = library ?? device.makeDefaultLibrary(),
            let function = library.makeFunction(name: "studioMotionBlur"),
            let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        var cache: CVMetalTextureCache?
        // Masked exports hand over a new full-size surface every frame, and the
        // default one-second age kept ~80 of them alive (2+ GB at 3420 wide).
        let cacheAttributes = [kCVMetalTextureCacheMaximumTextureAgeKey: 0.1] as CFDictionary
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, cacheAttributes, device, nil, &cache) == kCVReturnSuccess,
            let cache
        else { return nil }
        let width = Int(canvasSize.width)
        let height = Int(canvasSize.height)
        guard
            let backdropTexture = Self.makeTexture(
                device: device, width: width, height: height,
                colorSpace: colorSpace,
                draw: { context in
                    let bounds = CGRect(origin: .zero, size: canvasSize)
                    if let backdrop {
                        context.draw(backdrop, in: bounds)
                    } else {
                        context.setFillColor(CGColor(gray: 0, alpha: 1))
                        context.fill(bounds)
                    }
                }),
            let clipTexture = Self.makeTexture(
                device: device, width: width, height: height,
                colorSpace: colorSpace,
                draw: { context in
                    context.setFillColor(CGColor(gray: 1, alpha: 1))
                    context.addPath(cardPath)
                    context.fillPath()
                })
        else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.textureCache = cache
        self.backdropTexture = backdropTexture
        self.clipTexture = clipTexture
        self.downsampler = MPSImageLanczosScale(device: device)
        self.downsampler.edgeMode = .clamp
    }

    /// A committed pass. It retains the Core Video texture wrappers, whose
    /// textures alone do not keep their backing allocations alive.
    struct Submission {
        fileprivate let command: MTLCommandBuffer
        fileprivate let textures: [CVMetalTexture]
    }

    /// Rectangles use the same top-left canvas coordinates as StudioLayout.
    /// Returns nil, without encoding anything, if Metal cannot take a frame.
    /// Commands on one queue run in order, so the shared downsample texture
    /// is never overwritten while an earlier pass still reads it.
    func submit(screenFrame: CVPixelBuffer, sampleRects: [CGRect], into destination: CVPixelBuffer) -> Submission? {
        guard (1...24).contains(sampleRects.count),
            sampleRects.allSatisfy({
                $0.width > 0 && $0.height > 0 && $0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite
                    && $0.height.isFinite
            }),
            let source = texture(for: screenFrame, usage: .shaderRead),
            let output = texture(for: destination, usage: .shaderWrite),
            let sourceTexture = CVMetalTextureGetTexture(source),
            let outputTexture = CVMetalTextureGetTexture(output),
            outputTexture.width == backdropTexture.width,
            outputTexture.height == backdropTexture.height,
            let command = queue.makeCommandBuffer()
        else { return nil }

        // Bound the per-pixel filter footprint for very large reductions.
        // Leave up to 2x resolution for the shutter's scale-aware Lanczos
        // reconstruction, rather than reducing straight to output size.
        var sampledTexture = sourceTexture
        let scaledWidth = Int(min(CGFloat(sourceTexture.width), ceil(sampleRects.map(\.width).max()! * 2)))
        let scaledHeight = Int(min(CGFloat(sourceTexture.height), ceil(sampleRects.map(\.height).max()! * 2)))
        if scaledWidth < sourceTexture.width || scaledHeight < sourceTexture.height {
            if downsampledTexture?.width != scaledWidth || downsampledTexture?.height != scaledHeight {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm,
                    width: scaledWidth, height: scaledHeight, mipmapped: false)
                descriptor.usage = [.shaderRead, .shaderWrite]
                descriptor.storageMode = .private
                downsampledTexture = device.makeTexture(descriptor: descriptor)
            }
            guard let downsampledTexture else { return nil }
            downsampler.encode(
                commandBuffer: command, sourceTexture: sourceTexture,
                destinationTexture: downsampledTexture)
            sampledTexture = downsampledTexture
        }
        // shouldAccelerate screens these out first; this only guards callers
        // that skip it.
        guard
            sampleRects.allSatisfy({
                $0.width * 4 >= CGFloat(sampledTexture.width) && $0.height * 4 >= CGFloat(sampledTexture.height)
            })
        else { return nil }
        guard let encoder = command.makeComputeCommandEncoder() else { return nil }

        var count = UInt32(sampleRects.count)
        let rects = sampleRects.map { SIMD4<Float>(Float($0.minX), Float($0.minY), Float($0.width), Float($0.height)) }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(sampledTexture, index: 0)
        encoder.setTexture(backdropTexture, index: 1)
        encoder.setTexture(clipTexture, index: 2)
        encoder.setTexture(outputTexture, index: 3)
        rects.withUnsafeBytes { bytes in
            encoder.setBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 1)
        let width = pipeline.threadExecutionWidth
        let height = min(8, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: outputTexture.width, height: outputTexture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        encoder.endEncoding()
        command.commit()
        return Submission(command: command, textures: [source, output])
    }

    /// Blocks until the pass finishes. False means the frame has no screen
    /// layer and must be drawn another way.
    func wait(for submission: Submission) -> Bool {
        withExtendedLifetime(submission.textures) { submission.command.waitUntilCompleted() }
        return submission.command.status == .completed
    }

    /// Every frame - settled or blurred - renders on the GPU, so an export
    /// never alternates between two reconstruction filters. The one
    /// exception is an extreme discontinuity inside a shutter, where one
    /// rect is far smaller than the texture the others share; Core Graphics
    /// draws that frame. This is a per-frame fallback, not a GPU failure.
    static func shouldAccelerate(screenFrame: CVPixelBuffer, sampleRects: [CGRect]) -> Bool {
        guard let widest = sampleRects.map(\.width).max(),
              let tallest = sampleRects.map(\.height).max() else { return false }
        // Mirrors the downsample bound in render(screenFrame:sampleRects:into:).
        let sampledWidth = min(CGFloat(CVPixelBufferGetWidth(screenFrame)), ceil(widest * 2))
        let sampledHeight = min(CGFloat(CVPixelBufferGetHeight(screenFrame)), ceil(tallest * 2))
        return sampleRects.allSatisfy {
            $0.width * 4 >= sampledWidth && $0.height * 4 >= sampledHeight
        }
    }

    private func texture(for buffer: CVPixelBuffer, usage: MTLTextureUsage) -> CVMetalTexture? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        var texture: CVMetalTexture?
        let attributes = [kCVMetalTextureUsage: usage.rawValue] as CFDictionary
        guard
            CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault, textureCache, buffer,
                attributes, .bgra8Unorm, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0,
                &texture) == kCVReturnSuccess
        else { return nil }
        return texture
    }

    private static func makeTexture(
        device: MTLDevice, width: Int, height: Int,
        colorSpace: CGColorSpace, draw: (CGContext) -> Void
    ) -> MTLTexture? {
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            let pixels = context.data
        else { return nil }
        draw(context)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: pixels, bytesPerRow: context.bytesPerRow)
        return texture
    }
}
