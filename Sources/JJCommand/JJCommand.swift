import ArgumentParser
import CoreGraphics
import Foundation
import MyriaCore
import MyriaData
import MyriaLayouts
import MyriaRender

@main
struct JJCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jj",
        abstract: "Myriahedral maps of the Earth, after Jarke J. van Wijk (2008).",
        subcommands: [Layouts.self, Render.self, Stats.self, Gallery.self, Animate.self, Icon.self])
}

/// Options shared by the commands that build a map.
struct MapOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "Layout id (see `jj layouts`).")
    var layout = "coastline"

    @Option(name: .shortAndLong, help: "Mesh: graticule:2.5, geodesic:40, platonic:icosahedron:3. Default: the layout's own.")
    var mesh: String?

    @Option(name: .shortAndLong, parsing: .upToNextOption, help: "Layout parameters as name=value.")
    var parameter: [String] = []

    @Option(help: "Date and time (ISO 8601) for night, clocks and time-dependent layouts.")
    var date: String?

    func resolvedDate() throws -> Date {
        guard let date else { return Date() }
        guard let d = ISO8601DateFormatter().date(from: date) else { throw ValidationError("bad date \(date)") }
        return d
    }

    func build(_ engine: MapEngine) throws -> MapState {
        guard let layout = LayoutCatalog.layout(id: layout) else {
            throw ValidationError("unknown layout \(self.layout); try `jj layouts`")
        }
        var parameters = layout.descriptor.defaultParameters
        parameters.date = try resolvedDate()
        for p in parameter {
            let parts = p.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let v = Double(parts[1]) else { throw ValidationError("bad parameter \(p)") }
            parameters[parts[0]] = v
        }
        let kind = try mesh.map { m -> MeshKind in
            guard let k = MeshKind(argument: m) else { throw ValidationError("bad mesh \(m)") }
            return k
        } ?? layout.descriptor.preferredMesh
        return try engine.build(layout, parameters: parameters, mesh: MeshSpec(kind))
    }
}

struct Layouts: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List the layouts.")

    func run() {
        for category in LayoutCategory.allCases {
            print("\n\(category.title)")
            for layout in LayoutCatalog.all where layout.descriptor.category == category {
                let d = layout.descriptor
                print("  \(d.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \(d.title) — \(d.summary)")
            }
        }
    }
}

struct Render: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render a layout to a PNG.")

    @OptionGroup var map: MapOptions

    @Option(name: .shortAndLong, help: "Output PNG file.")
    var output = "map.png"

    @Option(help: "Width in pixels.")
    var width = 2400

    @Option(help: "Height in pixels (default: fits the map).")
    var height: Int?

    @Option(help: "Palette: \(Palette.all.map(\.id).joined(separator: ", ")).")
    var palette = "vanwijk"

    @Flag(help: "Use the palette's dark variant.")
    var dark = false

    @Option(help: "0 is the globe, 1 the flat map.")
    var unfold = 1.0

    @Option(help: "Coloring: landsea, relief, groups, field:<id>[:variant], regions:<dataset>.")
    var coloring: String?

    @Option(help: "Layers to add or remove, e.g. +cuts,+mesh,-graticule.")
    var layers: String?

    func run() throws {
        let engine = MapEngine()
        let start = Date()
        let state = try map.build(engine)
        let built = Date()
        let renderer = try MapRenderer()
        let h = height ?? (unfold < 1 ? width : MapExport.height(for: state, width: width))
        guard let palette = Palette.named(palette) else { throw ValidationError("unknown palette") }
        let settings = try MapExport.settings(for: state, palette: palette, dark: dark, width: width, height: h,
                                              coloring: parseColoring(coloring), layers: parseLayers(layers, state: state),
                                              date: map.resolvedDate(), unfold: unfold)
        let image = try renderer.image(state, settings: settings, width: width, height: h)
        try MapExport.png(image).write(to: URL(fileURLWithPath: output))
        let timing = state.timings.map { String(format: "%@ %.2fs", $0.0, $0.1) }.joined(separator: ", ")
        print(String(format: "%@: %d faces, %d pieces · built in %.2fs (%@) · drawn in %.2fs → %@",
                     state.layout.title, state.mesh.faceCount, state.pieceCount, built.timeIntervalSince(start), timing,
                     Date().timeIntervalSince(built), output))
        for note in state.cut.notes { print("  " + note) }
    }

    func parseColoring(_ s: String?) throws -> LayoutAppearance.Coloring? {
        guard let s else { return nil }
        let parts = s.split(separator: ":").map(String.init)
        switch parts[0] {
        case "landsea": return .landSea
        case "relief": return .relief
        case "groups": return .groups
        case "field" where parts.count >= 2: return .field(FieldKey(parts[1], parts.count > 2 ? parts[2] : ""))
        case "regions" where parts.count == 2: return .regions(DatasetID(rawValue: parts[1]))
        default: throw ValidationError("bad coloring \(s)")
        }
    }

    func parseLayers(_ s: String?, state: MapState) throws -> Set<LayerID>? {
        guard let s else { return nil }
        var set = LayerID.defaults(for: state.appearance)
        for item in s.split(separator: ",") {
            let name = String(item.dropFirst())
            guard let id = LayerID(rawValue: name) else { throw ValidationError("unknown layer \(name)") }
            if item.hasPrefix("-") { set.remove(id) } else { set.insert(id) }
        }
        return set
    }
}

