import Foundation
import MyriaCore
import simd

/// A unit quaternion for interpolating rotations.
public struct Quaternion: Hashable, Sendable {
    public var w, x, y, z: Double

    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w
        self.x = x
        self.y = y
        self.z = z
    }

    public static let identity = Quaternion(w: 1, x: 0, y: 0, z: 0)

    public init(axis: Vec3, angle: Double) {
        let a = axis.normalized, s = sin(angle / 2)
        self.init(w: cos(angle / 2), x: a.x * s, y: a.y * s, z: a.z * s)
    }

    /// From a rotation matrix (Shepperd's method).
    public init(_ m: Mat3) {
        let (m00, m11, m22) = (m.c0.x, m.c1.y, m.c2.z)
        let trace = m00 + m11 + m22
        if trace > 0 {
            let s = (trace + 1).squareRoot() * 2
            self.init(w: s / 4, x: (m.c1.z - m.c2.y) / s, y: (m.c2.x - m.c0.z) / s, z: (m.c0.y - m.c1.x) / s)
        } else if m00 > m11 && m00 > m22 {
            let s = (1 + m00 - m11 - m22).squareRoot() * 2
            self.init(w: (m.c1.z - m.c2.y) / s, x: s / 4, y: (m.c1.x + m.c0.y) / s, z: (m.c2.x + m.c0.z) / s)
        } else if m11 > m22 {
            let s = (1 + m11 - m00 - m22).squareRoot() * 2
            self.init(w: (m.c2.x - m.c0.z) / s, x: (m.c1.x + m.c0.y) / s, y: s / 4, z: (m.c2.y + m.c1.z) / s)
        } else {
            let s = (1 + m22 - m00 - m11).squareRoot() * 2
            self.init(w: (m.c0.y - m.c1.x) / s, x: (m.c2.x + m.c0.z) / s, y: (m.c2.y + m.c1.z) / s, z: s / 4)
        }
        self = normalized
    }

    public var normalized: Quaternion {
        let n = (w * w + x * x + y * y + z * z).squareRoot()
        return Quaternion(w: w / n, x: x / n, y: y / n, z: z / n)
    }

    public var matrix: Mat3 {
        let (xx, yy, zz) = (x * x, y * y, z * z)
        let (xy, xz, yz, wx, wy, wz) = (x * y, x * z, y * z, w * x, w * y, w * z)
        return Mat3(Vec3(1 - 2 * (yy + zz), 2 * (xy + wz), 2 * (xz - wy)),
                    Vec3(2 * (xy - wz), 1 - 2 * (xx + zz), 2 * (yz + wx)),
                    Vec3(2 * (xz + wy), 2 * (yz - wx), 1 - 2 * (xx + yy)))
    }

    public static func * (a: Quaternion, b: Quaternion) -> Quaternion {
        Quaternion(w: a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
                   x: a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
                   y: a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                   z: a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w)
    }

    /// Shortest-path spherical interpolation.
    public static func slerp(_ a: Quaternion, _ b: Quaternion, _ t: Double) -> Quaternion {
        var b = b
        var d = a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z
        if d < 0 {
            b = Quaternion(w: -b.w, x: -b.x, y: -b.y, z: -b.z)
            d = -d
        }
        if d > 0.9995 {
            return Quaternion(w: a.w + (b.w - a.w) * t, x: a.x + (b.x - a.x) * t,
                              y: a.y + (b.y - a.y) * t, z: a.z + (b.z - a.z) * t).normalized
        }
        let theta = acos(d), s = sin(theta)
        let (ka, kb) = (sin((1 - t) * theta) / s, sin(t * theta) / s)
        return Quaternion(w: a.w * ka + b.w * kb, x: a.x * ka + b.x * kb, y: a.y * ka + b.y * kb, z: a.z * ka + b.z * kb)
    }
}

/// Per-face poses of a map at any stage between globe and flat map.
///
/// `fold.poses(unfold:)` keeps the root face fixed in the plane z = 0. A
/// global rigid motion Q(t) then carries the root face from its place on the
/// (rotated) globe at t = 0 to the map's origin at t = 1, so the closed
/// state of every layout is the same globe: switching layouts while closed
/// is seamless.
public final class MapPoses: Sendable {
    public let projection: MyriahedralProjection
    let folding: Folding
    /// Root-local → globe coordinates.
    let rootToGlobe: Pose3

    public init(projection: MyriahedralProjection) {
        self.projection = projection
        folding = Folding(projection: projection)
        let frame = projection.mesh.frames[projection.unfolding.root]
        rootToGlobe = Pose3(rotation: Mat3(frame.xAxis, frame.yAxis, frame.normal), translation: frame.origin)
    }

    /// The flat map: every face's 2D transform as a 3D pose.
    public var flatPoses: [Pose3] {
        projection.unfolding.transforms.map { t in
            Pose3(rotation: Mat3(Vec3(t.cosine, t.sine, 0), Vec3(-t.sine, t.cosine, 0), .unitZ),
                  translation: Vec3(t.translation.x, t.translation.y, 0))
        }
    }

    /// Poses at `unfold` (0 globe, 1 flat), with the globe turned by `globe`.
    public func poses(unfold t: Double, globe: Mat3) -> [Pose3] {
        if t >= 1 { return flatPoses }
        let local = folding.poses(unfold: t)
        let start = Pose3(rotation: globe, translation: .zero).concatenating(rootToGlobe)
        let q = Quaternion.slerp(Quaternion(start.rotation), .identity, t)
        let motion = Pose3(rotation: q.matrix, translation: start.translation * (1 - t))
        return local.map { motion.concatenating($0) }
    }

