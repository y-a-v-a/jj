import Foundation

/// A key for an undirected edge between two vertex indices.
public enum EdgeKey {
    @inlinable public static func make(_ a: Int, _ b: Int) -> UInt64 {
        UInt64(min(a, b)) << 32 | UInt64(max(a, b))
    }
}

/// A generated myriahedron: the polyhedron plus structure that only its
/// generator knows.
public struct MeshBuild: Sendable {
    public var polyhedron: Polyhedron
    /// Per face, the cell (visible polygon) it belongs to. A polygon that is
    /// not planar is split into triangles of one cell; van Wijk: "faces with
    /// more edges can be handled by inserting interior edges with very high
    /// weights, such that these faces are never split up".
    public var cells: [Int]
    /// Weights the generator assigns to edges, keyed by `EdgeKey`
    /// (recursive subdivision's w_c). Empty when the generator has none.
    public var edgeWeights: [UInt64: Double]

    public init(polyhedron: Polyhedron, cells: [Int]? = nil, edgeWeights: [UInt64: Double] = [:]) {
        self.polyhedron = polyhedron
        self.cells = cells ?? Array(0..<polyhedron.faceCount)
        self.edgeWeights = edgeWeights
    }

    /// Rotates the whole build (cells and weights are unaffected).
    public func rotated(by rotation: Mat3) -> MeshBuild {
        var copy = self
        copy.polyhedron = polyhedron.rotated(by: rotation)
        return copy
    }
}

/// The kinds of myriahedra JJ can build.
public enum MeshKind: Hashable, Sendable, Codable {
    /// Latitude/longitude cells of `step` degrees with triangle fans at the
    /// poles (van Wijk's graticular meshes: 5° gives 2592 polygons, 1° 64 800).
    case graticule(step: Double)
    /// An icosahedron whose faces are divided into `frequency²` triangles.
    case geodesic(frequency: Int)
    /// A Platonic solid, recursively subdivided `levels` times (each level
    /// splits every edge at its great-circle midpoint).
    case platonic(PlatonicSolid, levels: Int)
    /// Hexagons (and twelve pentagons): the dual of the geodesic sphere of
    /// this frequency, every cell a fan of triangles that is never cut.
    case hexagonal(frequency: Int)

    public func build() -> MeshBuild {
        switch self {
        case .graticule(let step):
            MeshBuild(polyhedron: .graticule(latitudeStep: step, longitudeStep: step))
        case .geodesic(let n):
            MeshBuild(polyhedron: .geodesic(frequency: n))
        case .platonic(let solid, let levels):
            RecursiveSubdivision.build(solid.polyhedron(), levels: levels)
        case .hexagonal(let n):
            Self.hexagons(frequency: n)
        }
    }

    /// The dual of a geodesic sphere: one cell per geodesic vertex, its
    /// corners at the centroids of the triangles around it. Cells are not
    /// planar, so each is split by diagonals into triangles of one cell.
    /// Diagonals, not spokes: a centre vertex would have to be reached by a
    /// cut, opening every cell at its middle.
    static func hexagons(frequency n: Int) -> MeshBuild {
        let geo = Polyhedron.geodesic(frequency: n)
        var around = Array(repeating: [Int](), count: geo.vertexCount)
        for (t, face) in geo.faces.enumerated() { for v in face { around[v].append(t) } }
        let centroids = geo.faces.map { $0.reduce(Vec3.zero) { $0 + geo.vertices[$1] }.normalized }
        var faces: [[Int]] = []
        var cells: [Int] = []
        for v in 0..<geo.vertexCount {
            let c = geo.vertices[v]
            let (east, north) = Spherical.tangentFrame(at: c)
            let ring = around[v].sorted { a, b in
                atan2(centroids[a].dot(north), centroids[a].dot(east)) < atan2(centroids[b].dot(north), centroids[b].dot(east))
            }
            if ring.count == 6 {
                // A central triangle and three ears: well-shaped pieces.
                for tri in [[0, 2, 4], [0, 1, 2], [2, 3, 4], [4, 5, 0]] {
                    faces.append(tri.map { ring[$0] })
                    cells.append(v)
                }
            } else {
                for k in 1..<(ring.count - 1) {
                    faces.append([ring[0], ring[k], ring[k + 1]])
                    cells.append(v)
                }
            }
        }
        return MeshBuild(polyhedron: Polyhedron(vertices: centroids, faces: faces), cells: cells)
    }

