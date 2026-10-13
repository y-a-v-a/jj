import Foundation

/// Van Wijk's figure 13: a myriahedral map with its interrupts removed.
///
/// "We matched corresponding vertices at a distance below a certain
/// threshold, starting at the ends of gaps, followed by a finite element
/// simulation to redistribute the points of the mesh … These steps are
/// repeated until no corresponding vertices could be found."
///
/// Both copies of a vertex on either side of a cut are corresponding
/// vertices. Each round zips together the pairs that lie close (at first
/// those at the narrow ends of the gaps), then lets the map relax as an
/// elastic sheet: as-rigid-as-possible, every face as close to its own
/// undistorted shape as the closed seams allow. What cannot close stays the
/// map's outline. Triangle faces only: a triangle stays a triangle, so the
/// closed map is drawn with one affine map per face.
public struct ClosedGaps: Sendable {
    /// Per face, its corners in the open (unfolded) map.
    public let open: [[Vec2]]
    /// Per face, its corners once the gaps are closed.
    public let closed: [[Vec2]]
    /// Rounds of zipping and relaxing, and the pairs of vertices joined.
    public let rounds: Int
    public let joined: Int
    /// Seams that stay open: the closed map's outline.
    public let openSeams: [Int]
    public let bounds: Rect2
    /// The closed faces by position, for finding the face under a point.
    let index: FaceGrid

    /// - Parameters:
    ///   - threshold: how close corresponding vertices must come to be
    ///     joined, in mean edge lengths.
    ///   - maximumRounds: a bound on the rounds of zipping.
    /// Returns nil unless every face is a triangle.
    public init?(projection: MyriahedralProjection, threshold: Double = 1.0, maximumRounds: Int = 400) {
        let mesh = projection.mesh, topology = mesh.topology
        let faces = mesh.polyhedron.faces
        guard faces.allSatisfy({ $0.count == 3 }) else { return nil }
        let F = faces.count
        let isCut = projection.unfolding.isCut
        let unfolded = projection.mapPolygons
        func corner(_ f: Int, _ v: Int) -> Int { 3 * f + faces[f].firstIndex(of: v)! }

        // Corners joined by hinges are one map vertex; across a cut, the two
        // copies of each end are a pair to zip.
        var sets = UnionFind(count: 3 * F)
        var pairs: [(Int, Int, edge: Int)] = []
        for (e, edge) in topology.edges.enumerated() {
            let f = edge.leftFace, g = edge.rightFace
            if isCut[e] {
                pairs.append((corner(f, edge.a), corner(g, edge.a), e))
                pairs.append((corner(f, edge.b), corner(g, edge.b), e))
            } else {
                _ = sets.union(corner(f, edge.a), corner(g, edge.a))
                _ = sets.union(corner(f, edge.b), corner(g, edge.b))
            }
        }

        // The rest shape of every face and its cotangent weights.
        let rest = mesh.frames.map(\.localVertices)
        let weights: [(Double, Double, Double)] = rest.map { r in
            func cot(_ k: Int) -> Double {
                let a = r[(k + 1) % 3] - r[k], b = r[(k + 2) % 3] - r[k]
                return max(a.dot(b) / max(abs(a.cross(b)), 1e-300), 1e-3) / 2
            }
            // Weight of edge (k+1, k+2) is the cotangent at corner k.
            return (cot(0), cot(1), cot(2))
        }
        var edgeLength = 0.0
        for r in rest { edgeLength += (r[1] - r[0]).length + (r[2] - r[1]).length + (r[0] - r[2]).length }
        edgeLength /= Double(3 * F)
        let reach = threshold * edgeLength

        // Map vertices: compact ids, positions where the unfolding put them.
        var ids = [Int](repeating: 0, count: 3 * F)
        var x: [Vec2] = []
        func compact(_ old: [Vec2]?, _ oldIDs: [Int]) {
            var index = [Int: Int]()
            var sum: [Vec2] = [], count: [Double] = []
            for c in 0..<(3 * F) {
                let root = sets.find(c)
                let id: Int
                if let known = index[root] {
                    id = known
                } else {
                    id = sum.count
                    index[root] = id
                    sum.append(.zero)
                    count.append(0)
                }
                ids[c] = id
                let position: Vec2 = if let old { old[oldIDs[c]] } else { unfolded[c / 3][c % 3] }
                sum[id] = sum[id] + position
                count[id] += 1
            }
            x = sum.indices.map { sum[$0] / count[$0] }
        }
        compact(nil, ids)

        var round = 0, pairsJoined = 0
        while round < maximumRounds {
            // Zip every pair that has come close.
            var zipped = 0
            for (a, b, _) in pairs where sets.find(a) != sets.find(b) && (x[ids[a]] - x[ids[b]]).length < reach {
                _ = sets.union(a, b)
                zipped += 1
            }
            if zipped == 0 { break }
            pairsJoined += zipped
            round += 1
            let (oldX, oldIDs) = (x, ids)
            compact(oldX, oldIDs)
            // Then let the sheet relax a little (less on big meshes, where
            // rounds are many); it settles at the end.
            Self.relax(&x, ids: ids, rest: rest, weights: weights, iterations: F > 30_000 ? 1 : 2,
                       solverSteps: F > 30_000 ? 15 : 30)
        }
        if round > 0 { Self.relax(&x, ids: ids, rest: rest, weights: weights, iterations: 8, solverSteps: 40) }
        open = unfolded
        rounds = round
        joined = pairsJoined
        closed = (0..<F).map { f in (0..<3).map { x[ids[3 * f + $0]] } }
        var unzipped = Set<Int>()
        for (a, b, e) in pairs where sets.find(a) != sets.find(b) { unzipped.insert(e) }
        openSeams = unzipped.sorted()
        var b = Rect2.empty
        for p in x { b.include(p) }
        bounds = b
        index = FaceGrid(polygons: closed)
    }

