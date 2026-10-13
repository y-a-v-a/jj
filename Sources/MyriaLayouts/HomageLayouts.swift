import Foundation
import MyriaCore
import MyriaData

// The maps of Jarke J. van Wijk, "Unfolding the Earth: Myriahedral
// Projections", The Cartographic Journal 45(1), 32–42, 2008.

// MARK: - Graticular projections (figures 3 and 4)

/// Cuts along meridians or parallels with van Wijk's graticular weight.
public struct GraticularLayout: Layout {
    public enum Style: String, CaseIterable, Sendable {
        case cylindrical, conical, azimuthal, twoHemispheres, polyconic

        var title: String {
            switch self {
            case .cylindrical: "Cylindrical"
            case .conical: "Conical"
            case .azimuthal: "Azimuthal"
            case .twoHemispheres: "Two Hemispheres"
            case .polyconic: "Polyconic"
            }
        }

        /// (φ₀, W_φ, W_λ, root latitude)
        var defaults: (phi0: Double, wPhi: Double, wLambda: Double, rootLatitude: Double) {
            switch self {
            case .cylindrical: (0, 1, 0.05, 0)
            case .conical: (25, 1, 0.05, 25)
            case .azimuthal: (90, 1, 0.05, 45)
            case .twoHemispheres: (0, -1, 0.05, 45)
            case .polyconic: (0, 0.05, 1, 0)
            }
        }
    }

    public let style: Style

    public init(_ style: Style) { self.style = style }

    public var descriptor: LayoutDescriptor {
        let d = style.defaults
        let (summary, story, symbol): (String, String, String) = switch style {
        case .cylindrical:
            ("Meridian strips hanging from the equator",
             "A high W_φ with φ₀ = 0° makes edges along parallels the strongest near the equator: Prim's algorithm grows the equator into one strip and hangs a gore from every face of it. The gaps between the strips show what a cylindrical projection would have to stretch.",
             "rectangle.split.3x1")
        case .conical:
            ("Strips radiating from the 25th parallel",
             "The same weight with φ₀ = 25°: the strips hang from a parallel instead of the equator and fan out like the gores of a cone.",
             "fan")
        case .azimuthal:
            ("Every meridian a ray from the North Pole",
             "φ₀ = 90°: the tree grows outwards from the pole and the meridian strips become rays. The ever wider gaps towards the south show why azimuthal maps distort so much far from their centre.",
             "sun.max")
        case .twoHemispheres:
            ("Two azimuthal hemispheres, joined at one hinge",
             "A negative W_φ makes the poles strongest and the equator weakest: the globe splits along the equator into two azimuthal hemispheres held together by a single face.",
             "circle.grid.2x1")
        case .polyconic:
            ("Strips along parallels, like Hassler's polyconic",
             "A high W_λ cuts along parallels instead: every parallel unfolds into a curved strip attached to the central meridian, much like the polyconic projection of Hassler (1820). On a 1° graticule (64 800 polygons) the gaps fade and distortion shows as the transparency of the map (figure 4).",
             "water.waves")
        }
        return LayoutDescriptor(
            id: "graticular-\(style.rawValue)", title: style.title, summary: summary, story: story, symbol: symbol,
            category: .homage,
            parameters: [
                .slider("phi0", "Strongest latitude φ₀", -90...90, step: 1, unit: "°", default: d.phi0),
                .slider("lambda0", "Central meridian λ₀", -180...180, step: 1, unit: "°", default: 10),
                .slider("wPhi", "Latitude weight W_φ", -2...2, step: 0.05, default: d.wPhi),
                .slider("wLambda", "Longitude weight W_λ", 0...2, step: 0.05, default: d.wLambda),
            ],
            preferredMesh: style == .polyconic ? .graticule(step: 1) : .graticule(step: 5))
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let d = style.defaults
        let lambda0 = p.value("lambda0", default: 10)
        let phi0 = p.value("phi0", default: d.phi0)
        var weights = Weights.graticule(context.edges, phi0: phi0, lambda0: lambda0,
                                        wPhi: p.value("wPhi", default: d.wPhi), wLambda: p.value("wLambda", default: d.wLambda))
        // Rows either side of φ₀ tie. Always taking the northern row would
        // chain its trapezoids into a cone; alternating keeps the strip straight.
        if case .graticule(let step) = context.spec.kind {
            for (e, info) in context.edges.enumerated() {
                let g = GeoPoint(info.midpoint)
                let column = Int(((g.longitude + 180) / step).rounded(.down))
                let side: Double = g.latitude >= phi0 ? 1 : -1
                weights[e] += 1e-9 * side * (column.isMultiple(of: 2) ? 1 : -1)
            }
        }
        let root = Weights.root(context, latitude: d.rootLatitude, longitude: lambda0)
        return LayoutCut(hinges: context.mesh.hinges(weights: weights), root: root)
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        LayoutAppearance(coloring: .landSea, showGraticule: true)
    }
}