struct Stats: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Describe a cut: faces, cuts, pieces, timings.")

    @OptionGroup var map: MapOptions

    func run() throws {
        let engine = MapEngine()
        let start = Date()
        let state = try map.build(engine)
        let mesh = state.mesh
        let cuts = state.projection.cutEdges.count
        print("Layout:       \(state.layout.title)")
        print("Mesh:         \(state.context.spec.kind.title) (\(mesh.cellCount) polygons)")
        print("Faces/edges:  \(mesh.faceCount) / \(mesh.edgeCount), vertices \(mesh.polyhedron.vertexCount)")
        print("Cuts:         \(cuts) (V − 1 = \(mesh.polyhedron.vertexCount - 1))")
        print("Pieces:       \(state.pieceCount)")
        print(String(format: "Map size:     %.3f × %.3f", state.projection.bounds.width, state.projection.bounds.height))
        for (name, t) in state.timings { print(String(format: "  %-12@ %.3fs", name, t)) }
        print(String(format: "Total:        %.3fs", Date().timeIntervalSince(start)))
        for note in state.cut.notes { print(note) }
        // Animation costs: poses per frame on the CPU, a frame on the GPU.
        var t = Date()
        let frames = 20
        var sink: Float = 0
        for k in 0..<frames {
            state.poses.forEachPoseRows(unfold: Double(k) / Double(frames), globe: .identity) { _, r0, _, _ in sink += r0.w }
        }
        if sink.isNaN { print("") }
        print(String(format: "Fold poses:   %.2f ms per frame", Date().timeIntervalSince(t) * 1000 / Double(frames)))
        let renderer = try MapRenderer()
        let settings = MapExport.settings(for: state, palette: .vanWijk, dark: false, width: 2400, height: 1500, unfold: 0.5)
        _ = try renderer.image(state, settings: settings, width: 2400, height: 1500)
        t = Date()
        for k in 0..<frames {
            var s = settings
            s.unfold = 0.3 + 0.02 * Double(k)
            _ = try renderer.image(state, settings: s, width: 2400, height: 1500)
        }
        print(String(format: "Frame:        %.2f ms (2400 × 1500, 4× MSAA, folding, with read-back)", Date().timeIntervalSince(t) * 1000 / Double(frames)))
        print("Overlap:      " + String(format: "%.3f%% of the map area", state.projection.overlapFraction() * 100))
    }
}

struct Gallery: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render every layout into a folder.")

    @Option(name: .shortAndLong, help: "Output folder.")
    var output = "out/gallery"

    @Option(help: "Width in pixels.")
    var width = 1600

    @Option(help: "Palette id.")
    var palette = "vanwijk"

    @Flag(help: "Dark variant.")
    var dark = false

    @Option(help: "Only layouts whose id contains this.")
    var filter: String?

    func run() throws {
        let engine = MapEngine()
        let renderer = try MapRenderer()
        guard let palette = Palette.named(palette) else { throw ValidationError("unknown palette") }
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for layout in LayoutCatalog.all where filter.map({ layout.descriptor.id.contains($0) }) ?? true {
            let start = Date()
            let d = layout.descriptor
            let state = try engine.build(layout, parameters: d.defaultParameters, mesh: MeshSpec(d.preferredMesh))
            let h = MapExport.height(for: state, width: width)
            let settings = MapExport.settings(for: state, palette: palette, dark: dark, width: width, height: h)
            let image = try renderer.image(state, settings: settings, width: width, height: h)
            let file = "\(output)/\(d.id)\(dark ? "-dark" : "").png"
            try MapExport.png(image).write(to: URL(fileURLWithPath: file))
            print(String(format: "%-22@ %6d faces %5d pieces %6.2fs → %@", d.id, state.mesh.faceCount, state.pieceCount,
                         Date().timeIntervalSince(start), file))
        }
    }
}

