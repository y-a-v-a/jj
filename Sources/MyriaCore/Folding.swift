import Foundation
import simd

/// A 3×3 matrix stored by columns.
public struct Mat3: Hashable, Sendable {
    public var c0: Vec3
    public var c1: Vec3
    public var c2: Vec3

    public init(_ c0: Vec3, _ c1: Vec3, _ c2: Vec3) {
        self.c0 = c0
        self.c1 = c1
        self.c2 = c2
    }

    public static let identity = Mat3(.unitX, .unitY, .unitZ)

    @inlinable public func apply(_ v: Vec3) -> Vec3 { c0 * v.x + c1 * v.y + c2 * v.z }

    @inlinable public static func * (a: Mat3, b: Mat3) -> Mat3 { Mat3(a.apply(b.c0), a.apply(b.c1), a.apply(b.c2)) }

    /// Rotation by `angle` about the unit axis `k` (right-hand rule).
    public static func rotation(axis k: Vec3, angle: Double) -> Mat3 {
        let c = cos(angle), s = sin(angle)
        func r(_ v: Vec3) -> Vec3 { v * c + k.cross(v) * s + k * (k.dot(v) * (1 - c)) }
        return Mat3(r(.unitX), r(.unitY), r(.unitZ))
    }

    public static func rotationZ(_ angle: Double) -> Mat3 { rotation(axis: .unitZ, angle: angle) }
}

/// Rigid motion of 3D space.
public struct Pose3: Hashable, Sendable {
    public var rotation: Mat3
    public var translation: Vec3

    public init(rotation: Mat3, translation: Vec3) {
        self.rotation = rotation
        self.translation = translation
    }

    public static let identity = Pose3(rotation: .identity, translation: .zero)

    @inlinable public func apply(_ v: Vec3) -> Vec3 { rotation.apply(v) + translation }

    /// A face-local point, which lies in the plane z = 0.
    @inlinable public func apply(_ q: Vec2) -> Vec3 { rotation.c0 * q.x + rotation.c1 * q.y + translation }

    /// `self` applied after `other`.
    public func concatenating(_ other: Pose3) -> Pose3 {
        Pose3(rotation: rotation * other.rotation, translation: apply(other.translation))
    }
}

/// Folds an unfolded myriahedron back towards the polyhedron, as in van
/// Wijk's animations: every hinge opens by the same fraction of its
/// dihedral angle, so `fold(1)` is the flat map and `fold(0)` the closed
/// polyhedron, seen from outside its root face.
public struct Folding: Sendable {
    let order: [Int]
    let parent: [Int]
    /// Per face: child-local → parent-local when flat.
    let flat: [Pose3]
    /// Per face: hinge point and direction in parent-local coordinates.
    let hingePoint: [Vec3]
    let hingeAxis: [Vec3]
    /// Per face: signed rotation about the hinge that closes it.
    let closingAngle: [Double]

