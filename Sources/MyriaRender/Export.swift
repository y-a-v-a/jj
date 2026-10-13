import CoreGraphics
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
                             pixelScale: 1, lineScale: lineScale)
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
