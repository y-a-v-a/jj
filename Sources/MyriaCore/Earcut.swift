// Earcut.swift
//
// Polygon triangulation by ear clipping, ported to Swift from Mapbox's earcut
// (https://github.com/mapbox/earcut, v3.2), which is distributed under the
// ISC licence:
//
//   ISC License
//
//   Copyright (c) 2026, Mapbox
//
//   Permission to use, copy, modify, and/or distribute this software for any
//   purpose with or without fee is hereby granted, provided that the above
//   copyright notice and this permission notice appear in all copies.
//
//   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//   SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//   ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//   IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//
// Approach (unchanged from earcut):
//  1. Each ring becomes a circular doubly linked list of nodes. The outer ring
//     is linked counter-clockwise and holes clockwise, whatever their input
//     winding.
//  2. Holes are merged into the outer ring, leftmost first, through zero-width
//     "bridges" found with David Eberly's ray-casting method, leaving a single
//     weakly simple ring.
//  3. Ears (convex vertices whose triangle contains no reflex vertex) are cut
//     off one by one. Above 80 vertices the nodes are also threaded in z-order
//     (Morton) so the containment test only visits nodes whose z-code falls in
//     the candidate triangle's bounding box range.
//  4. When no ear can be found the ring is cleaned of duplicate and collinear
//     points, then small local self-intersections are cured, and as a last
//     resort the ring is split along a valid diagonal and both halves are
//     triangulated recursively.
//
// The port follows earcut 3.2.4 function by function, including its block
// bounding-box index that speeds up the hole-bridge search for polygons with
// many holes. One deliberate deviation: the test that no reflex vertex lies
// inside a candidate ear also counts vertices within a tiny distance (1e-12 of
// the largest coordinate magnitude) outside the triangle's edges. Sutherland–
// Hodgman clipping against general lines leaves the vertices of its zero-width
// bridges a few ulps off the clip line; with earcut's exact test such a vertex
// can fall just outside an ear spanning two clipped pieces and fail to block
// it. With zero tolerance the test is earcut's, bit for bit; on earcut's own
// fixtures the output is unchanged apart from one known-bad case.
//
// Swift specifics: nodes live in one manually managed buffer and link to each
// other by index (no per-node objects, no ARC traffic), and all state is per
// call, so concurrent calls are safe.

/// Ear-clipping polygon triangulation (a port of Mapbox's earcut).
///
/// Triangles are returned as index triples. Every triangle `(a, b, c)`
/// produced by ear clipping is strictly counter-clockwise:
/// `(b - a).cross(c - b) > 0`. Only the self-intersection repair pass, which
/// runs on self-intersecting input, can emit a triangle of the opposite or
/// zero orientation. Like earcut, the algorithm is not exact for invalid input
/// (crossing edges, overlapping holes, nearly coincident edges that cross by
/// rounding error) but never fails: it returns its best effort, possibly
/// covering some area twice or leaving parts untriangulated.
public enum Earcut {
    /// Rings with more vertices than this (counting holes) use z-order hashing.
    static let hashingThreshold = 80

    /// Distance, relative to the largest coordinate magnitude, within which a
    /// reflex vertex outside a candidate ear still blocks it.
    static let relativeEarTolerance = 1e-12

    /// Triangulates a simple polygon with optional holes. Vertices of `outer`
    /// followed by those of each hole (in order) form one index space; the
    /// result lists triangles as index triples into it. Rings are open (no
    /// repeated closing point) and may be in either winding.
    public static func triangulate(outer: [Vec2], holes: [[Vec2]] = []) -> [Int] {
        if holes.isEmpty { return triangulate(vertices: outer, holeIndices: []) }
        let (vertices, holeIndices) = flatten(outer, holes)
        return triangulate(vertices: vertices, holeIndices: holeIndices)
    }

    /// Triangulates a polygon given as rings, the first being the outer ring
    /// and the rest its holes. Returns the rings' vertices concatenated in
    /// order together with the triangle indices into them.
    public static func triangulate(rings: [[Vec2]]) -> (vertices: [Vec2], indices: [Int]) {
        guard let outer = rings.first else { return ([], []) }
        let (vertices, holeIndices) = flatten(outer, rings.dropFirst())
        return (vertices, triangulate(vertices: vertices, holeIndices: holeIndices))
    }

