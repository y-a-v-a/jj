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
        subcommands: [Layouts.self, Render.self, Stats.self, Gallery.self, Animate.self])
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
