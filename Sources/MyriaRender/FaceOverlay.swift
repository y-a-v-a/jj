import Foundation
import MyriaCore
import MyriaData

/// Triangles of polygon data inside the faces, in face-local coordinates.
public struct FillOverlay: Sendable {
    /// Three positions per triangle.
    public var positions: [Vec2] = []
    /// Per vertex, the face it lies in.
    public var faces: [Int32] = []
    /// Per vertex, the feature (region index) it belongs to.
    public var features: [Int32] = []

    public var triangleCount: Int { positions.count / 3 }

    mutating func append(_ other: FillOverlay) {
        positions += other.positions
        faces += other.faces
        features += other.features
    }
}

/// Line segments inside the faces, in face-local coordinates.
public struct LineOverlay: Sendable {
    public var a: [Vec2] = []
    public var b: [Vec2] = []
    public var faces: [Int32] = []
    /// Per segment, the attribute of its source line (rank, kind, …).
    public var attributes: [Int32] = []

    public var count: Int { a.count }

    mutating func append(_ other: LineOverlay) {
        a += other.a
        b += other.b
        faces += other.faces
        attributes += other.attributes
    }
}

/// Points placed in faces.
public struct PointOverlay: Sendable {
    public var positions: [Vec2] = []
    public var faces: [Int32] = []
    /// Per point, the index of the source item.
    public var items: [Int32] = []
}

/// Clips spherical geometry to one face and returns local coordinates.
struct FaceClipper {
    let frame: FaceFrame
    let center: Vec3
    let radiusDegrees: Double
    let area: Double
    /// Pre-clip cap around the face normal; keeps gnomonic projection finite.
    let capCosine: Double

    init(frame: FaceFrame, vertices: [Vec3]) {
        self.frame = frame
        center = frame.normal
        let radius = vertices.map { frame.normal.angle(to: $0) }.max() ?? 0
        radiusDegrees = radius * 180 / .pi
        area = frame.area
        capCosine = cos(min(max(radius * 1.5, 3 * .pi / 180), 80 * .pi / 180))
    }

    func clipPolygon(_ ring: [Vec3]) -> [Vec2] {
        let capped = SphericalClip.clipRing(ring, axis: frame.normal, minimumCosine: capCosine)
        guard capped.count >= 3 else { return [] }
        let local = capped.compactMap { frame.gnomonic($0, minimumCosine: 0) }
        guard local.count == capped.count else { return [] }
        return Planar.clip(local, toConvex: frame.localVertices)
    }

    /// Clips the given segments, appending local segments to `out`.
    func clipSegments(_ layer: SegmentLayer, indices: [Int], face: Int32, into out: inout LineOverlay) {
        for i in indices {
            let s = layer.segments[i]
            var a = s.a, b = s.b
            let da = frame.normal.dot(a) - capCosine, db = frame.normal.dot(b) - capCosine
            if da < 0 && db < 0 { continue }
            if da < 0 { a = (a + (b - a) * (da / (da - db))).normalized }
            if db < 0 { b = (a + (b - a) * (da / (da - db))).normalized }
            guard let la = frame.gnomonic(a, minimumCosine: 0), let lb = frame.gnomonic(b, minimumCosine: 0),
                  let (p, q) = Planar.clipSegment(la, lb, toConvex: frame.localVertices),
                  (q - p).lengthSquared > 1e-24
            else { continue }
            out.a.append(p)
            out.b.append(q)
            out.faces.append(face)
            out.attributes.append(layer.attributes[i])
        }
    }
}

/// Everything drawn on one mesh that does not depend on the cuts: polygon
/// fills, lines and points per face. Built lazily per layer and kept.
public final class MeshOverlays: Sendable {
    public let mesh: MyriahedralMesh
    public let data: BodyData
    private let store = OnceCache()

    public init(mesh: MyriahedralMesh, data: BodyData) {
        self.mesh = mesh
        self.data = data
    }

    var clippers: [FaceClipper] {
        store.value("clippers") {
            (0..<mesh.faceCount).map { FaceClipper(frame: mesh.frames[$0], vertices: mesh.polyhedron.faceVertices($0)) }
        }
    }