    /// Earcut's native form: all ring vertices in one array, with
    /// `holeIndices` giving the index at which each hole ring starts (in
    /// increasing order). Polygons with non-finite coordinates yield no
    /// triangles.
    public static func triangulate(vertices: [Vec2], holeIndices: [Int]) -> [Int] {
        precondition(vertices.count < 1 << 30, "Earcut: too many vertices")
        var previous = 0
        for start in holeIndices {
            precondition(start >= previous && start <= vertices.count, "Earcut: invalid hole indices")
            previous = start
        }
        guard vertices.count >= 3 else { return [] }
        var magnitude = 0.0
        for v in vertices {
            guard v.x.isFinite && v.y.isFinite else { return [] }
            magnitude = max(magnitude, max(abs(v.x), abs(v.y)))
        }

        var triangulator = Triangulator(capacity: vertices.count + 2 * holeIndices.count + 8,
                                        earTolerance: relativeEarTolerance * magnitude)
        return triangulator.run(vertices, holeIndices)
    }

    private static func flatten<Holes: Collection<[Vec2]>>(_ outer: [Vec2], _ holes: Holes) -> ([Vec2], [Int]) {
        var vertices = outer
        vertices.reserveCapacity(holes.reduce(outer.count) { $0 + $1.count })
        var holeIndices: [Int] = []
        holeIndices.reserveCapacity(holes.count)
        for hole in holes where !hole.isEmpty {
            holeIndices.append(vertices.count)
            vertices.append(contentsOf: hole)
        }
        return (vertices, holeIndices)
    }
}

// MARK: - Linked list storage

/// Marks a missing z-order neighbour.
private let noNode = -1

/// A vertex in a circular doubly linked ring. `prev`/`next` are always valid
/// node indices; `prevZ`/`nextZ` thread the z-order list and are `noNode` at
/// its ends (and while hashing is off).
private struct Node {
    var x: Double
    var y: Double
    /// Index of the vertex in the caller's array.
    var i: Int
    var prev: Int
    var next: Int
    /// Morton code of the vertex, valid while hashing.
    var z: Int
    var prevZ: Int
    var nextZ: Int
}

/// The candidate triangle `abc` (counter-clockwise) of an ear, for the test
/// that no other ring vertex lies inside it. The triangle is widened by
/// `tolerance` beyond each edge; its bounding box includes that margin.
private struct EarTriangle {
    let ax: Double, ay: Double, bx: Double, by: Double, cx: Double, cy: Double
    let minX: Double, minY: Double, maxX: Double, maxY: Double
    /// Tolerance times the (L1) length of each edge: the slack allowed in the
    /// doubled-area edge tests.
    let slackAB: Double, slackBC: Double, slackCA: Double

    init(_ a: Node, _ b: Node, _ c: Node, tolerance: Double) {
        ax = a.x; ay = a.y; bx = b.x; by = b.y; cx = c.x; cy = c.y
        minX = min(ax, min(bx, cx)) - tolerance; minY = min(ay, min(by, cy)) - tolerance
        maxX = max(ax, max(bx, cx)) + tolerance; maxY = max(ay, max(by, cy)) + tolerance
        slackAB = tolerance * (abs(bx - ax) + abs(by - ay))
        slackBC = tolerance * (abs(cx - bx) + abs(cy - by))
        slackCA = tolerance * (abs(ax - cx) + abs(ay - cy))
    }

    /// Whether `(px, py)` lies inside the widened triangle, other than
    /// exactly at its first vertex. With zero tolerance this is earcut's
    /// inclusive point-in-triangle test.
    @inline(__always) func covers(_ px: Double, _ py: Double) -> Bool {
        px >= minX && px <= maxX && py >= minY && py <= maxY && !(px == ax && py == ay)
            && (cx - px) * (ay - py) - (ax - px) * (cy - py) >= -slackCA
            && (ax - px) * (by - py) - (bx - px) * (ay - py) >= -slackAB
            && (bx - px) * (cy - py) - (cx - px) * (by - py) >= -slackBC
    }
}

/// Whether `p` lies inside the counter-clockwise triangle `abc` or on its boundary.
@inline(__always)
private func pointInTriangle(
    _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double,
    _ cx: Double, _ cy: Double, _ px: Double, _ py: Double
) -> Bool {
    (cx - px) * (ay - py) >= (ax - px) * (cy - py)
        && (ax - px) * (by - py) >= (bx - px) * (ay - py)
        && (bx - px) * (cy - py) >= (cx - px) * (by - py)
}

/// Spreads the low 16 bits of `v` to the even bit positions.
@inline(__always)
private func spreadBits(_ v: Int) -> Int {
    var v = v
    v = (v | (v << 8)) & 0x00FF_00FF
    v = (v | (v << 4)) & 0x0F0F_0F0F
    v = (v | (v << 2)) & 0x3333_3333
    v = (v | (v << 1)) & 0x5555_5555
    return v
}

/// A run of up to `blockEdges` consecutive ring edges and their bounding box,
/// for the hole-bridge search (see `indexSegment`).
private struct Block {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double
    /// First node of the run.
    var head: Int
    /// Node just past the run (exclusive walk bound); equal to `head` for a whole ring.
    var stop: Int
}

/// Edges per hole-bridge index block.
private let blockEdges = 16