    public init(projection: MyriahedralProjection) {
        let mesh = projection.mesh, unfolding = projection.unfolding
        let n = mesh.faceCount
        var flat = Array(repeating: Pose3.identity, count: n)
        var hingePoint = Array(repeating: Vec3.zero, count: n)
        var hingeAxis = Array(repeating: Vec3.unitX, count: n)
        var closingAngle = Array(repeating: 0.0, count: n)

        func local(_ f: Int, _ v: Int) -> Vec2 {
            mesh.frames[f].localVertices[mesh.polyhedron.faces[f].firstIndex(of: v)!]
        }

        for c in 0..<n where unfolding.parent[c] >= 0 {
            let p = unfolding.parent[c]
            let edge = mesh.topology.edges[unfolding.parentEdge[c]]
            // Child-local → parent-local in the flat state.
            let m = unfolding.transforms[p].inverse.concatenating(unfolding.transforms[c])
            flat[c] = Pose3(rotation: .rotationZ(m.angle), translation: Vec3(m.translation.x, m.translation.y, 0))
            let a = local(p, edge.a), b = local(p, edge.b)
            let point = Vec3(a.x, a.y, 0)
            let axis = Vec3(b.x - a.x, b.y - a.y, 0).normalized
            hingePoint[c] = point
            hingeAxis[c] = axis
            // The polyhedron is convex: closing tips the child away from the
            // parent's outward normal (+z in parent-local coordinates).
            let angle = mesh.frames[p].normal.angle(to: mesh.frames[c].normal)
            let probe = flat[c].apply(Planar.centroid(mesh.frames[c].localVertices))
            let tipped = Mat3.rotation(axis: axis, angle: angle).apply(probe - point) + point
            closingAngle[c] = tipped.z <= 0 ? angle : -angle
        }
        order = unfolding.order
        parent = unfolding.parent
        self.flat = flat
        self.hingePoint = hingePoint
        self.hingeAxis = hingeAxis
        self.closingAngle = closingAngle

        // The same data in depth-first order, as simd values: a frame streams
        // through memory, and every subtree is one contiguous range, so the
        // subtrees can be posed in parallel once their roots are.
        var children = Array(repeating: [Int](), count: n)
        for f in 0..<n where unfolding.parent[f] >= 0 { children[unfolding.parent[f]].append(f) }
        var dfs: [Int] = []
        dfs.reserveCapacity(n)
        var stack = [unfolding.root]
        while let f = stack.popLast() {
            dfs.append(f)
            stack.append(contentsOf: children[f].reversed())
        }
        var position = Array(repeating: 0, count: n)
        for (i, f) in dfs.enumerated() { position[f] = i }
        var size = Array(repeating: 1, count: n)
        for f in dfs.reversed() where unfolding.parent[f] >= 0 { size[unfolding.parent[f]] += size[f] }
        // Split off subtrees of at most n/64 faces; what remains is the trunk.
        let limit = max(256, n / 64)
        var trunk: [Int32] = []
        var tasks: [ClosedRange<Int32>] = []
        var queue = [unfolding.root]
        while let f = queue.popLast() {
            if size[f] <= limit && f != unfolding.root {
                tasks.append(Int32(position[f])...Int32(position[f] + size[f] - 1))
            } else {
                trunk.append(Int32(position[f]))
                queue.append(contentsOf: children[f])
            }
        }
        trunk.sort()
        plan = Plan(
            face: dfs.map { Int32($0) },
            parent: dfs.map { unfolding.parent[$0] < 0 ? -1 : Int32(position[unfolding.parent[$0]]) },
            axis: dfs.map { SIMD3(hingeAxis[$0].x, hingeAxis[$0].y, hingeAxis[$0].z) },
            point: dfs.map { SIMD3(hingePoint[$0].x, hingePoint[$0].y, hingePoint[$0].z) },
            angle: dfs.map { closingAngle[$0] },
            flatR: dfs.map { f in
                let r = flat[f].rotation
                return simd_double3x3(SIMD3(r.c0.x, r.c0.y, r.c0.z), SIMD3(r.c1.x, r.c1.y, r.c1.z), SIMD3(r.c2.x, r.c2.y, r.c2.z))
            },
            flatT: dfs.map { SIMD3(flat[$0].translation.x, flat[$0].translation.y, flat[$0].translation.z) },
            trunk: trunk, tasks: tasks)
    }

    /// Working memory for `forEachPose`, kept between frames by its owner.
    public final class FoldScratch {
        var rotations: [simd_double3x3] = []
        var translations: [SIMD3<Double>] = []

        public init() {}

        func reserve(_ n: Int) {
            if rotations.count < n {
                rotations = [simd_double3x3](repeating: matrix_identity_double3x3, count: n)
                translations = [SIMD3<Double>](repeating: .zero, count: n)
            }
        }
    }

    struct Plan: Sendable {
        let face: [Int32]
        let parent: [Int32]
        let axis: [SIMD3<Double>]
        let point: [SIMD3<Double>]
        let angle: [Double]
        let flatR: [simd_double3x3]
        let flatT: [SIMD3<Double>]
        /// Positions posed one after another before the subtrees.
        let trunk: [Int32]
        /// Contiguous subtrees posed in parallel.
        let tasks: [ClosedRange<Int32>]
    }