    /// Tiles (of the 5° grid every layer uses) near each face.
    var faceTiles: [[Int]] {
        store.value("faceTiles") {
            let grid = TileGrid(size: 5)
            return clippers.map { c in grid.tiles(aroundCap: GeoPoint(c.center), radius: c.radiusDegrees * 1.05 + 1e-6) }
        }
    }

    public func isBuilt(_ key: String) -> Bool { store.contains(key) }

    // MARK: Fills

    /// Polygon fills: land, lakes or the regions of a dataset.
    public func fills(_ dataset: DatasetID) throws -> FillOverlay {
        try store.value("fills:\(dataset)") {
            let layer: PolygonLayer = switch dataset {
            case .land: try data.land().polygons
            case .timeZones: try data.timeZones().regions.polygons
            default: try data.regions(dataset).polygons
            }
            return fills(of: layer)
        }
    }

    func fills(of layer: PolygonLayer) -> FillOverlay {
        let clippers = self.clippers, tiles = faceTiles, mesh = self.mesh
        let perFace = parallelMap(mesh.faceCount) { f -> FillOverlay in
            let clip = clippers[f]
            let frame = clip.frame
            let corners = mesh.polyhedron.faceVertices(f)
            // Inward normals of the face's edge planes, for quick rejection.
            let edgeNormals = corners.indices.map { corners[$0].cross(corners[($0 + 1) % corners.count]) }
            var out = FillOverlay()
            var covered: [Int32: Double] = [:]
            var pieces: [(feature: Int32, polygon: [Vec2])] = []
            for chunk in layer.chunks(inTiles: tiles[f]) {
                let t = chunk.triangles
                var k = 0
                while k + 2 < t.count {
                    let a = t[k], b = t[k + 1], c = t[k + 2]
                    k += 3
                    if frame.normal.dot(a) < clip.capCosine && frame.normal.dot(b) < clip.capCosine
                        && frame.normal.dot(c) < clip.capCosine { continue }
                    if edgeNormals.contains(where: { $0.dot(a) < 0 && $0.dot(b) < 0 && $0.dot(c) < 0 }) { continue }
                    guard let la = frame.gnomonic(a), let lb = frame.gnomonic(b), let lc = frame.gnomonic(c) else { continue }
                    let polygon = Planar.clip([la, lb, lc], toConvex: frame.localVertices)
                    let area = Planar.signedArea(polygon)
                    guard polygon.count >= 3, area > clip.area * 1e-12 else { continue }
                    covered[Int32(chunk.feature), default: 0] += area
                    pieces.append((Int32(chunk.feature), polygon))
                }
            }
            // A feature covering the whole face is drawn as the face itself.
            if let full = covered.first(where: { $0.value >= clip.area * (1 - 1e-6) })?.key {
                Self.appendFace(f, feature: full, mesh: mesh, into: &out)
                return out
            }
            for piece in pieces {
                // Convex: a fan.
                let p = piece.polygon
                for i in 1..<(p.count - 1) {
                    for q in [p[0], p[i], p[i + 1]] {
                        out.positions.append(q)
                        out.faces.append(Int32(f))
                        out.features.append(piece.feature)
                    }
                }
            }
            return out
        }
        var all = FillOverlay()
        all.positions.reserveCapacity(perFace.reduce(0) { $0 + $1.positions.count })
        for part in perFace { all.append(part) }
        return all
    }

    static func appendFace(_ f: Int, feature: Int32, mesh: MyriahedralMesh, into out: inout FillOverlay) {
        let v = mesh.frames[f].localVertices
        for k in 1..<(v.count - 1) {
            for p in [v[0], v[k], v[k + 1]] {
                out.positions.append(p)
                out.faces.append(Int32(f))
                out.features.append(feature)
            }
        }
    }

    // MARK: Lines

    /// Segments of a line layer clipped to every face.
    public func lines(_ key: String, _ layer: @autoclosure () throws -> SegmentLayer) rethrows -> LineOverlay {
        try store.value("lines:\(key)") { clip(try layer()) }
    }

    public func coastlines() throws -> LineOverlay {
        try lines("coastlines", try data.land().coastlines)
    }