/// One triangulation: the node pool plus the per-call state that earcut keeps
/// in module globals.
private struct Triangulator: ~Copyable {
    private var nodes: UnsafeMutablePointer<Node>
    private var count = 0
    private var capacity: Int

    /// Z-order transform (`invSize == 0` disables hashing).
    private var minX = 0.0
    private var minY = 0.0
    private var invSize = 0.0
    private var hashing: Bool { invSize != 0 }
    /// Absolute widening of candidate ears (see `EarTriangle`).
    private let earTolerance: Double

    /// Single-vertex holes, which duplicate/collinear filtering must keep.
    private var steiners: [Int] = []
    /// Set whenever `filterPoints` removes a node.
    private var filteredOut = false
    /// Scratch for sorting nodes by z-order: packed (z, ring position) keys
    /// and the node at each ring position.
    private var zKeys: [UInt64] = []
    private var zNodes: [Int] = []
    private var triangles: [Int] = []

    /// Block bounding-box index over the merged ring, used while holes are
    /// eliminated (node `z` then holds the node's block).
    private var blocks: UnsafeMutablePointer<Block>?
    private var blockCount = 0
    private var blockCapacity = 0
    /// True while holes are merged, so removals keep block boxes covering healed edges.
    private var indexActive = false

    init(capacity: Int, earTolerance: Double) {
        self.capacity = max(capacity, 8)
        self.earTolerance = earTolerance
        nodes = .allocate(capacity: self.capacity)
    }

    deinit {
        nodes.deallocate()
        blocks?.deallocate()
    }

    mutating func run(_ data: [Vec2], _ holeIndices: [Int]) -> [Int] {
        let outerLength = holeIndices.first ?? data.count
        guard var outerNode = linkedList(data, 0, outerLength, clockwise: true),
              nodes[outerNode].next != nodes[outerNode].prev
        else { return [] }

        if !holeIndices.isEmpty { outerNode = eliminateHoles(data, holeIndices, outerNode) }

        // For non-trivial shapes, hash vertices along a z-order curve over the
        // outer ring's bounding box (coordinates mapped to 15-bit integers).
        if data.count > Earcut.hashingThreshold {
            var x0 = data[0].x, y0 = data[0].y, x1 = x0, y1 = y0
            for k in 1..<outerLength {
                let p = data[k]
                if p.x < x0 { x0 = p.x }
                if p.y < y0 { y0 = p.y }
                if p.x > x1 { x1 = p.x }
                if p.y > y1 { y1 = p.y }
            }
            let size = max(x1 - x0, y1 - y0)
            minX = x0
            minY = y0
            invSize = size != 0 ? 32767 / size : 0
        }

        triangles.reserveCapacity(3 * count)
        earcutLinked(outerNode)
        return triangles
    }

    // MARK: Nodes

    private mutating func createNode(_ i: Int, _ x: Double, _ y: Double) -> Int {
        if count == capacity {
            let grown = UnsafeMutablePointer<Node>.allocate(capacity: capacity * 2)
            grown.moveInitialize(from: nodes, count: count)
            nodes.deallocate()
            nodes = grown
            capacity *= 2
        }
        (nodes + count).initialize(to: Node(x: x, y: y, i: i, prev: count, next: count,
                                            z: 0, prevZ: noNode, nextZ: noNode))
        count += 1
        return count - 1
    }

    /// Creates a node for vertex `i` and links it after `last` (if any).
    private mutating func insertNode(_ i: Int, _ p: Vec2, after last: Int?) -> Int {
        let n = createNode(i, p.x, p.y)
        if let last {
            let next = nodes[last].next
            nodes[n].next = next
            nodes[n].prev = last
            nodes[next].prev = n
            nodes[last].next = n
        }
        return n
    }

    /// Unlinks `p` from its ring and the z-order list. The removed node keeps
    /// its own links, which callers rely on to step back into the ring.
    private func removeNode(_ p: Int) {
        let prev = nodes[p].prev, next = nodes[p].next
        nodes[next].prev = prev
        nodes[prev].next = next
        let prevZ = nodes[p].prevZ, nextZ = nodes[p].nextZ
        if prevZ != noNode { nodes[prevZ].nextZ = nextZ }
        if nextZ != noNode { nodes[nextZ].prevZ = prevZ }
    }

    /// Links vertices `a` and `b` with a bridge. If they are on the same ring
    /// this splits it in two; if one is on the outer ring and the other on a
    /// hole, it merges the hole into the outer ring. Returns the copy of `b`.
    private mutating func splitPolygon(_ a: Int, _ b: Int) -> Int {
        let a2 = createNode(nodes[a].i, nodes[a].x, nodes[a].y)
        let b2 = createNode(nodes[b].i, nodes[b].x, nodes[b].y)
        let an = nodes[a].next, bp = nodes[b].prev

        nodes[a].next = b
        nodes[b].prev = a
        nodes[a2].next = an
        nodes[an].prev = a2
        nodes[b2].next = a2
        nodes[a2].prev = b2
        nodes[bp].next = b2
        nodes[b2].prev = bp
        return b2
    }

