import Foundation
import MyriaCore

/// Cuts along the borders of regions (timezones, countries, plates, land
/// masses), so each region unfolds as its own piece. Generalised from
/// myriamap's timezone cuts.
///
/// 1. Inside each region the hinges form a maximum spanning tree over the
///    region's own edges: east–west neighbours first (rows of faces become
///    strips), then north–south links where the rows are deepest inside the
///    region. Each region unfolds like a small polyconic map, with slits
///    along parallels running in from its border.
/// 2. The pieces are then joined by one hinge each across a border, grown
///    outward from the root piece (Prim's algorithm on pieces). A candidate
///    scores high near the equator and the central meridian and low when it
///    would hang its piece at a tilt; the tilt is exact, since a piece's
///    internal tree fixes how its faces rotate relative to each other. The
///    pieces hang off an equatorial belt like globe gores and stay upright.
public struct RegionTree: Sendable, Hashable {
    /// Longitude the equatorial belt is centred on.
    public var centerLongitude: Double
    /// How strongly cross-border hinges prefer low latitudes.
    public var equatorBias: Double
    /// Tilt (radians) at which a hinge's score has dropped by a factor e.
    public var tiltTolerance: Double

    public init(centerLongitude: Double = 0, equatorBias: Double = 2, tiltTolerance: Double = 0.35) {
        self.centerLongitude = centerLongitude
        self.equatorBias = equatorBias
        self.tiltTolerance = tiltTolerance
    }

    /// - Parameters:
    ///   - faceGroups: a label per face; faces with equal labels form regions.
    ///   - interior: optional weights for the trees inside regions; by
    ///     default rows along parallels (polyconic strips).
    ///   - avoid: per edge, true where pieces should rather not be joined
    ///     (a river between two banks); such hinges are a last resort.
    public func hinges(_ context: LayoutContext, faceGroups: [Int], root: Int, interior: [Double]? = nil,
                       avoid: [Bool]? = nil) -> [Bool] {
        let mesh = context.mesh
        let edges = mesh.topology.edges
        let internalWeights = interior ?? stripWeights(context, faceGroups: faceGroups)

        // 1. Spanning forest inside the regions; cells are never split.
        let internalEdges = edges.indices.filter {
            faceGroups[edges[$0].leftFace] == faceGroups[edges[$0].rightFace] || mesh.isInternalEdge[$0]
        }
        let inForest = SpanningTree.maximum(
            nodeCount: mesh.faceCount,
            edges: internalEdges.map { (edges[$0].leftFace, edges[$0].rightFace) },
            weights: internalEdges.map { mesh.isInternalEdge[$0] ? .infinity : internalWeights[$0] })
        var hinges = Array(repeating: false, count: edges.count)
        for (i, e) in internalEdges.enumerated() where inForest[i] { hinges[e] = true }

        // 2. Join the pieces.
        let pieces = PieceRotations(mesh: mesh, hinges: hinges)
        for e in attachPieces(context, pieces: pieces, root: root, avoid: avoid) { hinges[e] = true }
        return hinges
    }

    /// Weights of edges inside a region, in 2…2.5: east–west first, then
    /// north–south where deepest inside the region.
    public func stripWeights(_ context: LayoutContext, faceGroups: [Int]) -> [Double] {
        let mesh = context.mesh, info = context.edges
        let depth = Self.eastWestDepth(context, faceGroups: faceGroups)
        let maxDepth = Double(depth.filter { $0 < Int.max }.max() ?? 0) + 1
        return mesh.topology.edges.indices.map { e in
            let edge = mesh.topology.edges[e], g = info[e]
            guard faceGroups[edge.leftFace] == faceGroups[edge.rightFace] else { return 0 }
            let d = Double(min(depth[edge.leftFace], depth[edge.rightFace], Int(maxDepth))) / maxDepth
            return 2 + 0.5 * g.eastWestness + 0.5 * (1 - g.eastWestness) * d
        }
    }

