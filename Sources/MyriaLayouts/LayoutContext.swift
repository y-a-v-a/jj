import Foundation
import MyriaCore
import MyriaData

/// Geometry of one edge of the mesh as layouts see it.
public struct EdgeInfo: Sendable {
    /// Midpoint of the edge on the sphere.
    public let midpoint: Vec3
    /// 1 when the edge is crossed travelling east–west, 0 north–south.
    public let eastWestness: Double
    /// Unit tangent at the midpoint pointing from the left face's centre to
    /// the right face's centre: the direction a hinge holds faces together.
    public let crossing: Vec3
    /// Arc length of the edge (radians on the unit sphere).
    public let length: Double
}

/// A myriahedron prepared for layouts: lazily computed, cached geometry and
/// geographic samples. One context serves every layout cut on its mesh.
public final class LayoutContext: Sendable {
    public let spec: MeshSpec
    public let mesh: MyriahedralMesh
    public let data: BodyData
    private let store = OnceCache()

    public init(spec: MeshSpec, mesh: MyriahedralMesh, data: BodyData) {
        self.spec = spec
        self.mesh = mesh
        self.data = data
    }

    public convenience init(spec: MeshSpec, data: BodyData) throws {
        self.init(spec: spec, mesh: try MyriahedralMesh(spec.build()), data: data)
    }

    public func cached<T: Sendable>(_ key: String, _ load: () throws -> T) rethrows -> T {
        try store.value(key, load)
    }

    public func isCached(_ key: String) -> Bool { store.contains(key) }

    public func hasFaceRegions(_ dataset: DatasetID) -> Bool { isCached("faceRegions:\(dataset)") }

    // MARK: Geometry

    public var faceCenters: [Vec3] {
        cached("faceCenters") { (0..<mesh.faceCount).map { mesh.polyhedron.faceCenter($0) } }
    }

    public var faceLocations: [GeoPoint] {
        cached("faceLocations") { faceCenters.map(GeoPoint.init) }
    }

    public var edges: [EdgeInfo] {
        cached("edges") {
            let centers = faceCenters, p = mesh.polyhedron
            return mesh.topology.edges.map { edge in
                let a = p.vertices[edge.a], b = p.vertices[edge.b]
                let mid = (a + b).normalized
                let (east, north) = Spherical.tangentFrame(at: mid)
                let d = centers[edge.rightFace] - centers[edge.leftFace]
                let tangent = (d - mid * d.dot(mid)).normalized
                let de = tangent.dot(east), dn = tangent.dot(north)
                return EdgeInfo(midpoint: mid, eastWestness: de * de / max(de * de + dn * dn, 1e-300),
                                crossing: tangent, length: a.angle(to: b))
            }
        }
    }

    /// The edge shared by two faces, if they are neighbours.
    public func edge(between f: Int, _ g: Int) -> Int? {
        cached("edgeBetween") {
            var map: [UInt64: Int] = [:]
            map.reserveCapacity(mesh.edgeCount)
            for (e, edge) in mesh.topology.edges.enumerated() { map[EdgeKey.make(edge.leftFace, edge.rightFace)] = e }
            return map
        }[EdgeKey.make(f, g)]
    }

    /// The face containing a location.
    public func face(at p: GeoPoint) -> Int { mesh.face(containing: p.unitVector) }

    /// Sample points inside each face: its centre (counted twice) and a
    /// point two thirds of the way to each corner.
    var faceSamplePoints: [[Vec3]] {
        cached("faceSamplePoints") {
            (0..<mesh.faceCount).map { f in
                let frame = mesh.frames[f]
                var points = [frame.spherePoint(.zero), frame.spherePoint(.zero)]
                for v in frame.localVertices { points.append(frame.spherePoint(v * (2.0 / 3))) }
                return points
            }
        }
    }

    // MARK: Fields

    /// A field sampled at every face centre.
    public func faceValues(_ key: FieldKey) throws -> [Double] {
        try cached("faceValues:\(key)") {
            let field = try data.field(key)
            let centers = faceCenters
            return parallelMap(mesh.faceCount) { field.value(at: centers[$0]) }
        }
    }

    /// A field sampled at every edge midpoint.
    public func edgeValues(_ key: FieldKey) throws -> [Double] {
        try cached("edgeValues:\(key)") {
            let field = try data.field(key)
            return edgeValues(of: field)
        }
    }

    /// Any field sampled at every edge midpoint (not cached).
    public func edgeValues(of field: some SphereField) -> [Double] {
        let edges = self.edges
        return parallelMap(edges.count) { field.value(at: edges[$0].midpoint) }
    }

    // MARK: Land and regions