    /// Builds a circular list from `data[start..<end]` in the requested
    /// winding (clockwise in earcut's y-down sense, i.e. counter-clockwise
    /// with y up).
    private mutating func linkedList(_ data: [Vec2], _ start: Int, _ end: Int, clockwise: Bool) -> Int? {
        guard start < end else { return nil }
        var last: Int?
        if clockwise == (Self.signedArea(data, start, end) > 0) {
            for k in start..<end { last = insertNode(k, data[k], after: last) }
        } else {
            for k in stride(from: end - 1, through: start, by: -1) { last = insertNode(k, data[k], after: last) }
        }
        if let l = last, equals(l, nodes[l].next) {
            removeNode(l)
            last = nodes[l].next
        }
        return last
    }

    /// Twice the shoelace area, positive for counter-clockwise rings (y up).
    private static func signedArea(_ data: [Vec2], _ start: Int, _ end: Int) -> Double {
        var sum = 0.0
        var j = end - 1
        for i in start..<end {
            sum += (data[j].x - data[i].x) * (data[i].y + data[j].y)
            j = i
        }
        return sum
    }

    private func isSteiner(_ p: Int) -> Bool { !steiners.isEmpty && steiners.contains(p) }

    // MARK: Predicates

    /// Signed area of triangle `pqr`; negative when counter-clockwise (y up).
    @inline(__always)
    private func area(_ p: Int, _ q: Int, _ r: Int) -> Double {
        (nodes[q].y - nodes[p].y) * (nodes[r].x - nodes[q].x) - (nodes[q].x - nodes[p].x) * (nodes[r].y - nodes[q].y)
    }

    @inline(__always)
    private func equals(_ p: Int, _ q: Int) -> Bool {
        nodes[p].x == nodes[q].x && nodes[p].y == nodes[q].y
    }

    /// For collinear `p`, `q`, `r`: whether `q` lies on segment `pr`.
    private func onSegment(_ p: Int, _ q: Int, _ r: Int) -> Bool {
        let P = nodes[p], Q = nodes[q], R = nodes[r]
        return Q.x <= max(P.x, R.x) && Q.x >= min(P.x, R.x) && Q.y <= max(P.y, R.y) && Q.y >= min(P.y, R.y)
    }

    /// Whether segments `p1q1` and `p2q2` intersect; collinear touches count
    /// only when `includeBoundary` is set.
    private func intersects(_ p1: Int, _ q1: Int, _ p2: Int, _ q2: Int, includeBoundary: Bool = true) -> Bool {
        let o1 = area(p1, q1, p2), o2 = area(p1, q1, q2)
        let o3 = area(p2, q2, p1), o4 = area(p2, q2, q1)

        if ((o1 > 0 && o2 < 0) || (o1 < 0 && o2 > 0)) && ((o3 > 0 && o4 < 0) || (o3 < 0 && o4 > 0)) { return true }
        guard includeBoundary else { return false }

        if o1 == 0 && onSegment(p1, p2, q1) { return true } // p2 lies on p1q1
        if o2 == 0 && onSegment(p1, q2, q1) { return true } // q2 lies on p1q1
        if o3 == 0 && onSegment(p2, p1, q2) { return true } // p1 lies on p2q2
        if o4 == 0 && onSegment(p2, q1, q2) { return true } // q1 lies on p2q2
        return false
    }

    /// Whether the diagonal `ab` crosses any edge of `a`'s ring.
    private func intersectsPolygon(_ a: Int, _ b: Int) -> Bool {
        let ai = nodes[a].i, bi = nodes[b].i
        let minX = min(nodes[a].x, nodes[b].x), maxX = max(nodes[a].x, nodes[b].x)
        let minY = min(nodes[a].y, nodes[b].y), maxY = max(nodes[a].y, nodes[b].y)
        var p = a
        repeat {
            let n = nodes[p].next
            let P = nodes[p], N = nodes[n]
            // Edges whose bounding box misses the diagonal's cannot cross it.
            let disjoint = (P.x > maxX && N.x > maxX) || (P.x < minX && N.x < minX)
                || (P.y > maxY && N.y > maxY) || (P.y < minY && N.y < minY)
            if !disjoint && P.i != ai && N.i != ai && P.i != bi && N.i != bi && intersects(p, n, a, b) {
                return true
            }
            p = n
        } while p != a
        return false
    }

