import Foundation

/// The geometry shared by every unfolding of one polyhedron: topology, face
/// frames and point location. Building it is the expensive step, so it is
/// kept separate from the choice of cuts.
public struct MyriahedralMesh: Sendable {
    public let polyhedron: Polyhedron
    public let topology: MeshTopology
    public let frames: [FaceFrame]
    public let locator: FaceLocator
    /// Per face, the visible polygon (cell) it belongs to.
    public let cells: [Int]
    /// Per edge: true when both faces belong to one cell. Such edges are
    /// always hinges and are not drawn as mesh lines.
    public let isInternalEdge: [Bool]
    /// Per edge, the weight its generator assigned (recursive subdivision),
    /// or nil when the generator has none.
    public let intrinsicWeights: [Double]?

    public init(_ build: MeshBuild) throws {
        let polyhedron = build.polyhedron
        self.polyhedron = polyhedron
        let topology = try MeshTopology(polyhedron)
        self.topology = topology
        frames = parallelMap(polyhedron.faceCount) { FaceFrame(vertices: polyhedron.faceVertices($0)) }
        locator = FaceLocator(polyhedron: polyhedron)
        cells = build.cells
        isInternalEdge = topology.edges.map { build.cells[$0.leftFace] == build.cells[$0.rightFace] }
        intrinsicWeights = build.edgeWeights.isEmpty ? nil
            : topology.edges.map { build.edgeWeights[EdgeKey.make($0.a, $0.b)] ?? 0 }
    }

    public init(_ polyhedron: Polyhedron) throws {
        try self.init(MeshBuild(polyhedron: polyhedron))
    }

    public init(_ spec: MeshSpec) throws {
        try self.init(spec.build())
    }

    public var faceCount: Int { polyhedron.faceCount }
    public var edgeCount: Int { topology.edgeCount }
    public var cellCount: Int { (cells.max() ?? -1) + 1 }

    /// Dual-graph edges as face pairs, indexed like `topology.edges`.
    public var dualEdges: [(Int, Int)] { topology.edges.map { ($0.leftFace, $0.rightFace) } }

    /// The face containing a sphere direction.
    public func face(containing v: Vec3) -> Int { locator.face(containing: v) }

    /// The hinges of the maximum spanning tree of `weights` (one per edge;
    /// heavier edges are kept as hinges, lighter ones cut). Edges inside a
    /// cell are always kept.
    public func hinges(weights: [Double]) -> [Bool] {
        precondition(weights.count == edgeCount, "one weight per edge")
        var w = weights
        for e in w.indices where isInternalEdge[e] { w[e] = .infinity }
        return SpanningTree.maximum(nodeCount: faceCount, edges: dualEdges, weights: w)
    }

    /// Unfolds the mesh with the maximum spanning tree of `weights`.
    public func unfold(weights: [Double], root: Int) -> MyriahedralProjection {
        MyriahedralProjection(mesh: self, hinges: hinges(weights: weights), root: root)
    }
}

/// A myriahedral projection: the globe mapped gnomonically onto the faces of a
/// polyhedron, which is then cut open along a set of edges and unfolded flat.
public struct MyriahedralProjection: Sendable {
    public let mesh: MyriahedralMesh
    public let unfolding: Unfolding
    /// Face polygons in map coordinates.
    public let mapPolygons: [[Vec2]]
    public let bounds: Rect2
    let mapIndex: MapIndex

    public init(mesh: MyriahedralMesh, hinges: [Bool], root: Int) {
        self.mesh = mesh
        let unfolding = Unfolding(frames: mesh.frames, polyhedron: mesh.polyhedron, topology: mesh.topology,
                                  hinges: hinges, root: root)
        self.unfolding = unfolding
        let polygons = (0..<mesh.faceCount).map { f in
            mesh.frames[f].localVertices.map(unfolding.transforms[f].apply)
        }
        mapPolygons = polygons
        var b = Rect2.empty
        for p in polygons { b.include(Rect2(bounding: p)) }
        bounds = b
        mapIndex = MapIndex(polygons: polygons, bounds: b)
    }

    public func transform(of face: Int) -> Rigid2D { unfolding.transforms[face] }

    /// Map position of a sphere direction, using the face that contains it.
    public func project(_ v: Vec3) -> (face: Int, point: Vec2) {
        let f = mesh.face(containing: v)
        let local = mesh.frames[f].gnomonic(v) ?? .zero
        return (f, unfolding.transforms[f].apply(local))
    }

    public func project(_ p: GeoPoint) -> Vec2 { project(p.unitVector).point }

