import CoreGraphics
import ImageIO
import Foundation
import Testing
import MyriaCore
import MyriaData
import MyriaLayouts
@testable import MyriaRender

/// Visual tests: they draw maps with Metal and look at the pixels. Every
/// render is also written to `Tests/MyriaRenderTests/Output` for people to
/// look at; `Snapshots` holds the references (re-record with JJ_RECORD=1).
enum Visual {
    static let engine = MapEngine()
    nonisolated(unsafe) static let renderer: MapRenderer = try! MapRenderer()
    static let lock = NSLock()
    static let date = ISO8601DateFormatter().date(from: "2026-06-21T12:00:00Z")!

    static var testDirectory: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent() }

    static func build(_ id: String, mesh: MeshKind? = nil) throws -> MapState {
        let layout = try #require(LayoutCatalog.layout(id: id))
        var p = layout.descriptor.defaultParameters
        p.date = date
        return try engine.build(layout, parameters: p, mesh: MeshSpec(mesh ?? layout.descriptor.preferredMesh))
    }

    /// Renders (one at a time: the renderer is not thread-safe).
    static func render(_ state: MapState, width: Int, settings: (inout FrameSettings) -> Void = { _ in },
                       palette: Palette = .vanWijk, dark: Bool = false, unfold: Double = 1, square: Bool = false) throws -> Pixels {
        let height = square ? width : MapExport.height(for: state, width: width)
        var s = MapExport.settings(for: state, palette: palette, dark: dark, width: width, height: height, date: date, unfold: unfold)
        settings(&s)
        lock.lock()
        defer { lock.unlock() }
        return Pixels(try renderer.image(state, settings: s, width: width, height: height))
    }

    static func save(_ pixels: Pixels, _ name: String) throws {
        let dir = testDirectory.appendingPathComponent("Output")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try MapExport.png(pixels.image).write(to: dir.appendingPathComponent(name + ".png"))
    }
}

/// RGBA bytes of an image.
struct Pixels {
    let image: CGImage
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        self.image = image
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.bytes = bytes
    }

    func rgb(_ i: Int) -> (Int, Int, Int) { (Int(bytes[4 * i]), Int(bytes[4 * i + 1]), Int(bytes[4 * i + 2])) }

    func count(where predicate: ((Int, Int, Int)) -> Bool) -> Int {
        (0..<(width * height)).reduce(0) { $0 + (predicate(rgb($1)) ? 1 : 0) }
    }

    /// Mean absolute difference per channel, and the share of pixels that
    /// differ by more than 24 in some channel.
    func difference(to other: Pixels) -> (mean: Double, changed: Double) {
        guard width == other.width, height == other.height else { return (255, 1) }
        var sum = 0, changed = 0
        for i in 0..<(width * height) {
            let (a, b) = (rgb(i), other.rgb(i))
            let d = (abs(a.0 - b.0), abs(a.1 - b.1), abs(a.2 - b.2))
            sum += d.0 + d.1 + d.2
            if max(d.0, d.1, d.2) > 24 { changed += 1 }
        }
        return (Double(sum) / Double(3 * width * height), Double(changed) / Double(width * height))
    }
}

@Suite("Rendering", .serialized)
struct RenderTests {
    /// "The resulting maps have a large number of interrupts, but are
    /// (almost) conformal and conserve areas." Paint land red and sea blue:
    /// the share of red pixels is the share of land on the globe, 29.2 %.
    @Test(arguments: ["point-of-view", "timezones", "graticular-cylindrical", "geo-continents"])
    func myriahedralMapsConserveArea(id: String) throws {
        let state = try Visual.build(id)
        var style = Palette.vanWijk.light
        style.land = RGBA(1, 0, 0)
        style.ocean = RGBA(0, 0, 1)
        style.hillshade = 0
        let pixels = try Visual.render(state, width: 1600) {
            $0.style = style
            $0.coloring = .landSea
            $0.layers = [.land]
            $0.sealSlits = false
        }
        try Visual.save(pixels, "area-\(id)")
        let land = pixels.count { $0.0 > 200 && $0.2 < 60 }
        let sea = pixels.count { $0.2 > 200 && $0.0 < 60 }
        let share = Double(land) / Double(land + sea)
        #expect(abs(share - 0.292) < 0.015, "land share \(share)")
    }