    /// Whether the diagonal `ab` starts into the interior at `a`.
    private func locallyInside(_ a: Int, _ b: Int) -> Bool {
        let prev = nodes[a].prev, next = nodes[a].next
        return area(prev, a, next) < 0
            ? area(a, b, next) >= 0 && area(a, prev, b) >= 0
            : area(a, b, prev) < 0 || area(a, next, b) < 0
    }

    /// Whether the midpoint of the diagonal `ab` is inside the ring (even-odd).
    private func middleInside(_ a: Int, _ b: Int) -> Bool {
        let px = (nodes[a].x + nodes[b].x) / 2, py = (nodes[a].y + nodes[b].y) / 2
        var inside = false
        var p = a
        repeat {
            let n = nodes[p].next
            let P = nodes[p], N = nodes[n]
            if (P.y > py) != (N.y > py) && px < (N.x - P.x) * (py - P.y) / (N.y - P.y) + P.x {
                inside.toggle()
            }
            p = n
        } while p != a
        return inside
    }

    /// Whether the diagonal `ab` lies in the polygon's interior.
    private func isValidDiagonal(_ a: Int, _ b: Int) -> Bool {
        let aPrev = nodes[a].prev, bPrev = nodes[b].prev
        // A zero-length diagonal between two coincident reflex vertices.
        let zeroLength = equals(a, b) && area(aPrev, a, nodes[a].next) > 0 && area(bPrev, b, nodes[b].next) > 0
        return nodes[nodes[a].next].i != nodes[b].i
            && (zeroLength
                || (locallyInside(a, b) && locallyInside(b, a)                // locally visible
                    && (area(aPrev, a, bPrev) != 0 || area(a, bPrev, b) != 0))) // no opposite-facing sectors
            && !intersectsPolygon(a, b)
            && (zeroLength || middleInside(a, b))
    }

    /// Whether the sector at `m` contains the sector at `p` (same coordinates).
    private func sectorContainsSector(_ m: Int, _ p: Int) -> Bool {
        area(nodes[m].prev, m, nodes[p].prev) < 0 && area(nodes[p].next, m, nodes[m].next) < 0
    }

    // MARK: Filtering

    /// Removes duplicate and collinear points. Without `end`, sweeps the whole
    /// ring until nothing is removable; with `end`, heals only the window from
    /// `start` up to `end` (re-checking predecessors after each removal).
    /// Returns a node still on the ring.
    private mutating func filterPoints(_ start: Int, _ end: Int? = nil) -> Int {
        var end = end ?? start
        let full = end == start
        var p = start
        var again: Bool
        repeat {
            again = false
            let next = nodes[p].next
            if p != next && !isSteiner(p) && (equals(p, next) || area(nodes[p].prev, p, next) == 0) {
                if full || p == end { end = nodes[p].prev } // pull the stop bound back past the removal
                filteredOut = true
                removeNode(p)
                if indexActive { growBlock(nodes[p].prev, toCover: nodes[p].next) }
                p = nodes[p].prev // re-check the predecessor
                again = true
            } else if full || p != end {
                p = next
                again = !full
            }
        } while again || p != end
        return end
    }

    // MARK: Ear clipping

    /// The main ear slicing loop over one ring.
    private mutating func earcutLinked(_ start: Int) {
        var ear = start
        if hashing { indexCurve(ear) }

        // A strictly convex ring has no vertex that could block an ear, so skip
        // the containment tests until a candidate fails.
        var stop = ear
        var cured = false
        var convex = hashing && isConvex(ear)

        while nodes[ear].prev != nodes[ear].next {
            let prev = nodes[ear].prev, next = nodes[ear].next

            if area(prev, ear, next) < 0 && (convex || (hashing ? isEarHashed(ear) : isEar(ear))) {
                triangles.append(nodes[prev].i)
                triangles.append(nodes[ear].i)
                triangles.append(nodes[next].i)
                removeNode(ear)
                ear = next
                stop = next
                continue
            }

            convex = false
            ear = next

            // Looped through the whole remaining ring without finding an ear.
            if ear == stop {
                // Filtering may expose new ears; repeat while it removes nodes.
                filteredOut = false
                ear = filterPoints(ear)
                if filteredOut {
                    stop = ear
                    continue
                }
                // Then cure small local self-intersections, once.
                if !cured {
                    ear = cureLocalIntersections(ear)
                    stop = ear
                    cured = true
                    continue
                }
                // As a last resort, split the remaining ring in two.
                splitEarcut(ear)
                break
            }
        }
    }

    private func isConvex(_ start: Int) -> Bool {
        var p = start
        repeat {
            if area(nodes[p].prev, p, nodes[p].next) >= 0 { return false }
            p = nodes[p].next
        } while p != start
        return true
    }

