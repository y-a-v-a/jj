import Foundation
import MyriaCore
import MyriaData
import MyriaLayouts
import Synchronization

/// A cut and unfolded map, ready to draw: the mesh with its caches and
/// overlays, the layout's cut, the projection and its poses.
public final class MapState: Sendable {
    public let layout: LayoutDescriptor
    public let parameters: LayoutParameters
    public let appearance: LayoutAppearance
    public let context: LayoutContext
    public let overlays: MeshOverlays
    public let cut: LayoutCut
    public let projection: MyriahedralProjection
    public let poses: MapPoses
    /// Seconds spent on each stage of the build.
    public let timings: [(String, Double)]
    /// Distinguishes builds, for caches keyed by state.
    public let id = UUID()

    init(layout: LayoutDescriptor, parameters: LayoutParameters, appearance: LayoutAppearance, context: LayoutContext,
         overlays: MeshOverlays, cut: LayoutCut, projection: MyriahedralProjection, poses: MapPoses, timings: [(String, Double)]) {
        self.layout = layout
        self.parameters = parameters
        self.appearance = appearance
        self.context = context
        self.overlays = overlays
        self.cut = cut
        self.projection = projection
        self.poses = poses
        self.timings = timings
    }

    public var mesh: MyriahedralMesh { context.mesh }
    public var data: BodyData { context.data }

    /// Pieces of the map: faces of one group (region, land mass) joined
    /// by hinges. Without groups the map is one piece.
    public var pieceCount: Int {
        context.cached("pieces:\(id)") {
            guard let groups = cut.faceGroups else { return 1 }
            var sets = UnionFind(count: mesh.faceCount)
            for (e, edge) in mesh.topology.edges.enumerated()
            where !projection.unfolding.isCut[e] && groups[edge.leftFace] == groups[edge.rightFace] {
                sets.union(edge.leftFace, edge.rightFace)
            }
            return sets.componentCount
        }
    }

    /// The location and face at a map point, if any face covers it.
    /// - Parameters:
    ///   - slack: gaps narrower than this (map units) count as covered.
    ///   - closing: how far the gaps are closed (see `closedGaps`).
    public func location(atMapPoint q: Vec2, slack: Double = 0, closing: Double = 0) -> (face: Int, location: GeoPoint)? {
        if closing > 0, let gaps = closedGapsIfReady, let hit = gaps.face(at: q, amount: closing, frames: mesh.frames) {
            return (hit.face, GeoPoint(mesh.frames[hit.face].spherePoint(hit.local)))
        }
        return projection.inverse(q, slack: slack).map { ($0.face, $0.point) }
    }

    /// The map with its interrupts removed (van Wijk's figure 13), computed
    /// on first use, which may take a second; nil unless every face is a
    /// triangle.
    public var closedGaps: ClosedGaps? {
        context.cached("closedGaps:\(id)") { ClosedGaps(projection: projection) }
    }

    /// `closedGaps` once computed, without computing it.
    public var closedGapsIfReady: ClosedGaps? {
        context.isCached("closedGaps:\(id)") ? closedGaps : nil
    }

    /// Whether gaps can be closed: every face a triangle.
    public var canCloseGaps: Bool { mesh.polyhedron.faces.allSatisfy { $0.count == 3 } }

    /// Where a place lies on the flat map with the gaps closed by `closing`.
    public func mapPoint(_ p: GeoPoint, closing: Double = 0) -> Vec2 {
        guard closing > 0, let gaps = closedGapsIfReady else { return projection.project(p) }
        let f = mesh.face(containing: p.unitVector)
        guard let local = mesh.frames[f].gnomonic(p.unitVector) else { return projection.project(p) }
        let (a, b, t) = gaps.affine(face: f, local: mesh.frames[f].localVertices, amount: closing)
        return a * local.x + b * local.y + t
    }

    /// The flat map's bounds with the gaps closed by `closing`.
    public func bounds(closing: Double) -> Rect2 {
        guard closing > 0, let gaps = closedGapsIfReady else { return projection.bounds }
        return gaps.bounds(amount: closing, openBounds: projection.bounds)
    }
}