struct Animate: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render the globe unfolding into the map as a GIF.")

    @OptionGroup var map: MapOptions

    @Option(name: .shortAndLong, help: "Output GIF file.")
    var output = "unfold.gif"

    @Option(help: "Width in pixels.")
    var width = 800

    @Option(help: "Frames.")
    var frames = 48

    @Option(help: "Palette id.")
    var palette = "vanwijk"

    @Flag(help: "Dark variant.")
    var dark = false

    func run() throws {
        let engine = MapEngine()
        let state = try map.build(engine)
        let renderer = try MapRenderer()
        guard let palette = Palette.named(palette) else { throw ValidationError("unknown palette") }
        let h = MapExport.height(for: state, width: width)
        var images: [CGImage] = []
        let globe = Mat3.rotationZ(-(state.parameters["center"] ?? 10) * .pi / 180)
        let tilt = Mat3.rotation(axis: .unitX, angle: -.pi / 2) * Mat3.rotation(axis: .unitZ, angle: -.pi / 2)
        for k in 0..<frames {
            // Van Wijk: α' = α (1 + cos(π t / T)) / 2.
            let t = 1 - (1 + cos(.pi * Double(k) / Double(frames - 1))) / 2
            let settings = MapExport.settings(for: state, palette: palette, dark: dark, width: width, height: h,
                                              date: try map.resolvedDate(), unfold: t, globe: tilt * globe)
            images.append(try renderer.image(state, settings: settings, width: width, height: h))
        }
        images += Array(repeating: images.last!, count: 12)
        try MapExport.gif(images, delay: 1.0 / 24).write(to: URL(fileURLWithPath: output))
        print("\(images.count) frames → \(output)")
    }
}

struct Icon: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Render the app icon: a globe caught unfolding.")

    @Option(name: .shortAndLong, help: "Output PNG file.")
    var output = "icon.png"

    @Option(help: "Size in pixels.")
    var size = 1024

    func run() throws {
        let engine = MapEngine()
        guard let layout = LayoutCatalog.layout(id: "geo-continents") else { return }
        let state = try engine.build(layout, parameters: layout.descriptor.defaultParameters, mesh: MeshSpec(.geodesic(frequency: 24)))
        let renderer = try MapRenderer()
        var style = Palette.vanWijk.light
        style.background = RGBA(hex: "#13233d")
        style.backface = RGBA(hex: "#0d1a2e")
        let inner = Int(Double(size) * 0.80)
        // The globe turned to Europe and Africa, a third of the way open.
        let frame = state.mesh.frames[state.projection.unfolding.root]
        let facing = Mat3(Vec3(frame.xAxis.x, frame.yAxis.x, frame.normal.x), Vec3(frame.xAxis.y, frame.yAxis.y, frame.normal.y),
                          Vec3(frame.xAxis.z, frame.yAxis.z, frame.normal.z))
        let tilt = Mat3.rotation(axis: .unitX, angle: -0.35) * Mat3.rotation(axis: .unitY, angle: 0.5)
        var settings = MapExport.settings(for: state, palette: .vanWijk, dark: false, width: inner, height: inner,
                                          unfold: 0.16, globe: tilt * facing)
        settings.style = style
        settings.viewport = Viewport(bounds: Rect2(minX: -1.55, minY: -1.55, maxX: 1.55, maxY: 1.55),
                                     size: Vec2(Double(inner), Double(inner)), center: Vec2(0.25, 0.1), margin: 0)
        settings.layers = [.land, .coastlines, .graticule]
        settings.lineScale = 2.2
        let map = try renderer.image(state, settings: settings, width: inner, height: inner)

        // Compose: a rounded square with a deep blue gradient, the globe on top.
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let s = Double(size), inset = s * 0.1, side = s - 2 * inset
        let rect = CGRect(x: inset, y: inset, width: side, height: side)
        let shape = CGPath(roundedRect: rect, cornerWidth: side * 0.225, cornerHeight: side * 0.225, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.45))
        ctx.addPath(shape)
        ctx.setFillColor(CGColor(srgbRed: 0.075, green: 0.137, blue: 0.239, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  colors: [CGColor(srgbRed: 0.13, green: 0.25, blue: 0.42, alpha: 1),
                                           CGColor(srgbRed: 0.05, green: 0.10, blue: 0.19, alpha: 1)] as CFArray,
                                  locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s - inset), end: CGPoint(x: 0, y: inset), options: [])
        let m = (s - Double(inner)) / 2
        ctx.setBlendMode(.lighten)
        ctx.draw(map, in: CGRect(x: m, y: m, width: Double(inner), height: Double(inner)))
        ctx.restoreGState()
        try MapExport.png(ctx.makeImage()!).write(to: URL(fileURLWithPath: output))
        print("icon → \(output)")
    }
}