    /// Whether the convex vertex `ear` forms a valid ear: no other ring vertex
    /// that is reflex lies inside (or within tolerance of) its triangle.
    private func isEar(_ ear: Int) -> Bool {
        let a = nodes[ear].prev, c = nodes[ear].next
        let triangle = EarTriangle(nodes[a], nodes[ear], nodes[c], tolerance: earTolerance)
        var p = nodes[c].next
        while p != a {
            if triangle.covers(nodes[p].x, nodes[p].y) && area(nodes[p].prev, p, nodes[p].next) >= 0 { return false }
            p = nodes[p].next
        }
        return true
    }

    /// `isEar` restricted to nodes whose z-code is within the triangle's
    /// bounding box range, walking the z-order list both ways from `ear`.
    private func isEarHashed(_ ear: Int) -> Bool {
        let a = nodes[ear].prev, c = nodes[ear].next
        let triangle = EarTriangle(nodes[a], nodes[ear], nodes[c], tolerance: earTolerance)
        let minZ = zOrder(triangle.minX, triangle.minY)
        let maxZ = zOrder(triangle.maxX, triangle.maxY)

        var p = nodes[ear].prevZ
        while p != noNode && nodes[p].z >= minZ {
            if p != c && triangle.covers(nodes[p].x, nodes[p].y) && area(nodes[p].prev, p, nodes[p].next) >= 0 {
                return false
            }
            p = nodes[p].prevZ
        }
        var n = nodes[ear].nextZ
        while n != noNode && nodes[n].z <= maxZ {
            if n != c && triangle.covers(nodes[n].x, nodes[n].y) && area(nodes[n].prev, n, nodes[n].next) >= 0 {
                return false
            }
            n = nodes[n].nextZ
        }
        return true
    }

    /// Cuts off triangles at small local self-intersections (edge `a p`
    /// crossing edge `p.next b`). Returns a node on the remaining ring.
    private mutating func cureLocalIntersections(_ start: Int) -> Int {
        var start = start
        var p = start
        var cured = false
        repeat {
            let a = nodes[p].prev, pn = nodes[p].next, b = nodes[pn].next
            if intersects(a, p, pn, b, includeBoundary: false) && locallyInside(a, b) && locallyInside(b, a) {
                triangles.append(nodes[a].i)
                triangles.append(nodes[p].i)
                triangles.append(nodes[b].i)
                removeNode(p)
                removeNode(pn)
                p = b
                start = b
                cured = true
            }
            p = nodes[p].next
        } while p != start
        return cured ? filterPoints(p) : p
    }

    /// Splits the ring along the first valid diagonal found and triangulates
    /// both halves.
    private mutating func splitEarcut(_ start: Int) {
        var a = start
        repeat {
            var b = nodes[nodes[a].next].next
            while b != nodes[a].prev {
                if nodes[a].i != nodes[b].i && isValidDiagonal(a, b) {
                    var c = splitPolygon(a, b)
                    // Filter collinear points around the cuts.
                    a = filterPoints(a, nodes[a].next)
                    c = filterPoints(c, nodes[c].next)
                    earcutLinked(a)
                    earcutLinked(c)
                    return
                }
                b = nodes[b].next
            }
            a = nodes[a].next
        } while a != start
    }

    // MARK: Holes

    /// Links every hole into the outer ring, producing a single ring.
    private mutating func eliminateHoles(_ data: [Vec2], _ holeIndices: [Int], _ outerNode: Int) -> Int {
        var queue: [Int] = []
        queue.reserveCapacity(holeIndices.count)
        for (k, start) in holeIndices.enumerated() {
            let end = k + 1 < holeIndices.count ? holeIndices[k + 1] : data.count
            guard let list = linkedList(data, start, end, clockwise: false) else { continue }
            if list == nodes[list].next { steiners.append(list) }
            queue.append(getLeftmost(list))
        }

        // Left to right. When the leftmost points of two holes coincide, order
        // them counter-clockwise so each finds the shared point as its bridge.
        let n = nodes
        queue.sort { a, b in
            let p = n[a], q = n[b]
            if p.x != q.x { return p.x < q.x }
            if p.y != q.y { return p.y < q.y }
            let pn = n[p.next], qn = n[q.next]
            return (pn.y - p.y) / (pn.x - p.x) < (qn.y - q.y) / (qn.x - q.x)
        }

        // Seed the bridge-search index with the outer ring; each merged hole
        // appends its own segment.
        // Upper bound: every vertex indexed once, two bridge nodes per hole,
        // plus a partial trailing block per segment.
        let bound = (data.count + 2 * holeIndices.count + blockEdges - 1) / blockEdges + holeIndices.count + 2
        if blockCapacity < bound {
            blocks?.deallocate()
            blocks = .allocate(capacity: bound)
            blockCapacity = bound
        }
        blockCount = 0
        indexSegment(outerNode, outerNode)

        var outerNode = outerNode
        indexActive = true
        for hole in queue { outerNode = eliminateHole(hole, outerNode) }
        indexActive = false

        // Collapse collinear/coincident points across the merged ring once.
        return filterPoints(outerNode)
    }

