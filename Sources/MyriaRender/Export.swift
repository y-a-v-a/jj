import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import MyriaCore
import MyriaData
import MyriaLayouts
import UniformTypeIdentifiers

/// One-call rendering of a map to an image, for exports, the command line
/// and tests.
public enum MapExport {
    /// A viewport fitting the flat map (or, while folded, the globe) into
    /// `width × height` points.
    public static func viewport(for state: MapState, width: Double, height: Double, unfold: Double = 1, margin: Double = 16) -> Viewport {
        let map = Viewport(bounds: state.projection.bounds, size: Vec2(width, height), margin: margin)
        guard unfold < 1 else { return map }
        let globe = Viewport(bounds: Rect2(minX: -1.15, minY: -1.15, maxX: 1.15, maxY: 1.15), size: Vec2(width, height), margin: margin)
        return Viewport.blend(globe, map, unfold)
    }

    /// A viewport around the map as it stands at `unfold`: the globe, the
    /// flat map or anything between, so no frame of an unfolding film loses
    /// part of it, whatever the shapes of the map and the frame.
    public static func fittedViewport(for state: MapState, width: Double, height: Double, unfold: Double, globe: Mat3,
                                      margin: Double = 16) -> Viewport {
        guard unfold > 0, unfold < 1 else { return viewport(for: state, width: width, height: height, unfold: unfold, margin: margin) }
        let frames = state.mesh.frames
        var b = Rect2.empty
        for (f, pose) in state.poses.poses(unfold: unfold, globe: globe).enumerated() {
            for v in frames[f].localVertices {
                let p = pose.apply(v)
                b.include(Vec2(p.x, p.y))
            }
        }
        // The globe's room for its halo, given up as it opens.
        let pad = 0.15 * (1 - unfold)
        b = Rect2(minX: b.minX - pad, minY: b.minY - pad, maxX: b.maxX + pad, maxY: b.maxY + pad)
        return Viewport(bounds: b, size: Vec2(width, height), margin: margin)
    }

    /// The height that suits a map `width` wide.
    public static func height(for state: MapState, width: Int, margin: Double = 16) -> Int {
        let b = state.projection.bounds
        return Int(((Double(width) - 2 * margin) * b.height / max(b.width, 1e-9) + 2 * margin).rounded())
    }

    public static func settings(for state: MapState, palette: Palette, dark: Bool, width: Int, height: Int,
                                coloring: LayoutAppearance.Coloring? = nil, layers: Set<LayerID>? = nil,
                                date: Date = Date(), unfold: Double = 1, globe: Mat3 = .identity) -> FrameSettings {
        let lineScale = max(1, Double(width) / 1600)
        return FrameSettings(style: palette.style(dark: dark), coloring: coloring ?? state.appearance.coloring,
                             layers: layers ?? LayerID.defaults(for: state.appearance), date: date, unfold: unfold, globe: globe,
                             viewport: viewport(for: state, width: Double(width), height: Double(height), unfold: unfold),
                             pixelScale: 1, lineScale: lineScale, sealSlits: state.appearance.sealSlits)
    }

    public static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.allocation("PNG encoder")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw RenderError.allocation("PNG data") }
        return data as Data
    }

    /// The frames of an unfolding film: the globe turns a quarter turn into
    /// place, unfolds with van Wijk's easing, α' = α (1 + cos(π t / T)) / 2,
    /// and the map holds still. Each frame is (unfold, globe).
    public static func unfoldingStoryboard(fps: Double, globe: Mat3, turn: Double = 1.5, unfold: Double = 4,
                                           hold: Double = 2) -> [(unfold: Double, globe: Mat3)] {
        var frames: [(unfold: Double, globe: Mat3)] = []
        let turning = Int((turn * fps).rounded()), unfolding = Int((unfold * fps).rounded()), holding = Int((hold * fps).rounded())
        for k in 0..<turning {
            // Ease out of the turn: fast at first, settling as it starts to open.
            let t = Double(k) / Double(max(turning, 1))
            let angle = -.pi / 2 * (1 - sin(t * .pi / 2))
            frames.append((0, globe * Mat3.rotationZ(angle)))
        }
        for k in 0...unfolding {
            let t = Double(k) / Double(max(unfolding, 1))
            frames.append(((1 - cos(.pi * t)) / 2, globe))
        }
        frames += Array(repeating: (1, globe), count: holding)
        return frames
    }

    /// A 16:9 frame for films, `width` wide; even, as video encoders need.
    public static func movieSize(width: Int) -> (width: Int, height: Int) {
        (width & ~1, (width * 9 / 16) & ~1)
    }

    /// Writes frames as a film (HEVC in a QuickTime movie), rendering each
    /// frame on demand.
    public static func movie(to url: URL, width: Int, height: Int, fps: Int, count: Int,
                             frame: (Int) throws -> CGImage) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(8_000_000, width * height * 4)],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw RenderError.allocation("movie track") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RenderError.allocation("movie writer") }
        writer.startSession(atSourceTime: .zero)
        for k in 0..<count {
            let image = try frame(k)
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard let pool = adaptor.pixelBufferPool else { throw writer.error ?? RenderError.allocation("pixel buffers") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw RenderError.allocation("pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(k), timescale: CMTimeScale(fps))) else {
                throw writer.error ?? RenderError.allocation("movie frame \(k)")
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? RenderError.allocation("movie") }
    }

    /// Writes frames as an animated GIF.
    public static func gif(_ images: [CGImage], delay: Double) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, images.count, nil) else {
            throw RenderError.allocation("GIF encoder")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
        for image in images { CGImageDestinationAddImage(dest, image, frame) }
        guard CGImageDestinationFinalize(dest) else { throw RenderError.allocation("GIF data") }
        return data as Data
    }
}