    /// Lines of a dataset: rivers, plate boundaries, country borders, or the
    /// borders between regions of a polygon dataset.
    public func lines(_ dataset: DatasetID) throws -> LineOverlay {
        try store.value("lines:\(dataset)") {
            switch dataset {
            case .timeZones: clip(try data.timeZones().regions.borders)
            case .rivers, .plateBoundaries, .countryBorders: clip(try data.lines(dataset).segments)
            case .lakes: clip(SegmentLayer(polylines: try data.regions(.lakes).regions.isEmpty ? [] : lakeShores()))
            default: clip(try data.regions(dataset).borders)
            }
        }
    }

    private func lakeShores() throws -> [[Vec2]] {
        let lakes = try data.regions(.lakes)
        var rings: [[Vec2]] = []
        for tile in lakes.polygons.tiles {
            for chunk in tile { rings += chunk.rings }
        }
        return SegmentLayer.polylines(fromRings: rings) { !SegmentLayer.isArtificial($0, $1) }
    }

    func clip(_ layer: SegmentLayer) -> LineOverlay {
        let clippers = self.clippers, tiles = faceTiles
        let perFace = parallelMap(mesh.faceCount) { f -> LineOverlay in
            var out = LineOverlay()
            clippers[f].clipSegments(layer, indices: layer.segmentIndices(inTiles: tiles[f]), face: Int32(f), into: &out)
            return out
        }
        var all = LineOverlay()
        for part in perFace { all.append(part) }
        return all
    }

    /// Great-circle arcs of the busiest air routes; the attribute is the
    /// number of airlines flying the route.
    public func flightArcs(limit: Int = 6000) throws -> LineOverlay {
        try store.value("lines:flights:\(limit)") {
            let network = try data.flights()
            let routes = network.routes.sorted { $0.count > $1.count }.prefix(limit)
            var polylines: [[Vec2]] = []
            var attributes: [Int32] = []
            for route in routes {
                let arc = network.arc(route, step: 0.01).map { p -> Vec2 in
                    let g = GeoPoint(p)
                    return Vec2(g.longitude, g.latitude)
                }
                polylines.append(arc)
                attributes.append(Int32(route.count))
            }
            return clip(SegmentLayer(polylines: polylines, attributes: attributes))
        }
    }

    /// Tissot's indicatrices: small circles of `radius` degrees every
    /// `spacing` degrees. On a myriahedral map they stay round.
    public func tissot(spacing: Double = 30, radius: Double = 4) -> LineOverlay {
        store.value("lines:tissot:\(spacing):\(radius)") {
            var circles: [[Vec2]] = []
            for lat in stride(from: -90 + spacing / 2, through: 90 - spacing / 2, by: spacing) {
                for lon in stride(from: -180.0, to: 180, by: spacing) {
                    let c = GeoPoint(latitude: lat, longitude: lon).unitVector
                    let (east, north) = Spherical.tangentFrame(at: c)
                    let r = radius * .pi / 180
                    let ring: [Vec2] = (0...72).map { k in
                        let t = Double(k) / 72 * 2 * .pi
                        let p = (c * cos(r) + (east * cos(t) + north * sin(t)) * sin(r)).normalized
                        let g = GeoPoint(p)
                        return Vec2(g.longitude, g.latitude)
                    }
                    // Split where the circle crosses the antimeridian.
                    var current: [Vec2] = []
                    for p in ring {
                        if let last = current.last, abs(p.x - last.x) > 180 {
                            circles.append(current)
                            current = []
                        }
                        current.append(p)
                    }
                    circles.append(current)
                }
            }
            return clip(SegmentLayer(polylines: circles))
        }
    }

    // MARK: Points

    /// Cities, each placed in its face.
    public func cities(limit: Int = 600) throws -> PointOverlay {
        try store.value("points:cities:\(limit)") {
            let places = try data.places().places.prefix(limit)
            return place(places.map(\.location.unitVector))
        }
    }

    public func airports(limit: Int = 800) throws -> PointOverlay {
        try store.value("points:airports:\(limit)") {
            place(try data.flights().airports.prefix(limit).map(\.location.unitVector))
        }
    }

    public func place(_ points: [Vec3]) -> PointOverlay {
        var out = PointOverlay()
        for (i, p) in points.enumerated() {
            let f = mesh.face(containing: p)
            guard let local = mesh.frames[f].gnomonic(p) else { continue }
            out.positions.append(local)
            out.faces.append(Int32(f))
            out.items.append(Int32(i))
        }
        return out
    }
}