    /// Bridges one hole into the outer ring; holes without a bridge are dropped.
    private mutating func eliminateHole(_ hole: Int, _ outerNode: Int) -> Int {
        guard let bridge = findHoleBridge(hole, outerNode) else { return outerNode }
        let bridgeReverse = splitPolygon(bridge, hole)

        // Index the merged-in run before filtering. In ring order it goes
        // bridge -> hole ... -> bridgeReverse -> bridge copy -> (bridge's old
        // next), covering the hole's edges and both slit edges. Filtering only
        // drops collinear/coincident points, so the boxes stay supersets.
        indexSegment(bridge, nodes[nodes[bridgeReverse].next].next)

        // Heal collinear/coincident points around the two new slit edges.
        _ = filterPoints(bridgeReverse, nodes[bridgeReverse].next)
        return filterPoints(bridge, nodes[bridge].next)
    }

    /// David Eberly's method for finding an outer ring vertex visible from the
    /// hole's leftmost vertex. Scans the merged ring block by block, skipping
    /// blocks whose bounding box cannot matter.
    private func findHoleBridge(_ hole: Int, _ outerNode: Int) -> Int? {
        guard let blocks else { return nil }
        let hx = nodes[hole].x, hy = nodes[hole].y
        var qx = -Double.infinity
        var m = noNode

        // Find the nearest outer segment crossed by a ray from the hole point
        // to the left; its endpoint with the lesser x is a candidate bridge,
        // unless the ray hits a vertex, which is then chosen.
        if equals(hole, outerNode) { return outerNode }
        for b in 0..<blockCount {
            let box = blocks[b]
            if hy < box.minY || hy > box.maxY || box.minX > hx || box.maxX <= qx { continue }
            let stop = liveBlockStop(b)
            var p = liveBlockHead(b)
            repeat {
                let n = nodes[p].next
                if isLive(p) {
                    if equals(hole, n) { return n }
                    let P = nodes[p], N = nodes[n]
                    if hy <= P.y && hy >= N.y && N.y != P.y {
                        let x = P.x + (hy - P.y) * (N.x - P.x) / (N.y - P.y)
                        if x <= hx && x > qx {
                            qx = x
                            m = P.x < N.x ? p : n
                            if x == hx { return m } // hole touches the outer segment; pick its leftmost endpoint
                        }
                    }
                }
                p = n
            } while p != stop
        }

        guard m != noNode else { return nil }

        // Vertices inside the triangle (hole point, ray intersection, m) could
        // block the bridge; among them pick the one at the minimum angle to
        // the ray. With none, m is visible.
        let mx = nodes[m].x, my = nodes[m].y
        let triangleMinY = min(hy, my), triangleMaxY = max(hy, my) // x span is [mx, hx]
        var tanMin = Double.infinity
        for b in 0..<blockCount {
            let box = blocks[b]
            if box.maxX < mx || box.minX > hx || box.maxY < triangleMinY || box.minY > triangleMaxY { continue }
            let stop = liveBlockStop(b)
            var p = liveBlockHead(b)
            repeat {
                let px = nodes[p].x, py = nodes[p].y
                if isLive(p) && hx >= px && px >= mx && hx != px
                    && pointInTriangle(hy < my ? hx : qx, hy, mx, my, hy < my ? qx : hx, hy, px, py) {
                    let tan = abs(hy - py) / (hx - px) // tangential
                    let n = nodes[p].next
                    // When the hole point sits on p's horizontal edge (a T-junction)
                    // the bridge runs along that edge: valid, though not locally inside.
                    let visible = locallyInside(p, hole) || (py == hy && nodes[n].y == hy && nodes[n].x > hx)
                    if visible && (tan < tanMin
                        || (tan == tanMin && (px > nodes[m].x || (px == nodes[m].x && sectorContainsSector(m, p))))) {
                        m = p
                        tanMin = tan
                    }
                }
                p = nodes[p].next
            } while p != stop
        }
        return m
    }

    // MARK: Hole-bridge index
    //
    // One bounding box per `blockEdges` consecutive ring edges lets the
    // leftward-ray scans in `findHoleBridge` skip whole blocks instead of
    // walking the entire merged ring for every hole (earcut issue #183). The
    // index grows append-only: the outer ring seeds it and each merged hole
    // appends a segment. Segments are independent runs, not a tiling of the
    // ring, since splices land mid-ring. Filtering only removes collinear or
    // coincident points, so a stale box remains a conservative superset; walks
    // skip removed nodes and lazily advance removed heads and stops.

    /// Whether `p` is still linked into its ring.
    @inline(__always)
    private func isLive(_ p: Int) -> Bool { nodes[nodes[p].prev].next == p }