    /// Writes the poses at `unfold` as rows of 3 × 4 matrices, one call per
    /// face in no particular order, for the GPU. Allocation-free per face.
    public func forEachPoseRows(unfold t: Double, globe: Mat3,
                                _ body: (Int, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) -> Void) {
        if t >= 1 {
            for (f, m) in projection.unfolding.transforms.enumerated() {
                body(f, SIMD4(Float(m.cosine), Float(-m.sine), 0, Float(m.translation.x)),
                     SIMD4(Float(m.sine), Float(m.cosine), 0, Float(m.translation.y)), SIMD4(0, 0, 1, 0))
            }
            return
        }
        let start = Pose3(rotation: globe, translation: .zero).concatenating(rootToGlobe)
        let q = Quaternion.slerp(Quaternion(start.rotation), .identity, t).matrix
        let qm = simd_double3x3(SIMD3(q.c0.x, q.c0.y, q.c0.z), SIMD3(q.c1.x, q.c1.y, q.c1.z), SIMD3(q.c2.x, q.c2.y, q.c2.z))
        let qt = SIMD3(start.translation.x, start.translation.y, start.translation.z) * (1 - t)
        folding.forEachPose(unfold: t) { f, r, tr in
            let m = qm * r, v = qm * tr + qt
            body(f, SIMD4(Float(m[0][0]), Float(m[1][0]), Float(m[2][0]), Float(v.x)),
                 SIMD4(Float(m[0][1]), Float(m[1][1]), Float(m[2][1]), Float(v.y)),
                 SIMD4(Float(m[0][2]), Float(m[1][2]), Float(m[2][2]), Float(v.z)))
        }
    }

    /// Globe coordinates of a face-local point (the closed polyhedron).
    public func globePoint(face: Int, local: Vec2) -> Vec3 {
        projection.mesh.frames[face].planePoint(local)
    }
}

/// Pan and zoom of the map in a view. Map y points north (up); view y points
/// down. `zoom` 1 fits `bounds` into the view.
public struct Viewport: Hashable, Sendable {
    public var bounds: Rect2
    public var size: Vec2
    public var zoom: Double
    /// Map point shown at the view's centre.
    public var center: Vec2
    public var margin: Double
    public static let maximumZoom = 1500.0

    public init(bounds: Rect2, size: Vec2, zoom: Double = 1, center: Vec2? = nil, margin: Double = 16) {
        self.bounds = bounds
        self.size = size
        self.zoom = zoom
        self.center = center ?? bounds.center
        self.margin = margin
    }

    /// View points per map unit.
    public var scale: Double {
        let fit = min((size.x - 2 * margin) / max(bounds.width, 1e-12), (size.y - 2 * margin) / max(bounds.height, 1e-12))
        return max(fit, 1e-9) * zoom
    }

    public func toView(_ p: Vec2) -> Vec2 {
        Vec2(size.x / 2 + (p.x - center.x) * scale, size.y / 2 - (p.y - center.y) * scale)
    }

    public func toMap(_ q: Vec2) -> Vec2 {
        Vec2(center.x + (q.x - size.x / 2) / scale, center.y - (q.y - size.y / 2) / scale)
    }

    /// Zooms by `factor`, keeping the map point under `anchor` (view
    /// coordinates) in place.
    public mutating func zoom(by factor: Double, around anchor: Vec2) {
        let before = toMap(anchor)
        zoom = min(max(zoom * factor, 0.5), Self.maximumZoom)
        let after = toMap(anchor)
        center = center + (before - after)
        clamp()
    }

    /// Moves the map by a drag of `delta` view points.
    public mutating func pan(by delta: Vec2) {
        center = center - Vec2(delta.x / scale, -delta.y / scale)
        clamp()
    }

    /// Keeps the map centre within the map.
    public mutating func clamp() {
        center = Vec2(min(max(center.x, bounds.minX), bounds.maxX), min(max(center.y, bounds.minY), bounds.maxY))
    }

    /// Orthographic projection of world space (map units, z towards the
    /// viewer) into Metal clip space, depth 0…1 over z ∈ [−depth, depth].
    public func matrix(depth: Double = 4) -> simd_float4x4 {
        let s = scale
        let sx = Float(2 * s / size.x), sy = Float(2 * s / size.y)
        let tx = Float(-center.x) * sx, ty = Float(-center.y) * sy
        let sz = Float(-0.5 / depth)
        return simd_float4x4(columns: (SIMD4(sx, 0, 0, 0), SIMD4(0, sy, 0, 0), SIMD4(0, 0, sz, 0), SIMD4(tx, ty, 0.5, 1)))
    }

    /// Blends two viewports (globe view and map view) for fold animations:
    /// centre linearly, scale geometrically.
    public static func blend(_ a: Viewport, _ b: Viewport, _ t: Double) -> Viewport {
        var v = b
        let scale = exp(log(a.scale) * (1 - t) + log(b.scale) * t)
        v.center = Vec2.lerp(a.center, b.center, t)
        v.zoom = scale / max(b.scale / b.zoom, 1e-12)
        return v
    }
}