    let plan: Plan

    /// The same poses as `poses(unfold:)`, computed with simd, without
    /// allocating per face. Renderers call this every frame of a fold.
    ///
    /// `body` is called once per face, concurrently from several threads,
    /// so it must only write to state owned by that face.
    public func forEachPose(unfold: Double, scratch: FoldScratch? = nil, _ body: (Int, simd_double3x3, SIMD3<Double>) -> Void) {
        let closing = 1 - min(max(unfold, 0), 1)
        let n = plan.face.count
        let work = scratch ?? FoldScratch()
        work.reserve(n)
        plan.face.withUnsafeBufferPointer { face in
        plan.parent.withUnsafeBufferPointer { parent in
        plan.axis.withUnsafeBufferPointer { axis in
        plan.point.withUnsafeBufferPointer { point in
        plan.angle.withUnsafeBufferPointer { angle in
        plan.flatR.withUnsafeBufferPointer { flatR in
        plan.flatT.withUnsafeBufferPointer { flatT in
        work.rotations.withUnsafeMutableBufferPointer { rotations in
        work.translations.withUnsafeMutableBufferPointer { translations in
            // Buffer pointers are values; writing through them needs no inout.
            let R = rotations, T = translations
            @inline(__always) func pose(_ i: Int) {
                let p = Int(parent[i])
                guard p >= 0 else {
                    R[i] = matrix_identity_double3x3
                    T[i] = .zero
                    return
                }
                let k = axis[i]
                let a = angle[i] * closing
                // Rodrigues: R = I + sin θ K + (1 − cos θ) K².
                let c = cos(a), s = sin(a), t = 1 - c
                let hinge = simd_double3x3(
                    SIMD3(t * k.x * k.x + c, t * k.x * k.y + s * k.z, t * k.x * k.z - s * k.y),
                    SIMD3(t * k.x * k.y - s * k.z, t * k.y * k.y + c, t * k.y * k.z + s * k.x),
                    SIMD3(t * k.x * k.z + s * k.y, t * k.y * k.z - s * k.x, t * k.z * k.z + c))
                // pose = parent ∘ (translate(point) ∘ hinge ∘ translate(−point)) ∘ flat
                let local = hinge * (flatT[i] - point[i]) + point[i]
                R[i] = R[p] * hinge * flatR[i]
                T[i] = R[p] * local + T[p]
            }
            // The trunk in order, then every subtree on its own core: each
            // writes only its own range and reads only its root's parent.
            for i in plan.trunk {
                pose(Int(i))
                body(Int(face[Int(i)]), R[Int(i)], T[Int(i)])
            }
            let tasks = plan.tasks
            nonisolated(unsafe) let compute = pose
            nonisolated(unsafe) let deliver = body
            DispatchQueue.concurrentPerform(iterations: tasks.count) { t in
                for i in tasks[t] {
                    compute(Int(i))
                    deliver(Int(face[Int(i)]), R[Int(i)], T[Int(i)])
                }
            }
        }}}}}}}}}
    }

    /// Face-local → world poses at `unfold` in [0, 1] (0 closed, 1 flat). The
    /// root face stays in the plane z = 0 facing +z.
    public func poses(unfold: Double) -> [Pose3] {
        var poses = Array(repeating: Pose3.identity, count: order.count)
        let closing = 1 - min(max(unfold, 0), 1)
        for f in order {
            let p = parent[f]
            guard p >= 0 else { continue }
            let rotation = Mat3.rotation(axis: hingeAxis[f], angle: closingAngle[f] * closing)
            let hinge = Pose3(rotation: rotation, translation: hingePoint[f] - rotation.apply(hingePoint[f]))
            poses[f] = poses[p].concatenating(hinge).concatenating(flat[f])
        }
        return poses
    }
}