/// Builds maps and keeps the expensive, cut-independent parts (meshes,
/// their samples and overlays) for reuse. Safe to use from any thread.
public final class MapEngine: Sendable {
    public let data: BodyData
    private let meshes = Mutex<[MeshSpec: (context: LayoutContext, overlays: MeshOverlays, used: Int)]>([:])
    private let counter = Mutex(0)
    /// How many meshes to keep around.
    public let capacity: Int

    public init(data: BodyData = .earth, capacity: Int = 6) {
        self.data = data
        self.capacity = capacity
    }

    /// The prepared mesh for a spec (built once, kept while recently used).
    public func prepared(_ spec: MeshSpec) throws -> (context: LayoutContext, overlays: MeshOverlays) {
        let tick = counter.withLock { c in c += 1; return c }
        if let hit = meshes.withLock({ dict -> (LayoutContext, MeshOverlays)? in
            guard let entry = dict[spec] else { return nil }
            dict[spec]!.used = tick
            return (entry.context, entry.overlays)
        }) {
            return hit
        }
        let mesh = try MyriahedralMesh(spec.build())
        let context = LayoutContext(spec: spec, mesh: mesh, data: data)
        let overlays = MeshOverlays(mesh: mesh, data: data)
        return meshes.withLock { dict in
            if let entry = dict[spec] { return (entry.context, entry.overlays) }
            dict[spec] = (context, overlays, tick)
            while dict.count > capacity, let oldest = dict.min(by: { $0.value.used < $1.value.used })?.key {
                dict.removeValue(forKey: oldest)
            }
            return (context, overlays)
        }
    }

    /// Cuts and unfolds a map.
    /// - Parameter mesh: the user's mesh choice; layouts may substitute their own.
    public func build(_ layout: any Layout, parameters: LayoutParameters, mesh chosen: MeshSpec) throws -> MapState {
        var timings: [(String, Double)] = []
        var start = Date()
        func lap(_ name: String) {
            timings.append((name, Date().timeIntervalSince(start)))
            start = Date()
        }
        let spec = try layout.mesh(for: parameters, chosen: chosen, body: data)
        lap("orientation")
        let (context, overlays) = try prepared(spec)
        lap("mesh")
        let cut = try layout.cut(context, parameters: parameters)
        lap("cut")
        let projection = MyriahedralProjection(mesh: context.mesh, hinges: cut.hinges, root: cut.root)
        lap("unfold")
        let poses = MapPoses(projection: projection)
        lap("fold")
        return MapState(layout: layout.descriptor, parameters: parameters, appearance: layout.appearance(parameters),
                        context: context, overlays: overlays, cut: cut, projection: projection, poses: poses,
                        timings: timings)
    }
}

/// Graph colouring of regions: neighbouring regions get different slots.
public enum RegionColoring {
    /// Slot per label (labels ≥ 0), using DSatur: colour the most
    /// constrained label next, with the lowest free slot.
    public static func slots(labels: [Int], mesh: MyriahedralMesh, slotCount: Int) -> [Int: Int] {
        var neighbors: [Int: Set<Int>] = [:]
        for label in labels where label >= 0 { neighbors[label, default: []] = neighbors[label] ?? [] }
        for edge in mesh.topology.edges {
            let a = labels[edge.leftFace], b = labels[edge.rightFace]
            if a >= 0, b >= 0, a != b {
                neighbors[a, default: []].insert(b)
                neighbors[b, default: []].insert(a)
            }
        }
        var slots: [Int: Int] = [:]
        var remaining = Set(neighbors.keys)
        while !remaining.isEmpty {
            let next = remaining.max { a, b in
                let sa = Set(neighbors[a]!.compactMap { slots[$0] }).count
                let sb = Set(neighbors[b]!.compactMap { slots[$0] }).count
                return sa != sb ? sa < sb : (neighbors[a]!.count != neighbors[b]!.count
                    ? neighbors[a]!.count < neighbors[b]!.count : a > b)
            }!
            remaining.remove(next)
            let used = Set(neighbors[next]!.compactMap { slots[$0] })
            slots[next] = (0..<slotCount).first { !used.contains($0) } ?? next % slotCount
        }
        return slots
    }
}