    /// As-rigid-as-possible relaxation (Sorkine and Alexa): alternately fit
    /// each face's best rotation to its current shape, and move the vertices
    /// to where those rotated faces want them (a sparse solve by conjugate
    /// gradients, warm-started where they are).
    static func relax(_ x: inout [Vec2], ids: [Int], rest: [[Vec2]], weights: [(Double, Double, Double)],
                      iterations: Int, solverSteps: Int) {
        let n = x.count, F = rest.count
        // Every face's three edges as (i, j, weight, rest i − rest j).
        struct Spring { let i: Int, j: Int, w: Double, r: Vec2 }
        var springList: [Spring] = []
        springList.reserveCapacity(3 * F)
        for f in 0..<F {
            let w = weights[f], r = rest[f]
            let c0 = ids[3 * f], c1 = ids[3 * f + 1], c2 = ids[3 * f + 2]
            springList.append(Spring(i: c1, j: c2, w: w.0, r: r[1] - r[2]))
            springList.append(Spring(i: c2, j: c0, w: w.1, r: r[2] - r[0]))
            springList.append(Spring(i: c0, j: c1, w: w.2, r: r[0] - r[1]))
        }
        // The cotangent Laplacian by rows (each vertex's neighbours), plus a
        // soft anchor to where the vertices are, which keeps the solve
        // definite and the map in place.
        var offsets = [Int](repeating: 0, count: n + 1)
        for s in springList {
            offsets[s.i + 1] += 1
            offsets[s.j + 1] += 1
        }
        for i in 0..<n { offsets[i + 1] += offsets[i] }
        var neighbours = [Int](repeating: 0, count: offsets[n]), weightList = [Double](repeating: 0, count: offsets[n])
        var fill = offsets
        for s in springList {
            neighbours[fill[s.i]] = s.j; weightList[fill[s.i]] = s.w; fill[s.i] += 1
            neighbours[fill[s.j]] = s.i; weightList[fill[s.j]] = s.w; fill[s.j] += 1
        }
        var sums = (0..<n).map { i in (offsets[i]..<offsets[i + 1]).reduce(0.0) { $0 + weightList[$1] } }
        let anchor = 1e-3 * sums.reduce(0, +) / Double(max(n, 1))
        for i in 0..<n { sums[i] += anchor }
        // Frozen for the concurrent loops.
        let springs = springList, start = offsets, neighbour = neighbours, weight = weightList, diagonal = sums
        let chunk = max(256, n / (ProcessInfo.processInfo.activeProcessorCount * 4))
        let chunks = (n + chunk - 1) / chunk

        /// out = L v, by rows, in parallel.
        func apply(_ v: [Vec2], into out: inout [Vec2]) {
            v.withUnsafeBufferPointer { v in
                out.withUnsafeMutableBufferPointer { o in
                    nonisolated(unsafe) let (v, o) = (v, o)
                    DispatchQueue.concurrentPerform(iterations: chunks) { c in
                        for i in (c * chunk)..<min(n, (c + 1) * chunk) {
                            var acc = v[i] * diagonal[i]
                            for k in start[i]..<start[i + 1] { acc = acc - v[neighbour[k]] * weight[k] }
                            o[i] = acc
                        }
                    }
                }
            }
        }

        var rhs = [Vec2](repeating: .zero, count: n)
        var out = rhs, residual = rhs, z = rhs, p = rhs
        for _ in 0..<iterations {
            // Local step: each face's best rotation…
            let current = x
            let rotations: [(Double, Double)] = parallelMap(F) { f in
                var m00 = 0.0, m01 = 0.0, m10 = 0.0, m11 = 0.0
                for s in springs[(3 * f)..<(3 * f + 3)] {
                    let ex = current[s.i] - current[s.j]
                    m00 += s.w * s.r.x * ex.x; m01 += s.w * s.r.x * ex.y
                    m10 += s.w * s.r.y * ex.x; m11 += s.w * s.r.y * ex.y
                }
                let angle = atan2(m01 - m10, m00 + m11)
                return (cos(angle), sin(angle))
            }
            // …and where the rotated faces want their corners.
            for i in 0..<n { rhs[i] = x[i] * anchor }
            for (k, s) in springs.enumerated() {
                let (cs, sn) = rotations[k / 3]
                let d = Vec2(cs * s.r.x - sn * s.r.y, sn * s.r.x + cs * s.r.y) * s.w
                rhs[s.i] = rhs[s.i] + d
                rhs[s.j] = rhs[s.j] - d
            }
            // Global step: L x = rhs, by Jacobi-preconditioned conjugate gradients.
            apply(x, into: &out)
            var rz = 0.0, scale = 0.0
            for i in 0..<n {
                residual[i] = rhs[i] - out[i]
                z[i] = residual[i] / diagonal[i]
                p[i] = z[i]
                rz += residual[i].dot(z[i])
                scale += rhs[i].lengthSquared
            }
            let tolerance = 1e-12 * max(scale, 1e-300)
            for _ in 0..<solverSteps {
                guard rz > tolerance else { break }
                apply(p, into: &out)
                var pap = 0.0
                for i in 0..<n { pap += p[i].dot(out[i]) }
                let alpha = rz / max(pap, 1e-300)
                var next = 0.0
                for i in 0..<n {
                    x[i] = x[i] + p[i] * alpha
                    residual[i] = residual[i] - out[i] * alpha
                    z[i] = residual[i] / diagonal[i]
                    next += residual[i].dot(z[i])
                }
                let beta = next / rz
                rz = next
                for i in 0..<n { p[i] = z[i] + p[i] * beta }
            }
        }
    }