    /// Score of hanging a piece from an already placed face across an edge.
    func score(midpoint: Vec3, tilt: Double) -> Double {
        let p = GeoPoint(midpoint)
        let equator = pow(cos(p.latitude * .pi / 180), equatorBias)
        let away = abs(Spherical.longitudeDelta(centerLongitude, p.longitude)) / 180
        return equator * (1 - 0.5 * away) * exp(-pow(tilt / tiltTolerance, 2))
    }

    /// Prim's algorithm over pieces; returns the chosen border hinges.
    func attachPieces(_ context: LayoutContext, pieces: PieceRotations, root: Int, avoid: [Bool]? = nil) -> [Int] {
        let mesh = context.mesh, info = context.edges
        let edges = mesh.topology.edges
        var placed = Array(repeating: false, count: pieces.count)
        var frontier = CandidateHeap()
        var chosen: [Int] = []

        func place(_ piece: Int, rotation: Double) {
            placed[piece] = true
            for f in pieces.faces[piece] {
                for e in mesh.topology.faceEdges[f] {
                    let c = edges[e].otherFace(f)
                    let target = pieces.piece[c]
                    guard !placed[target] else { continue }
                    // Rotation of face c once hinged to f, then of its piece.
                    let faceAngle = rotation + pieces.angle[f] + pieces.hingeRotation(edge: e, from: c, to: f)
                    let pieceOffset = faceAngle - pieces.angle[c]
                    let tilt = Self.wrap(pieceOffset + pieces.meanAngle[target])
                    var s = score(midpoint: info[e].midpoint, tilt: tilt)
                    if avoid?[e] == true { s *= 1e-3 }
                    frontier.push(Candidate(edge: e, target: target, score: s, offset: pieceOffset))
                }
            }
        }

        place(pieces.piece[root], rotation: -pieces.angle[root])
        while let best = frontier.pop() {
            guard !placed[best.target] else { continue }
            chosen.append(best.edge)
            place(best.target, rotation: best.offset)
        }
        return chosen
    }

    static func wrap(_ angle: Double) -> Double {
        atan2(sin(angle), cos(angle))
    }

    /// Hops from each face to the nearest region border travelling only
    /// east–west within the region. Rows that never meet a border (around a
    /// pole) get `Int.max`.
    static func eastWestDepth(_ context: LayoutContext, faceGroups: [Int]) -> [Int] {
        let mesh = context.mesh, info = context.edges
        var depth = Array(repeating: Int.max, count: mesh.faceCount)
        var queue: [Int] = []
        for (e, edge) in mesh.topology.edges.enumerated() where info[e].eastWestness >= 0.5 {
            if faceGroups[edge.leftFace] != faceGroups[edge.rightFace] {
                for f in [edge.leftFace, edge.rightFace] where depth[f] != 0 {
                    depth[f] = 0
                    queue.append(f)
                }
            }
        }
        var head = 0
        while head < queue.count {
            let f = queue[head]
            head += 1
            for e in mesh.topology.faceEdges[f] where info[e].eastWestness >= 0.5 {
                let g = mesh.topology.edges[e].otherFace(f)
                if faceGroups[g] == faceGroups[f] && depth[g] == Int.max {
                    depth[g] = depth[f] + 1
                    queue.append(g)
                }
            }
        }
        return depth
    }

    /// A region that wraps around a pole (Antarctica, the Arctic Ocean)
    /// cannot unfold in one piece without heavy distortion. For cutting
    /// only, its polar faces are split into `sectorWidth`° sectors, so each
    /// sector hangs off the piece next to it.
    public static func splittingPolarCaps(_ faceGroups: [Int], context: LayoutContext, latitude: Double = 60,
                                          sectorWidth: Double = 15, maxSectors: Int = 6) -> [Int] {
        let centers = context.faceLocations
        let sectorCount = Int((360 / sectorWidth).rounded())
        let groupCount = (faceGroups.max() ?? -1) + 1
        func sector(_ p: GeoPoint) -> Int {
            ((Int(((p.longitude + sectorWidth / 2) / sectorWidth).rounded(.down)) % sectorCount) + sectorCount) % sectorCount
        }
        var sectors: [Int: Set<Int>] = [:]
        for f in centers.indices where faceGroups[f] >= 0 && abs(centers[f].latitude) > latitude {
            let pole = centers[f].latitude > 0 ? 1 : 0
            sectors[faceGroups[f] * 2 + pole, default: []].insert(sector(centers[f]))
        }
        return centers.indices.map { f in
            let g = faceGroups[f], p = centers[f]
            guard g >= 0, abs(p.latitude) > latitude else { return g }
            let pole = p.latitude > 0 ? 1 : 0
            guard (sectors[g * 2 + pole]?.count ?? 0) > maxSectors else { return g }
            return groupCount + (g * 2 + pole) * sectorCount + sector(p)
        }
    }
}