// MARK: - Optimal fold-outs of the Platonic solids (figure 8)

/// The Platonic solids turned so that their cuts cross as little land as
/// possible. "For the tetrahedron a perfect, and for the other platonic
/// solids an almost perfect, mapping is achieved."
public struct PlatonicLayout: Layout {
    public init() {}

    static let solids = PlatonicSolid.allCases

    public var descriptor: LayoutDescriptor {
        LayoutDescriptor(
            id: "platonic", title: "Platonic Solids",
            summary: "Fold-outs that cut as little land as possible",
            story: "Each edge of the solid weighs the land it would cut, sampled at 25 points. For every orientation of the solid the maximum spanning tree gives the best fold-out, and the orientation with the least land cut wins. Van Wijk notes that, apart from the tetrahedron, the continents land where Buckminster Fuller put them in his Dymaxion map.",
            symbol: "cube.transparent", category: .homage,
            parameters: [
                .choice("solid", "Solid", Self.solids.map(\.title), default: 4),
                .toggle("optimise", "Least land cut", default: true,
                        help: "Search all orientations for the one whose cuts cross the least land"),
                .slider("alpha", "Turn α", 0...360, step: 1, unit: "°", default: 0),
                .slider("beta", "Tilt β", 0...180, step: 1, unit: "°", default: 0),
                .slider("gamma", "Turn γ", 0...360, step: 1, unit: "°", default: 0),
            ],
            preferredMesh: .platonic(.icosahedron, levels: 0), requires: [.land], fixesMesh: true)
    }

    func solid(_ p: LayoutParameters) -> PlatonicSolid {
        Self.solids[min(max(p.index("solid", default: 4), 0), Self.solids.count - 1)]
    }

    public func mesh(for p: LayoutParameters, chosen: MeshSpec, body: BodyData) throws -> MeshSpec {
        let solid = solid(p)
        let orientation = p.flag("optimise", default: true)
            ? try PlatonicOptimizer.bestOrientation(solid, data: body)
            : MeshOrientation(alpha: p.value("alpha", default: 0), beta: p.value("beta", default: 0), gamma: p.value("gamma", default: 0))
        return MeshSpec(.platonic(solid, levels: 0), orientation: orientation)
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let landCut = try PlatonicOptimizer.landCut(context)
        // Edges over land are kept as folds, so cuts run through the sea;
        // between equals, edges nearer the equator.
        let tiebreak = context.edges.map { cos(GeoPoint($0.midpoint).latitude * .pi / 180) * 1e-6 }
        let weights = Weights.add(landCut, tiebreak)
        let hinges = context.mesh.hinges(weights: weights)
        let cutLand = zip(hinges, landCut).filter { !$0.0 }.reduce(0) { $0 + $1.1 }
        let cutLength = zip(hinges, context.edges).filter { !$0.0 }.reduce(0) { $0 + $1.1.length }
        let root = Weights.root(context, latitude: 20, longitude: 10)
        return LayoutCut(hinges: hinges, root: root,
                         notes: [String(format: "Cuts cross %.1f° of land over %.0f° of cut edges (%.1f%%)",
                                        cutLand * 180 / .pi, cutLength * 180 / .pi, 100 * cutLand / max(cutLength, 1e-12))])
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        LayoutAppearance(coloring: .landSea, showGraticule: true)
    }
}

