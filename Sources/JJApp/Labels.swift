import CoreGraphics
import Foundation
import MyriaCore
import MyriaData
import MyriaLayouts
import MyriaRender

/// Where names and clocks go on an unfolded map.
enum LabelPlacer {
    static func labels(for state: MapState, coloring: LayoutAppearance.Coloring, layers: Set<LayerID>) -> [MapLabel] {
        var labels: [MapLabel] = []
        let data = state.data
        let typical = (4 * Double.pi / Double(state.mesh.faceCount)).squareRoot()

        func deepest(_ groups: [Int]) -> [Int: (face: Int, depth: Int, size: Int)] {
            deepestFaces(state, groups: groups)
        }

        switch state.layout.id {
        case "timezones":
            // A live clock in every zone piece.
            if let groups = state.cut.faceGroups, let atlas = try? data.timeZones() {
                let regions = (try? state.context.faceRegions(.timeZones)) ?? []
                let grouping = state.parameters.index("grouping")
                for (group, d) in deepest(groups) where d.depth >= 1 {
                    let region = regions.indices.contains(d.face) && regions[d.face] >= 0 ? regions[d.face] : group
                    guard atlas.zones.indices.contains(region) else { continue }
                    let zone = atlas.zones[region]
                    labels.append(MapLabel(id: labels.count, kind: .clock, position: center(state, d.face),
                                           text: grouping == 1 ? zone.offsetLabel(at: state.parameters.date) : zone.placeName,
                                           room: (Double(d.depth) + 0.5) * typical, timeZone: zone.timeZone))
                }
            }
        case "tectonic":
            if let groups = state.cut.faceGroups, let plates = try? data.regions(.plates) {
                for (g, d) in deepest(groups) where plates.regions.indices.contains(g) && d.depth >= 1 {
                    labels.append(MapLabel(id: labels.count, kind: .region, position: center(state, d.face),
                                           text: plates.regions[g].name, room: (Double(d.depth) + 0.5) * typical, timeZone: nil))
                }
            }
        case "coastline", "rivers":
            // The oceans' names.
            let basins = state.context.faceLocations.map { OceanBasin($0).rawValue }
            let land = (try? state.context.landFraction()) ?? []
            let sea = basins.indices.map { land.indices.contains($0) && land[$0] < 0.5 ? basins[$0] : -1 }
            for (b, d) in deepest(sea) where b >= 0 && d.depth >= 3 {
                labels.append(MapLabel(id: labels.count, kind: .ocean, position: center(state, d.face),
                                       text: OceanBasin(rawValue: b)!.title.uppercased(), room: Double(d.depth) * typical, timeZone: nil))
            }
        default:
            break
        }

        if case .regions(.countries) = coloring, let countries = try? data.regions(.countries) {
            let faces = (try? state.context.faceRegions(.countries)) ?? []
            var count = [Int: Int]()
            for r in faces where r >= 0 { count[r, default: 0] += 1 }
            for region in countries.regions {
                guard let n = count[region.id], n >= 2, let point = region.labelPoint else { continue }
                labels.append(MapLabel(id: labels.count, kind: .region, position: state.projection.project(point),
                                       text: region.name, room: Double(n).squareRoot() * typical * 0.6, timeZone: nil))
            }
        }

        if data.body.has(.features), let features = try? data.features() {
            // Named features, largest first; smaller ones appear as the map is zoomed.
            let typicalKm = typical * data.body.radius
            for feature in features.features.prefix(400) {
                labels.append(MapLabel(id: labels.count, kind: .region, position: state.projection.project(feature.location),
                                       text: feature.name, room: max(feature.diameter / typicalKm, 1) * typical * 0.5, timeZone: nil))
            }
        }

        if layers.contains(.cities), data.body.has(.places), let places = try? data.places() {
            for place in places.places.prefix(300) {
                labels.append(MapLabel(id: labels.count, kind: .city, position: state.projection.project(place.location),
                                       text: place.name, room: typical * max(0.6, 2.4 - 0.25 * Double(place.rank)), timeZone: nil))
            }
        }
        return labels
    }