    @Test func darkAndLightBackgrounds() throws {
        let state = try Visual.build("graticular-cylindrical")
        for dark in [false, true] {
            let pixels = try Visual.render(state, width: 600, dark: dark)
            let bg = Palette.vanWijk.style(dark: dark).background
            let corner = pixels.rgb(0)
            #expect(abs(corner.0 - Int(bg.r * 255)) <= 2 && abs(corner.2 - Int(bg.b * 255)) <= 2)
        }
    }

    /// Closed, the map is the globe: a disc filling π/4 of its bounding square.
    @Test func foldsIntoAGlobe() throws {
        let state = try Visual.build("geo-continents")
        let pixels = try Visual.render(state, width: 600, unfold: 0, square: true)
        try Visual.save(pixels, "globe")
        let bg = Palette.vanWijk.light.background
        let background = pixels.count { abs($0.0 - Int(bg.r * 255)) < 4 && abs($0.1 - Int(bg.g * 255)) < 4 && abs($0.2 - Int(bg.b * 255)) < 4 }
        let covered = Double(pixels.width * pixels.height - background)
        // The globe of radius 1 is drawn in a ±1.15 square with a 16 px margin.
        let radius = (600.0 - 32) / 2.3
        #expect(abs(covered / (.pi * radius * radius) - 1) < 0.03)
    }

    @Test func everyPaletteDrawsBothVariants() throws {
        let state = try Visual.build("timezones", mesh: .graticule(step: 5))
        for palette in Palette.all {
            for dark in [false, true] {
                let pixels = try Visual.render(state, width: 400, palette: palette, dark: dark)
                let distinct = Set((0..<(pixels.width * pixels.height)).map { i -> Int in
                    let (r, g, b) = pixels.rgb(i)
                    return (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
                })
                #expect(distinct.count > 12, "\(palette.id) \(dark)")
            }
        }
    }

    @Test func paletteColorsStayApart() {
        for palette in Palette.all {
            for style in [palette.light, palette.dark] {
                #expect(style.land.perceptualDistance(to: style.ocean) > 4, "\(palette.id)")
                let c = style.categorical
                for i in c.indices {
                    for j in c.indices where j > i { #expect(c[i].perceptualDistance(to: c[j]) > 3, "\(palette.id) \(i) \(j)") }
                }
                #expect(style.ink.contrastRatio(with: style.background) > 4.5, "\(palette.id) ink")
            }
        }
    }

    /// Fields drawn opaquely must not fade into the page at either end of
    /// their scale, or the map's outline (and its cuts) disappear.
    @Test func opaqueColourScalesStandOutFromThePage() {
        for palette in Palette.all {
            for (variant, style) in [("light", palette.light), ("dark", palette.dark)] {
                // Terrain is left out: its snowy end only ever colours peaks.
                for hint in [ColormapHint.rain, .wind, .landness, .distance, .sequential] {
                    let map = style.colormap(hint)
                    for end in [map.stops.first!, map.stops.last!] {
                        #expect(end.perceptualDistance(to: style.background) > 6, "\(palette.id) \(variant) \(hint)")
                    }
                }
            }
        }
    }

    /// Every layout against its reference image.
    @Test(arguments: LayoutCatalog.all.map(\.descriptor.id))
    func snapshot(id: String) throws {
        let state = try Visual.build(id)
        let pixels = try Visual.render(state, width: 480)
        try Visual.save(pixels, "snapshot-\(id)")
        let url = Visual.testDirectory.appendingPathComponent("Snapshots/\(id).png")
        if ProcessInfo.processInfo.environment["JJ_RECORD"] != nil || !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try MapExport.png(pixels.image).write(to: url)
            return
        }
        let reference = try #require(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let diff = pixels.difference(to: Pixels(reference))
        #expect(diff.mean < 3 && diff.changed < 0.02, "\(id): mean \(diff.mean), changed \(diff.changed)")
    }
}