/// Searches orientations of a Platonic solid for the fold-out whose cuts
/// cross the least land (van Wijk 2008, figure 8).
public enum PlatonicOptimizer {
    /// Land along each edge of the context's mesh: the fraction of 25
    /// samples on land times the edge's length.
    public static func landCut(_ context: LayoutContext) throws -> [Double] {
        let raster = try landRaster(context.data)
        let p = context.mesh.polyhedron
        return context.mesh.topology.edges.map { edge in
            let a = p.vertices[edge.a], b = p.vertices[edge.b]
            var land = 0.0
            for k in 0..<25 {
                land += raster.value(at: Spherical.slerp(a, b, (Double(k) + 0.5) / 25))
            }
            return land / 25 * a.angle(to: b)
        }
    }

    static func landRaster(_ data: BodyData) throws -> GridField {
        try data.cached("field:landRaster:1440") {
            GridField.coverage(rings: try data.land().rings, width: 1440, height: 720, supersample: 2)
        }
    }

    /// The orientation with the least land on cut edges, cached per solid.
    public static func bestOrientation(_ solid: PlatonicSolid, data: BodyData, step: Double = 4) throws -> MeshOrientation {
        try data.cached("platonic:best:\(solid.rawValue):\(step)") {
            let raster = try landRaster(data)
            let base = solid.polyhedron()
            let topology = try MeshTopology(base)
            let samples = 25
            // Sample directions along every edge of the unrotated solid.
            let points: [[Vec3]] = topology.edges.map { e in
                (0..<samples).map { Spherical.slerp(base.vertices[e.a], base.vertices[e.b], (Double($0) + 0.5) / Double(samples)) }
            }
            let lengths = topology.edges.map { base.vertices[$0.a].angle(to: base.vertices[$0.b]) }
            let dual = topology.edges.map { ($0.leftFace, $0.rightFace) }

            @Sendable func cost(_ o: MeshOrientation) -> Double {
                let m = o.matrix
                let land = points.indices.map { e in
                    points[e].reduce(0) { $0 + raster.value(at: m.apply($1)) } / Double(samples) * lengths[e]
                }
                let hinges = SpanningTree.maximum(nodeCount: base.faceCount, edges: dual, weights: land)
                return zip(hinges, land).reduce(0) { $0 + ($1.0 ? 0 : $1.1) }
            }

            // Coarse search over all orientations, then refine the best few.
            var coarse: [(MeshOrientation, Double)] = []
            let alphas = stride(from: 0.0, to: 360, by: step), betas = stride(from: 0.0, through: 180, by: step)
            let grid = alphas.flatMap { a in betas.map { (a, $0) } }
            let results = parallelMap(grid.count) { i -> (MeshOrientation, Double) in
                let (a, b) = grid[i]
                var best = (MeshOrientation(), Double.infinity)
                for g in stride(from: 0.0, to: 360, by: step) {
                    let o = MeshOrientation(alpha: a, beta: b, gamma: g)
                    let c = cost(o)
                    if c < best.1 { best = (o, c) }
                }
                return best
            }
            coarse = results.sorted { $0.1 < $1.1 }
            var best = coarse[0]
            for (start, _) in coarse.prefix(6) {
                let offsets = stride(from: -step, through: step, by: 1).map { $0 }
                let refined = parallelMap(offsets.count) { i -> (MeshOrientation, Double) in
                    var local = (start, Double.infinity)
                    for db in offsets {
                        for dg in offsets {
                            let o = MeshOrientation(alpha: start.alpha + offsets[i], beta: start.beta + db, gamma: start.gamma + dg)
                            let c = cost(o)
                            if c < local.1 { local = (o, c) }
                        }
                    }
                    return local
                }
                if let r = refined.min(by: { $0.1 < $1.1 }), r.1 < best.1 { best = r }
            }
            return best.0
        }
    }
}

// MARK: - Recursive subdivision (figures 5 and 6)

public struct SubdivisionLayout: Layout {
    public init() {}