    static func center(_ state: MapState, _ face: Int) -> Vec2 {
        Planar.centroid(state.projection.mapPolygons[face])
    }

    /// Per group, the face deepest inside its largest piece (hops to the
    /// piece's border), preferring faces near the equator.
    static func deepestFaces(_ state: MapState, groups: [Int]) -> [Int: (face: Int, depth: Int, size: Int)] {
        let mesh = state.mesh, isCut = state.projection.unfolding.isCut
        let pieces = state.context.components(of: groups) { !isCut[$0] }
        var pieceSize = [Int: Int]()
        for p in pieces { pieceSize[p, default: 0] += 1 }
        // Largest piece per group.
        var best = [Int: Int]()
        for f in groups.indices where groups[f] >= 0 {
            let g = groups[f], p = pieces[f]
            if let current = best[g], pieceSize[current]! >= pieceSize[p]! { continue }
            best[g] = p
        }
        // Depth inside pieces.
        var depth = Array(repeating: -1, count: mesh.faceCount)
        var queue: [Int] = []
        for f in 0..<mesh.faceCount where groups[f] >= 0 {
            let border = mesh.topology.faceEdges[f].contains { e in
                let g = mesh.topology.edges[e].otherFace(f)
                return pieces[g] != pieces[f]
            }
            if border {
                depth[f] = 0
                queue.append(f)
            }
        }
        var head = 0
        while head < queue.count {
            let f = queue[head]
            head += 1
            for g in mesh.topology.neighbors(of: f) where pieces[g] == pieces[f] && depth[g] < 0 {
                depth[g] = depth[f] + 1
                queue.append(g)
            }
        }
        let z = state.context.faceCenters.map { abs($0.z) }
        var result = [Int: (face: Int, depth: Int, size: Int)]()
        for f in 0..<mesh.faceCount where groups[f] >= 0 && best[groups[f]] == pieces[f] {
            let g = groups[f]
            if let current = result[g] {
                if depth[f] < current.depth || (depth[f] == current.depth && z[f] >= z[current.face]) { continue }
            }
            result[g] = (f, depth[f], pieceSize[pieces[f]]!)
        }
        return result
    }
}

/// Small renders of every layout for the gallery.
enum Thumbnails {
    nonisolated(unsafe) static var engines: [String: MapEngine] = [:]
    nonisolated(unsafe) static var renderer: MapRenderer? = try? MapRenderer(sampleCount: 4)
    static let lock = NSLock()

    static func coarse(_ kind: MeshKind) -> MeshKind {
        switch kind {
        case .graticule(let step): .graticule(step: max(step, 3))
        case .geodesic(let n): .geodesic(frequency: min(n, 20))
        case .platonic(let solid, let levels): .platonic(solid, levels: min(levels, 3))
        case .hexagonal(let n): .hexagonal(frequency: min(n, 12))
        }
    }

    static func render(_ layout: any MapLayout, body: CelestialBody, palette: Palette, dark: Bool) -> CGImage? {
        lock.lock()
        defer { lock.unlock() }
        guard let renderer else { return nil }
        let engine = engines[body.id] ?? MapEngine(data: BodyData.of(body), capacity: 4)
        engines[body.id] = engine
        let d = layout.descriptor
        guard let state = try? engine.build(layout, parameters: layout.defaultParameters(for: body), mesh: MeshSpec(coarse(d.preferredMesh)))
        else { return nil }
        let (w, h) = (360, 220)
        var settings = MapExport.settings(for: state, palette: palette, dark: dark, width: w, height: h)
        settings.viewport.margin = 8
        settings.lineScale = 0.5
        settings.layers.subtract([.cities, .lakes, .rivers, .flights])
        return try? renderer.image(state, settings: settings, width: w, height: h)
    }
}