    /// Number of visible polygons (cells).
    public var cellCount: Int {
        switch self {
        case .graticule(let step):
            let rows = max(2, Int((180 / step).rounded())), cols = max(3, Int((360 / step).rounded()))
            return rows * cols
        case .geodesic(let n):
            return 20 * n * n
        case .platonic(let solid, let levels):
            let perFace = solid == .dodecahedron && levels > 0 ? 5 * Int(pow(4.0, Double(levels - 1))) : Int(pow(4.0, Double(levels)))
            return solid.faceCount * perFace
        case .hexagonal(let n):
            return 10 * n * n + 2
        }
    }

    public var title: String {
        switch self {
        case .graticule(let s): "Graticule \(Self.format(s))°"
        case .geodesic(let n): "Geodesic \(n)"
        case .platonic(let solid, let levels): levels == 0 ? solid.title : "\(solid.title) ×\(levels)"
        case .hexagonal(let n): "Hexagons \(n)"
        }
    }

    public var detail: String { "\(cellCount.formatted()) polygons" }

    /// Parses "graticule:2.5", "geodesic:40" or "platonic:icosahedron:4".
    public init?(argument: String) {
        let parts = argument.split(separator: ":").map(String.init)
        switch parts.first {
        case "graticule":
            guard parts.count == 2, let s = Double(parts[1]), s > 0, s <= 45 else { return nil }
            self = .graticule(step: s)
        case "geodesic":
            guard parts.count == 2, let n = Int(parts[1]), n > 0, n <= 400 else { return nil }
            self = .geodesic(frequency: n)
        case "hexagonal":
            guard parts.count == 2, let n = Int(parts[1]), n > 0, n <= 200 else { return nil }
            self = .hexagonal(frequency: n)
        case "platonic":
            guard parts.count >= 2, let solid = PlatonicSolid(rawValue: parts[1]) else { return nil }
            let levels = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
            guard (0...8).contains(levels) else { return nil }
            self = .platonic(solid, levels: levels)
        default:
            return nil
        }
    }

    public var argument: String {
        switch self {
        case .graticule(let s): "graticule:\(Self.format(s))"
        case .geodesic(let n): "geodesic:\(n)"
        case .platonic(let solid, let levels): "platonic:\(solid.rawValue):\(levels)"
        case .hexagonal(let n): "hexagonal:\(n)"
        }
    }

    static func format(_ v: Double) -> String { String(format: "%g", v) }
}

/// Orientation of a mesh on the globe, as three rotations in degrees: about
/// the polar axis, then tilt about the y axis, then about the polar axis again.
public struct MeshOrientation: Hashable, Sendable, Codable {
    public var alpha: Double
    public var beta: Double
    public var gamma: Double

    public init(alpha: Double = 0, beta: Double = 0, gamma: Double = 0) {
        self.alpha = alpha
        self.beta = beta
        self.gamma = gamma
    }

    public static let identity = MeshOrientation()

    public var isIdentity: Bool { alpha == 0 && beta == 0 && gamma == 0 }

    public var matrix: Mat3 {
        let r = Double.pi / 180
        return Mat3.rotationZ(gamma * r) * Mat3.rotation(axis: .unitY, angle: beta * r) * Mat3.rotationZ(alpha * r)
    }
}

/// A mesh kind in an orientation: everything needed to build a myriahedron.
public struct MeshSpec: Hashable, Sendable, Codable {
    public var kind: MeshKind
    public var orientation: MeshOrientation

    public init(_ kind: MeshKind, orientation: MeshOrientation = .identity) {
        self.kind = kind
        self.orientation = orientation
    }

    public func build() -> MeshBuild {
        let b = kind.build()
        return orientation.isIdentity ? b : b.rotated(by: orientation.matrix)
    }
}