    /// Indexes the run `head..<stop` (the whole ring when `head == stop`) as
    /// blocks of up to `blockEdges` edges, each box bounding both endpoints of
    /// every edge it owns.
    private mutating func indexSegment(_ head: Int, _ stop: Int) {
        var p = head
        repeat {
            if blockCount == blockCapacity { growBlocks() }
            let b = blockCount
            blockCount += 1
            let start = p
            var x0 = nodes[p].x, y0 = nodes[p].y, x1 = x0, y1 = y0
            var k = 0
            repeat {
                let c = nodes[p].next // edge p -> c
                nodes[p].z = b        // z holds the owning block while holes are merged
                let cx = nodes[c].x, cy = nodes[c].y
                if cx < x0 { x0 = cx }
                if cx > x1 { x1 = cx }
                if cy < y0 { y0 = cy }
                if cy > y1 { y1 = cy }
                p = c
                k += 1
            } while k < blockEdges && p != stop
            blocks![b] = Block(minX: x0, minY: y0, maxX: x1, maxY: y1, head: start, stop: p)
        } while p != stop
    }

    /// Never needed within the bound computed in `eliminateHoles`; kept so a
    /// miscount cannot write out of bounds.
    private mutating func growBlocks() {
        let grown = UnsafeMutablePointer<Block>.allocate(capacity: max(2 * blockCapacity, 8))
        if let blocks {
            grown.moveInitialize(from: blocks, count: blockCount)
            blocks.deallocate()
        }
        blocks = grown
        blockCapacity = max(2 * blockCapacity, 8)
    }

    /// After `filterPoints` heals the edge `head -> tail`, grows `head`'s block
    /// box to cover `tail`, which may have lived in another block.
    private func growBlock(_ head: Int, toCover tail: Int) {
        guard let blocks else { return }
        let b = nodes[head].z
        let tx = nodes[tail].x, ty = nodes[tail].y
        if tx < blocks[b].minX { blocks[b].minX = tx }
        if ty < blocks[b].minY { blocks[b].minY = ty }
        if tx > blocks[b].maxX { blocks[b].maxX = tx }
        if ty > blocks[b].maxY { blocks[b].maxY = ty }
    }

    /// The block's exclusive walk bound, advanced past removed nodes.
    private func liveBlockStop(_ b: Int) -> Int {
        var stop = blocks![b].stop
        while !isLive(stop) { stop = nodes[stop].next }
        blocks![b].stop = stop
        return stop
    }

    /// The block's first node, advanced past removed nodes. For a whole-ring
    /// block (head == stop) this advances exactly like `liveBlockStop`, so the
    /// walk still laps the ring.
    private func liveBlockHead(_ b: Int) -> Int {
        var head = blocks![b].head
        while !isLive(head) { head = nodes[head].next }
        blocks![b].head = head
        return head
    }

    private func getLeftmost(_ start: Int) -> Int {
        var p = start, leftmost = start
        repeat {
            let P = nodes[p], L = nodes[leftmost]
            if P.x < L.x || (P.x == L.x && P.y < L.y) { leftmost = p }
            p = nodes[p].next
        } while p != start
        return leftmost
    }

    // MARK: Z-order hashing

    /// Morton code of a point, from coordinates mapped into [0, 32767].
    @inline(__always)
    private func zOrder(_ x: Double, _ y: Double) -> Int {
        spreadBits(Self.quantize((x - minX) * invSize)) | (spreadBits(Self.quantize((y - minY) * invSize)) << 1)
    }

    /// Truncates to an integer clamped to [0, 32767] (NaN maps to 0); clamping
    /// keeps z monotonic for points outside the outer ring's bounding box.
    @inline(__always)
    private static func quantize(_ v: Double) -> Int {
        v > 0 ? (v < 32767 ? Int(v) : 32767) : 0
    }

    /// Computes z-codes for a ring and threads its nodes in z-order (ties
    /// keep ring order, as in earcut's stable radix sort).
    private mutating func indexCurve(_ start: Int) {
        zKeys.removeAll(keepingCapacity: true)
        zNodes.removeAll(keepingCapacity: true)
        var p = start
        repeat {
            let z = zOrder(nodes[p].x, nodes[p].y)
            nodes[p].z = z
            zKeys.append(UInt64(z) << 32 | UInt64(zNodes.count))
            zNodes.append(p)
            p = nodes[p].next
        } while p != start

        zKeys.sort()

        var prev = noNode
        for key in zKeys {
            let node = zNodes[Int(key & 0xFFFF_FFFF)]
            nodes[node].prevZ = prev
            if prev != noNode { nodes[prev].nextZ = node }
            prev = node
        }
        nodes[prev].nextZ = noNode
    }
}