    public var descriptor: LayoutDescriptor {
        LayoutDescriptor(
            id: "subdivision", title: "Recursive Subdivision",
            summary: "Self-similar cuts on subdivided Platonic solids",
            story: "Every edge is split at its great-circle midpoint, level after level, and carries weights at its ends and centre that are interpolated as it splits. Edges are weighed by their centre value, highest near the centres of the original edges, plus a small graticular weight to choose the aspect. One expects fractals; instead, at the second level the gaps are almost invisible: the sphere quickly looks flat to the small triangles.",
            symbol: "triangle.inset.filled", category: .homage,
            parameters: [
                .choice("solid", "Solid", PlatonicSolid.allCases.map(\.title), default: 4),
                .slider("levels", "Levels", 1...6, step: 1, default: 5),
                .slider("wPhi", "Latitude weight W_φ", -0.5...0.5, step: 0.01, default: 0.05),
                .slider("wLambda", "Longitude weight W_λ", 0...0.5, step: 0.01, default: 0.02),
                .slider("lambda0", "Central meridian λ₀", -180...180, step: 1, unit: "°", default: 10),
            ],
            preferredMesh: .platonic(.icosahedron, levels: 5), fixesMesh: true)
    }

    public func mesh(for p: LayoutParameters, chosen: MeshSpec, body: BodyData) throws -> MeshSpec {
        let solid = PlatonicSolid.allCases[min(max(p.index("solid", default: 4), 0), 4)]
        let levels = Int(p.value("levels", default: 5))
        return MeshSpec(.platonic(solid, levels: max(1, min(levels, solid == .tetrahedron ? 7 : 6))))
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let intrinsic = context.mesh.intrinsicWeights ?? Array(repeating: 0, count: context.mesh.edgeCount)
        let lambda0 = p.value("lambda0", default: 10)
        let graticule = Weights.graticule(context.edges, phi0: 0, lambda0: lambda0, wPhi: p.value("wPhi", default: 0.05),
                                          wLambda: p.value("wLambda", default: 0.02))
        let weights = Weights.add(intrinsic, graticule)
        return LayoutCut(hinges: context.mesh.hinges(weights: weights), root: Weights.root(context, longitude: lambda0))
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        LayoutAppearance(coloring: .landSea, showGraticule: true)
    }
}

// MARK: - Geography aligned (figure 12)

/// Weights from f, the amount of land in the neighbourhood.
public struct GeoAlignedLayout: Layout {
    public enum Style: String, CaseIterable, Sendable {
        case continents, northUp, separated, coastline
    }

    public let style: Style

    public init(_ style: Style) { self.style = style }

