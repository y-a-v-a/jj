import Foundation

/// A k-d tree over points on the unit sphere for exact nearest-neighbour
/// queries. Chord length grows with arc length, so the nearest point in 3D
/// is also the nearest along the sphere.
public struct PointIndex: Sendable {
    public let points: [Vec3]
    /// Point indices in tree order; node `n` covers `order[lo..<hi]` with its
    /// splitting point at the median.
    let order: [Int32]
    let axes: [UInt8]

    public init(_ points: [Vec3]) {
        self.points = points
        var order = (0..<points.count).map(Int32.init)
        var axes = [UInt8](repeating: 0, count: points.count)
        func build(_ lo: Int, _ hi: Int) {
            guard hi - lo > 1 else { return }
            var minV = Vec3(.infinity, .infinity, .infinity), maxV = -minV
            for k in lo..<hi {
                let p = points[Int(order[k])]
                minV = Vec3(min(minV.x, p.x), min(minV.y, p.y), min(minV.z, p.z))
                maxV = Vec3(max(maxV.x, p.x), max(maxV.y, p.y), max(maxV.z, p.z))
            }
            let extent = maxV - minV
            let axis: UInt8 = extent.x >= extent.y && extent.x >= extent.z ? 0 : (extent.y >= extent.z ? 1 : 2)
            let mid = (lo + hi) / 2
            order[lo..<hi].sort { Self.coordinate(points[Int($0)], axis) < Self.coordinate(points[Int($1)], axis) }
            axes[mid] = axis
            build(lo, mid)
            build(mid + 1, hi)
        }
        build(0, points.count)
        self.order = order
        self.axes = axes
    }

    public var isEmpty: Bool { points.isEmpty }

    @inline(__always) static func coordinate(_ p: Vec3, _ axis: UInt8) -> Double {
        axis == 0 ? p.x : (axis == 1 ? p.y : p.z)
    }

    /// Index of the point nearest to `q`, and its distance along the unit
    /// sphere in radians.
    public func nearest(to q: Vec3) -> (index: Int, distance: Double)? {
        guard !points.isEmpty else { return nil }
        var best = -1
        var bestD2 = Double.infinity
        func search(_ lo: Int, _ hi: Int) {
            guard lo < hi else { return }
            let mid = (lo + hi) / 2
            let p = points[Int(order[mid])]
            let d2 = (p - q).lengthSquared
            if d2 < bestD2 {
                bestD2 = d2
                best = Int(order[mid])
            }
            guard hi - lo > 1 else { return }
            let axis = axes[mid]
            let diff = Self.coordinate(q, axis) - Self.coordinate(p, axis)
            if diff < 0 {
                search(lo, mid)
                if diff * diff < bestD2 { search(mid + 1, hi) }
            } else {
                search(mid + 1, hi)
                if diff * diff < bestD2 { search(lo, mid) }
            }
        }
        search(0, points.count)
        // Chord length c relates to the arc θ by c = 2 sin(θ/2).
        return (best, 2 * asin(min(1, bestD2.squareRoot() / 2)))
    }
}