    /// Map position of a sphere direction through a given face's projection
    /// (used to draw geometry that strays slightly across a face edge).
    public func project(_ v: Vec3, through face: Int) -> Vec2? {
        mesh.frames[face].gnomonic(v).map(unfolding.transforms[face].apply)
    }

    /// The globe location shown at map position `q`, if any face covers it.
    /// With `slack`, a point in a gap narrower than that (map units) belongs
    /// to the nearest face, as hairline slits do on screen.
    public func inverse(_ q: Vec2, slack: Double = 0) -> (face: Int, point: GeoPoint)? {
        func location(_ f: Int) -> (face: Int, point: GeoPoint) {
            let local = unfolding.transforms[f].inverse.apply(q)
            return (f, GeoPoint(mesh.frames[f].spherePoint(local)))
        }
        for f in mapIndex.candidates(q) where Planar.convexContains(mapPolygons[f], q, tolerance: 1e-12) {
            return location(f)
        }
        guard slack > 0 else { return nil }
        var best: (face: Int, distance: Double)?
        for probe in [Vec2(slack, 0), Vec2(-slack, 0), Vec2(0, slack), Vec2(0, -slack), .zero] {
            for f in mapIndex.candidates(q + probe) {
                let d = Planar.distanceOutside(mapPolygons[f], q)
                if d <= slack, d < best?.distance ?? .infinity { best = (f, d) }
            }
        }
        return best.map { location($0.face) }
    }

    /// Faces lying (partly) on top of another face: their centroid falls
    /// inside a face they are not. Van Wijk: fold-overs are rare.
    public func overlappingFaces() -> [Int] {
        (0..<mesh.faceCount).filter { f in
            let c = Planar.centroid(mapPolygons[f])
            return mapIndex.candidates(c).contains { g in
                g != f && Planar.convexContains(mapPolygons[g], c, tolerance: -1e-12)
            }
        }
    }

    /// Area fraction of the map covered by overlapping faces.
    public func overlapFraction() -> Double {
        let total = (0..<mesh.faceCount).reduce(0.0) { $0 + mesh.frames[$1].area }
        return overlappingFaces().reduce(0.0) { $0 + mesh.frames[$1].area } / max(total, 1e-300)
    }

    /// Edges where the map is cut open.
    public var cutEdges: [Int] { unfolding.isCut.indices.filter { unfolding.isCut[$0] } }

    /// Both map segments of a cut edge: one per adjacent face.
    public func mapSegments(ofEdge e: Int) -> [(Vec2, Vec2)] {
        let edge = mesh.topology.edges[e]
        return [edge.leftFace, edge.rightFace].map { f in
            let face = mesh.polyhedron.faces[f]
            let ia = face.firstIndex(of: edge.a)!, ib = face.firstIndex(of: edge.b)!
            return (mapPolygons[f][ia], mapPolygons[f][ib])
        }
    }
}

/// Uniform grid over map space for locating faces by map position.
struct MapIndex: Sendable {
    let bounds: Rect2
    let cols: Int
    let rows: Int
    let cells: [[Int32]]

    init(polygons: [[Vec2]], bounds: Rect2) {
        let n = max(polygons.count, 1)
        let side = max(1, Int(Double(n).squareRoot() * 0.75))
        let aspect = bounds.width / max(bounds.height, 1e-12)
        cols = max(1, Int(Double(side) * aspect.squareRoot()))
        rows = max(1, Int(Double(side) / aspect.squareRoot()))
        self.bounds = bounds
        var cells = Array(repeating: [Int32](), count: cols * rows)
        for (f, poly) in polygons.enumerated() {
            let r = Rect2(bounding: poly)
            let (c0, r0) = MapIndex.cell(Vec2(r.minX, r.minY), bounds, cols, rows)
            let (c1, r1) = MapIndex.cell(Vec2(r.maxX, r.maxY), bounds, cols, rows)
            for row in r0...r1 {
                for col in c0...c1 { cells[row * cols + col].append(Int32(f)) }
            }
        }
        self.cells = cells
    }

    static func cell(_ p: Vec2, _ b: Rect2, _ cols: Int, _ rows: Int) -> (Int, Int) {
        let cx = Int(((p.x - b.minX) / max(b.width, 1e-12) * Double(cols)).rounded(.down))
        let cy = Int(((p.y - b.minY) / max(b.height, 1e-12) * Double(rows)).rounded(.down))
        return (min(cols - 1, max(0, cx)), min(rows - 1, max(0, cy)))
    }

    func candidates(_ q: Vec2) -> [Int] {
        guard bounds.contains(q) else { return [] }
        let (c, r) = MapIndex.cell(q, bounds, cols, rows)
        return cells[r * cols + c].map(Int.init)
    }
}