    public var descriptor: LayoutDescriptor {
        let (title, summary, story, symbol): (String, String, String, String) = switch style {
        case .continents:
            ("Aligned with Continents", "w = f: continents whole, cuts through the oceans",
             "f measures how much land lies nearby: a land raster convolved with a Gaussian on the sphere. With w = f the folds follow its contours and the cuts its gradients, so the continents stay whole and the map tears apart in the middle of the oceans. Without anything else to go on, the continents end up in Buckminster Fuller's layout.",
             "globe.europe.africa")
        case .northUp:
            ("North Up, South Down", "f plus a graticular weight for a familiar layout",
             "Adding a graticular weight to f and tuning W_λ and W_φ gives a more familiar layout, resembling a conical projection: the continents with few interrupts, with correct shape and relative position.",
             "arrow.up.and.down")
        case .separated:
            ("Continents and Oceans", "w = |f − f_c|: the map's boundary follows a contour",
             "With |f − f_c| as the weight, the global boundary of the map runs along the contour f = f_c. It is smooth, and divides the surface into the main continents, the oceans, and Antarctica. Van Wijk did not know of a similar map.",
             "square.split.diagonal.2x2")
        case .coastline:
            ("The Coastline of the Earth", "w = −f: the oceans in the middle, the coasts all around",
             "With −f as the weight the oceans become central, surrounded by the coastline of the world: a map that emphasises the importance of the oceans, in the spirit of Athelstan Spilhaus's ocean maps.",
             "drop")
        }
        var parameters: [LayoutParameter] = [
            .choice("sigma", "Smoothing σ", ["5°", "10°", "15°", "20°"], default: 1, help: "Radius of the Gaussian that turns land into f"),
            .slider("lambda0", "Central meridian", -180...180, step: 1, unit: "°", default: style == .coastline ? -150 : 10),
        ]
        if style == .separated {
            parameters.append(.slider("fc", "Contour f_c", 0.05...0.95, step: 0.01, default: 0.3))
        }
        if style == .northUp {
            parameters.append(.slider("wPhi", "Latitude weight W_φ", 0...1, step: 0.01, default: 0.25))
            parameters.append(.slider("wLambda", "Longitude weight W_λ", 0...1, step: 0.01, default: 0.05))
        }
        return LayoutDescriptor(id: "geo-\(style.rawValue)", title: title, summary: summary, story: story, symbol: symbol,
                                category: .homage, parameters: parameters, preferredMesh: .geodesic(frequency: 32),
                                requires: [.land])
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let sigma = ["5", "10", "15", "20"][min(max(p.index("sigma", default: 1), 0), 3)]
        let f = try context.edgeValues(FieldKey("landDensity", sigma))
        let lambda0 = p.value("lambda0", default: 10)
        // A whisper of structure where f is flat, so ties don't decide.
        let order = Weights.graticule(context.edges, phi0: 0, lambda0: lambda0, wPhi: 0.002, wLambda: 0.001)
        let weights: [Double] = switch style {
        case .continents: Weights.add(f, order)
        case .northUp:
            Weights.add(f, Weights.graticule(context.edges, phi0: 0, lambda0: lambda0,
                                             wPhi: p.value("wPhi", default: 0.25), wLambda: p.value("wLambda", default: 0.05)))
        case .separated:
            Weights.add(f.map { abs($0 - p.value("fc", default: 0.3)) }, order)
        case .coastline: Weights.add(f.map { -$0 }, order)
        }
        let rootLatitude: Double = style == .coastline ? -30 : 15
        return LayoutCut(hinges: context.mesh.hinges(weights: weights),
                         root: Weights.root(context, latitude: rootLatitude, longitude: lambda0))
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        LayoutAppearance(coloring: .landSea, showGraticule: true)
    }
}

// MARK: - A point of view (figure 14)

public struct PointOfViewLayout: Layout {
    public init() {}

    public var descriptor: LayoutDescriptor {
        LayoutDescriptor(
            id: "point-of-view", title: "Point of View",
            summary: "The world radiating from one place, with a dash of chance",
            story: "An azimuthal projection on a subdivided icosahedron of 81 920 triangles: the edge weight falls with the distance from a chosen point, plus a small random factor that makes the strips branch like coral. Van Wijk centred it at 40°N, 100°W; choose any centre.",
            symbol: "scope", category: .homage,
            parameters: [
                .slider("lat", "Centre latitude", -90...90, step: 1, unit: "°", default: 40),
                .slider("lon", "Centre longitude", -180...180, step: 1, unit: "°", default: -100),
                .slider("random", "Chance", 0...1, step: 0.01, default: 0.3),
                .slider("seed", "Seed", 1...99, step: 1, default: 7),
            ],
            preferredMesh: .geodesic(frequency: 64))
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let center = GeoPoint(latitude: p.value("lat", default: 40), longitude: p.value("lon", default: -100))
        let distance = Weights.distance(from: center.unitVector, context.edges)
        let noise = Weights.noise(count: distance.count, seed: UInt64(p.value("seed", default: 7)))
        // Distances are in radians (0…π); the chance is scaled to a typical
        // face so it reshuffles neighbours, not continents.
        let typical = (4 * Double.pi / Double(context.mesh.faceCount)).squareRoot()
        let weights = Weights.add(distance.map { -$0 }, noise, scale: p.value("random", default: 0.3) * typical * 40)
        return LayoutCut(hinges: context.mesh.hinges(weights: weights), root: context.face(at: center))
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        LayoutAppearance(coloring: .landSea, showGraticule: false)
    }
}