    // MARK: Drawing

    /// The corners of a face with the gaps closed by `amount` (0 open, 1 closed).
    public func corners(of face: Int, amount: Double) -> [Vec2] {
        (0..<3).map { Vec2.lerp(open[face][$0], closed[face][$0], amount) }
    }

    /// The affine map taking a face's local coordinates to the map with the
    /// gaps closed by `amount`: columns `a`, `b` and offset `t`, so that
    /// local p goes to a·p.x + b·p.y + t.
    public func affine(face: Int, local: [Vec2], amount: Double) -> (a: Vec2, b: Vec2, t: Vec2) {
        let q = corners(of: face, amount: amount)
        let (r1, r2) = (local[1] - local[0], local[2] - local[0])
        let (d1, d2) = (q[1] - q[0], q[2] - q[0])
        let det = r1.cross(r2)
        guard abs(det) > 1e-300 else { return (Vec2(1, 0), Vec2(0, 1), q[0] - local[0]) }
        // Solve [a b] [r1 r2] = [d1 d2].
        let a = (d1 * r2.y - d2 * r1.y) / det
        let b = (d2 * r1.x - d1 * r2.x) / det
        return (a, b, q[0] - (a * local[0].x + b * local[0].y))
    }

    /// The bounds of the map with the gaps closed by `amount`.
    public func bounds(amount: Double, openBounds: Rect2) -> Rect2 {
        guard amount > 0 else { return openBounds }
        if amount >= 1 { return bounds }
        var b = Rect2.empty
        for f in open.indices { for p in corners(of: f, amount: amount) { b.include(p) } }
        return b
    }

    /// The face under map point `q` with the gaps closed by `amount`, and
    /// the point in its local coordinates.
    public func face(at q: Vec2, amount: Double, frames: [FaceFrame]) -> (face: Int, local: Vec2)? {
        // Closed, the index finds the candidates; while moving, small maps
        // are searched face by face and large ones not at all.
        let candidates: [Int]
        if amount >= 1 {
            candidates = index.candidates(Rect2(minX: q.x, minY: q.y, maxX: q.x, maxY: q.y))
        } else if open.count <= 20_000 {
            candidates = Array(open.indices)
        } else {
            return nil
        }
        for f in candidates {
            let c = corners(of: f, amount: amount)
            let s0 = (c[1] - c[0]).cross(q - c[0]), s1 = (c[2] - c[1]).cross(q - c[1]), s2 = (c[0] - c[2]).cross(q - c[2])
            guard (s0 >= 0 && s1 >= 0 && s2 >= 0) || (s0 <= 0 && s1 <= 0 && s2 <= 0) else { continue }
            let (a, b, t) = affine(face: f, local: frames[f].localVertices, amount: amount)
            let det = a.cross(b)
            guard abs(det) > 1e-300 else { continue }
            let d = q - t
            return (f, Vec2(d.cross(b) / det, a.cross(d) / det))
        }
        return nil
    }
}