    /// Whether some cells hold several faces (hexagons, subdivided cubes).
    var hasCompositeCells: Bool { mesh.cellCount < mesh.faceCount }

    /// Faces of each cell.
    var cellFaces: [[Int]] {
        cached("cellFaces") {
            var faces = Array(repeating: [Int](), count: mesh.cellCount)
            for (f, c) in mesh.cells.enumerated() { faces[c].append(f) }
            return faces
        }
    }

    /// Fraction of each face that is land, from 8 samples per face; faces of
    /// one cell share their cell's (area-weighted) value, since cells are
    /// never cut apart.
    public func landFraction() throws -> [Double] {
        try cached("landFraction") {
            let land = try data.land()
            let samples = faceSamplePoints
            var fraction = parallelMap(mesh.faceCount) { f in
                let points = samples[f]
                return Double(points.filter { land.isLand(GeoPoint($0)) }.count) / Double(points.count)
            }
            if hasCompositeCells {
                for faces in cellFaces where faces.count > 1 {
                    let area = faces.reduce(0) { $0 + mesh.frames[$1].area }
                    let mean = faces.reduce(0) { $0 + fraction[$1] * mesh.frames[$1].area } / max(area, 1e-300)
                    for f in faces { fraction[f] = mean }
                }
            }
            return fraction
        }
    }

    /// The region of a polygon dataset covering most of each face (by
    /// sampling), or -1 where none does.
    public func faceRegions(_ dataset: DatasetID) throws -> [Int] {
        try cached("faceRegions:\(dataset)") {
            let regions = try dataset == .timeZones ? data.timeZones().regions : data.regions(dataset)
            let samples = faceSamplePoints
            let composite = hasCompositeCells
            let cells = mesh.cells, faces = composite ? cellFaces : []
            return parallelMap(mesh.faceCount) { f in
                var votes: [Int: Int] = [:]
                // A cell votes as a whole.
                for g in composite ? faces[cells[f]] : [f] {
                    for p in samples[g] { votes[regions.polygons.feature(at: GeoPoint(p)) ?? -1, default: 0] += 1 }
                }
                return votes.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? -1
            }
        }
    }

    /// Per edge, whether one of the given polylines crosses it, i.e. runs
    /// between the two faces. Following a polyline in small steps, every
    /// change of face marks the edge between the faces.
    public func edgesCrossed(by layer: SegmentLayer, where include: (Int32) -> Bool = { _ in true }) -> [Bool] {
        var crossed = Array(repeating: false, count: mesh.edgeCount)
        let typical = (4 * Double.pi / Double(mesh.faceCount)).squareRoot()
        let step = typical / 6
        var last = -1
        var lastPoint = Vec3.zero
        for (i, s) in layer.segments.enumerated() where include(layer.attributes[i]) {
            let n = max(1, Int((s.a.angle(to: s.b) / step).rounded(.up)))
            for k in 0...n {
                let p = Spherical.slerp(s.a, s.b, Double(k) / Double(n))
                let f = mesh.face(containing: p)
                // A new polyline starts where the previous segment did not end.
                if k == 0, (p - lastPoint).length > 1e-9 { last = -1 }
                if last >= 0, f != last {
                    if let e = edge(between: last, f) {
                        crossed[e] = true
                    } else {
                        // Jumped across a corner: walk the gap in finer steps.
                        markFinely(from: lastPoint, to: p, crossed: &crossed)
                    }
                }
                last = f
                lastPoint = p
            }
        }
        return crossed
    }

    private func markFinely(from a: Vec3, to b: Vec3, crossed: inout [Bool]) {
        var last = mesh.face(containing: a)
        for k in 1...16 {
            let f = mesh.face(containing: Spherical.slerp(a, b, Double(k) / 16))
            if f != last, let e = edge(between: last, f) { crossed[e] = true }
            last = f
        }
    }

    // MARK: Pieces

    /// The connected pieces of faces with equal labels: faces joined across
    /// edges where both sides carry the same label (labels ≥ 0).
    public func components(of labels: [Int], joinedBy keep: (Int) -> Bool = { _ in true }) -> [Int] {
        var sets = UnionFind(count: mesh.faceCount)
        for (e, edge) in mesh.topology.edges.enumerated()
        where labels[edge.leftFace] == labels[edge.rightFace] && keep(e) {
            sets.union(edge.leftFace, edge.rightFace)
        }
        var ids: [Int: Int] = [:]
        return (0..<mesh.faceCount).map { f in
            let r = sets.find(f)
            if let id = ids[r] { return id }
            ids[r] = ids.count
            return ids.count - 1
        }
    }
}