/// A candidate hinge between a placed piece and an unplaced one.
struct Candidate {
    let edge: Int
    let target: Int
    let score: Double
    let offset: Double
}

/// Max-heap of candidates by score, ties to the lower edge index.
struct CandidateHeap {
    private var items: [Candidate] = []

    private func before(_ a: Candidate, _ b: Candidate) -> Bool {
        a.score != b.score ? a.score > b.score : a.edge < b.edge
    }

    mutating func push(_ c: Candidate) {
        items.append(c)
        var i = items.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            guard before(items[i], items[p]) else { break }
            items.swapAt(i, p)
            i = p
        }
    }

    mutating func pop() -> Candidate? {
        guard let top = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            var i = 0
            while true {
                let l = 2 * i + 1, r = l + 1
                var best = i
                if l < items.count, before(items[l], items[best]) { best = l }
                if r < items.count, before(items[r], items[best]) { best = r }
                if best == i { break }
                items.swapAt(i, best)
                i = best
            }
        }
        return top
    }
}

/// Pieces of a spanning forest and how their faces rotate relative to each
/// other once unfolded.
struct PieceRotations {
    let mesh: MyriahedralMesh
    /// Piece index per face.
    let piece: [Int]
    let faces: [[Int]]
    /// Rotation of each face's local frame in its piece's frame.
    let angle: [Double]
    /// Area-weighted circular mean of `angle` per piece.
    let meanAngle: [Double]

    var count: Int { faces.count }

    init(mesh: MyriahedralMesh, hinges: [Bool]) {
        self.mesh = mesh
        let n = mesh.faceCount
        var piece = Array(repeating: -1, count: n)
        var angle = Array(repeating: 0.0, count: n)
        var faces: [[Int]] = []
        for start in 0..<n where piece[start] < 0 {
            let id = faces.count
            var members = [start]
            piece[start] = id
            var head = 0
            while head < members.count {
                let f = members[head]
                head += 1
                for e in mesh.topology.faceEdges[f] where hinges[e] {
                    let g = mesh.topology.edges[e].otherFace(f)
                    guard piece[g] < 0 else { continue }
                    piece[g] = id
                    angle[g] = angle[f] + Self.hingeRotation(mesh: mesh, edge: e, from: g, to: f)
                    members.append(g)
                }
            }
            faces.append(members)
        }
        self.piece = piece
        self.faces = faces
        self.angle = angle
        meanAngle = faces.map { members in
            var s = 0.0, c = 0.0
            for f in members {
                let w = mesh.frames[f].area
                s += w * sin(angle[f])
                c += w * cos(angle[f])
            }
            return atan2(s, c)
        }
    }

    func hingeRotation(edge e: Int, from child: Int, to parent: Int) -> Double {
        Self.hingeRotation(mesh: mesh, edge: e, from: child, to: parent)
    }

    /// Rotation taking `child`'s local frame onto `parent`'s when the two are
    /// unfolded around their shared edge.
    static func hingeRotation(mesh: MyriahedralMesh, edge e: Int, from child: Int, to parent: Int) -> Double {
        let edge = mesh.topology.edges[e]
        func local(_ f: Int, _ v: Int) -> Vec2 {
            mesh.frames[f].localVertices[mesh.polyhedron.faces[f].firstIndex(of: v)!]
        }
        let dc = local(child, edge.b) - local(child, edge.a)
        let dp = local(parent, edge.b) - local(parent, edge.a)
        return atan2(dp.y, dp.x) - atan2(dc.y, dc.x)
    }
}
