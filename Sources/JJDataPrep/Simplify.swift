import Foundation
import MyriaCore

/// Planar geometry on (longitude, latitude) degrees: Douglas–Peucker
/// simplification, rounding/validation of output rings and lines, antimeridian
/// splitting and even–odd containment.
enum Planar {
    static func segmentDistance(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Double {
        let ab = b - a
        let l2 = ab.lengthSquared
        guard l2 > 0 else { return (p - a).length }
        let t = max(0, min(1, (p - a).dot(ab) / l2))
        return (p - (a + ab * t)).length
    }

    /// Douglas–Peucker significance of every point: the endpoints are
    /// infinitely significant, and an interior point survives simplification
    /// at tolerance ε exactly when its significance exceeds ε (significance is
    /// capped by the parent split, so thresholding reproduces classic DP).
    static func significance(_ points: [Vec2]) -> [Double] {
        let n = points.count
        var s = [Double](repeating: 0, count: n)
        guard n > 0 else { return s }
        s[0] = .infinity
        s[n - 1] = .infinity
        var stack: [(Int, Int, Double)] = [(0, n - 1, .infinity)]
        while let (a, b, cap) = stack.popLast() {
            guard b > a + 1 else { continue }
            var best = a + 1, bestDistance = -1.0
            for i in (a + 1)..<b {
                let d = segmentDistance(points[i], points[a], points[b])
                if d > bestDistance { bestDistance = d; best = i }
            }
            let d = min(bestDistance, cap)
            s[best] = d
            stack.append((a, best, d))
            stack.append((best, b, d))
        }
        return s
    }

    /// Douglas–Peucker with a guaranteed minimum number of interior points
    /// (taken in order of significance) so that rings cannot collapse.
    static func douglasPeucker(_ points: [Vec2], tolerance: Double, minInterior: Int = 0) -> [Vec2] {
        guard points.count > 2 else { return points }
        let s = significance(points)
        var keep = s.map { $0 > tolerance }
        let interior = 1..<(points.count - 1)
        let kept = interior.filter { keep[$0] }.count
        let wanted = min(minInterior, interior.count)
        if kept < wanted {
            let candidates = interior.filter { !keep[$0] }.sorted { s[$0] != s[$1] ? s[$0] > s[$1] : $0 < $1 }
            for i in candidates.prefix(wanted - kept) { keep[i] = true }
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    static func rounded(_ p: Vec2, decimals: Int = 3) -> Vec2 {
        let f = pow(10, Double(decimals))
        return Vec2((p.x * f).rounded() / f + 0, (p.y * f).rounded() / f + 0)
    }

    static func removingConsecutiveDuplicates(_ points: [Vec2]) -> [Vec2] {
        var out: [Vec2] = []
        out.reserveCapacity(points.count)
        for p in points where out.last != p { out.append(p) }
        return out
    }

    /// Rounds a line; nil when fewer than two distinct positions remain.
    static func cleanLine(_ line: [Vec2], decimals: Int = 3) -> [Vec2]? {
        let out = removingConsecutiveDuplicates(line.map { rounded($0, decimals: decimals) })
        return out.count >= 2 ? out : nil
    }

    /// Rounds and closes a ring; nil when it collapses (fewer than four
    /// positions including the closing one, or zero area).
    static func cleanRing(_ ring: [Vec2], decimals: Int = 3) -> [Vec2]? {
        var out = removingConsecutiveDuplicates(ring.map { rounded($0, decimals: decimals) })
        while out.count > 1, out.first == out.last { out.removeLast() }
        guard out.count >= 3 else { return nil }
        out.append(out[0])
        return signedArea(out) != 0 ? out : nil
    }

    /// Shoelace area of a closed ring (positive when counter-clockwise in lon/lat).
    static func signedArea(_ ring: [Vec2]) -> Double {
        guard ring.count > 2 else { return 0 }
        var sum = 0.0
        for i in 0..<(ring.count - 1) { sum += ring[i].cross(ring[i + 1]) }
        sum += ring[ring.count - 1].cross(ring[0])
        return sum / 2
    }

    /// Simplifies a line, then rounds it; nil when it collapses.
    static func simplifyLine(_ line: [Vec2], tolerance: Double) -> [Vec2]? {
        cleanLine(douglasPeucker(line, tolerance: tolerance))
    }

    /// Simplifies a closed ring (keeping at least a triangle), then rounds it;
    /// nil when it collapses.
    static func simplifyRing(_ ring: [Vec2], tolerance: Double) -> [Vec2]? {
        var closed = removingConsecutiveDuplicates(ring)
        if closed.first != closed.last, let first = closed.first { closed.append(first) }
        guard closed.count >= 4 else { return nil }
        return cleanRing(douglasPeucker(closed, tolerance: tolerance, minInterior: 2))
    }

    /// Simplifies every ring; a polygon whose outer ring collapses is dropped,
    /// collapsed holes are dropped individually.
    static func simplifyPolygons(_ polygons: [[[Vec2]]], tolerance: Double) -> [[[Vec2]]] {
        polygons.compactMap { rings in
            guard let outer = rings.first, let o = simplifyRing(outer, tolerance: tolerance) else { return nil }
            return [o] + rings.dropFirst().compactMap { simplifyRing($0, tolerance: tolerance) }
        }
    }

    /// Splits a line wherever it jumps across the antimeridian, inserting the
    /// interpolated crossing at ±180 on both sides.
    static func splitAtAntimeridian(_ line: [Vec2]) -> [[Vec2]] {
        var parts: [[Vec2]] = []
        var current: [Vec2] = []
        for p in line {
            if let q = current.last, abs(p.x - q.x) > 180 {
                let edge: Double = q.x > 0 ? 180 : -180
                let px = p.x + (q.x > 0 ? 360 : -360)
                let t = (edge - q.x) / (px - q.x)
                let y = q.y + t * (p.y - q.y)
                current.append(Vec2(edge, y))
                parts.append(current)
                current = [Vec2(-edge, y)]
            }
            current.append(p)
        }
        parts.append(current)
        return parts.filter { $0.count >= 2 }
    }

    /// Even–odd containment over all rings of a (multi)polygon in lon/lat space.
    static func contains(_ polygons: [[[Vec2]]], _ p: Vec2) -> Bool {
        var inside = false
        for rings in polygons {
            for ring in rings where ring.count > 2 {
                var j = ring.count - 1
                for i in 0..<ring.count {
                    let a = ring[i], b = ring[j]
                    if (a.y > p.y) != (b.y > p.y), p.x < a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y) {
                        inside.toggle()
                    }
                    j = i
                }
            }
        }
        return inside
    }
}

// MARK: - Topology-preserving simplification

/// A vertex quantised to 1e-6°, used to recognise shared vertices exactly.
struct QKey: Hashable, Comparable {
    let x: Int64
    let y: Int64

    init(_ p: Vec2) {
        x = Int64((p.x * 1e6).rounded())
        y = Int64((p.y * 1e6).rounded())
    }

    var point: Vec2 { Vec2(Double(x) / 1e6, Double(y) / 1e6) }

    static func < (a: QKey, b: QKey) -> Bool { a.x != b.x ? a.x < b.x : a.y < b.y }
}

/// Simplifies a polygon layer without opening gaps between neighbours: rings
/// are cut into arcs at junction vertices (where the set of neighbouring
/// vertices differs from a plain pass-through), each distinct arc is
/// simplified once in a canonical direction, and the rings are reassembled
/// from the simplified arcs. Shared borders therefore stay identical.
enum TopologySimplifier {
    /// `layer`: features → polygons → rings (closed). Returns the same
    /// structure, rounded to 3 decimals, with collapsed rings removed.
    static func simplify(_ layer: [[[[Vec2]]]], tolerance: Double) -> [[[[Vec2]]]] {
        // Quantised cyclic rings (no closing duplicate).
        let keyed: [[[[QKey]]]] = layer.map { polygons in
            polygons.map { rings in
                rings.map { ring in
                    var keys: [QKey] = []
                    for p in ring {
                        let k = QKey(p)
                        if keys.last != k { keys.append(k) }
                    }
                    while keys.count > 1, keys.first == keys.last { keys.removeLast() }
                    return keys
                }
            }
        }

        // Junctions: vertices with other than exactly two distinct neighbours.
        var neighbours: [QKey: Set<QKey>] = [:]
        for ring in keyed.joined().joined() where ring.count >= 3 {
            for i in ring.indices {
                neighbours[ring[i], default: []].insert(ring[(i + ring.count - 1) % ring.count])
                neighbours[ring[i], default: []].insert(ring[(i + 1) % ring.count])
            }
        }
        let junctions = Set(neighbours.filter { $0.value.count != 2 }.keys)

        // Cut each ring into arcs; record the strictest minimum interior point
        // count each canonical arc needs so no ring collapses.
        func arcs(of ring: [QKey]) -> [[QKey]] {
            let n = ring.count
            guard let start = ring.indices.first(where: { junctions.contains(ring[$0]) }) else {
                // No junction: one closed arc with a canonical start and direction.
                let m = ring.indices.min { ring[$0] < ring[$1] }!
                var r = Array(ring[m...] + ring[..<m])
                if r.count > 2, r[r.count - 1] < r[1] { r = [r[0]] + r[1...].reversed() }
                return [r + [r[0]]]
            }
            var result: [[QKey]] = []
            var current = [ring[start]]
            for step in 1...n {
                let k = ring[(start + step) % n]
                current.append(k)
                if junctions.contains(k) {
                    result.append(current)
                    current = [k]
                }
            }
            return result
        }
        func canonical(_ arc: [QKey]) -> (key: [QKey], reversed: Bool) {
            let r = Array(arc.reversed())
            return r.lexicographicallyPrecedes(arc) ? (r, true) : (arc, false)
        }

        var minInterior: [[QKey]: Int] = [:]
        let ringArcs: [[[[[QKey]]]]] = keyed.map { polygons in
            polygons.map { rings in
                rings.map { ring in
                    guard ring.count >= 3 else { return [] }
                    let a = arcs(of: ring)
                    let need = a.count == 1 ? 2 : (a.count == 2 ? 1 : 0)
                    for arc in a {
                        let key = canonical(arc).key
                        minInterior[key] = max(minInterior[key] ?? 0, need)
                    }
                    return a
                }
            }
        }

        var simplified: [[QKey]: [QKey]] = [:]
        for (key, need) in minInterior {
            let points = key.map(\.point)
            let kept = Planar.douglasPeucker(points, tolerance: tolerance, minInterior: need)
            simplified[key] = kept.map(QKey.init)
        }

        return ringArcs.map { polygons in
            polygons.compactMap { rings -> [[Vec2]]? in
                let cleaned: [[Vec2]?] = rings.map { arcs in
                    guard !arcs.isEmpty else { return nil }
                    var ring: [QKey] = []
                    for arc in arcs {
                        let (key, reversed) = canonical(arc)
                        var s = simplified[key]!
                        if reversed { s.reverse() }
                        ring.append(contentsOf: ring.isEmpty ? s[...] : s.dropFirst())
                    }
                    return Planar.cleanRing(ring.map(\.point))
                }
                guard let outer = cleaned.first ?? nil else { return nil }
                return [outer] + cleaned.dropFirst().compactMap { $0 }
            }
        }
    }

    struct SharedEdges {
        /// Directed edge uses over all rings.
        var uses = 0
        /// Uses belonging to an edge used exactly twice, in opposite directions.
        var shared = 0
        /// Total length (degrees) of all edge uses and of those shared ones.
        var length = 0.0, sharedLength = 0.0
    }

    /// How much of the rings' outline is a clean shared border: edges used by
    /// exactly two rings in opposite directions.
    static func sharedEdgeStatistics(_ layer: [[[[Vec2]]]]) -> SharedEdges {
        struct Edge: Hashable { let a: QKey, b: QKey }
        var counts: [Edge: (forward: Int, backward: Int, length: Double)] = [:]
        var stats = SharedEdges()
        for ring in layer.joined().joined() {
            for i in 0..<max(ring.count - 1, 0) {
                let a = QKey(ring[i]), b = QKey(ring[i + 1])
                guard a != b else { continue }
                let length = (ring[i + 1] - ring[i]).length
                stats.uses += 1
                stats.length += length
                if a < b {
                    counts[Edge(a: a, b: b), default: (0, 0, length)].forward += 1
                } else {
                    counts[Edge(a: b, b: a), default: (0, 0, length)].backward += 1
                }
            }
        }
        for c in counts.values where c.forward == 1 && c.backward == 1 {
            stats.shared += 2
            stats.sharedLength += 2 * c.length
        }
        return stats
    }

    static func describe(_ s: SharedEdges) -> String {
        String(format: "%d of %d edge uses shared (%.1f%%), shared outline %.0f° of %.0f° (%.1f%%)",
               s.shared, s.uses, s.uses > 0 ? 100 * Double(s.shared) / Double(s.uses) : 0,
               s.sharedLength, s.length, s.length > 0 ? 100 * s.sharedLength / s.length : 0)
    }
}
