import Foundation
import MyriaCore
import MyriaData

/// The parameter every thematic layout shares: where the map is centred.
let centerParameter = LayoutParameter.slider("center", "Centre longitude", -180...180, step: 5, unit: "°", default: 10)

/// A whisper of graticular structure, so that flat stretches of a field
/// unfold in orderly strips instead of by tie-breaking.
func order(_ context: LayoutContext, center: Double, strength: Double = 0.02) -> [Double] {
    Weights.graticule(context.edges, phi0: 0, lambda0: center, wPhi: strength, wLambda: strength / 2)
}

// MARK: - The planet

/// The five oceans, by the conventional limits (simplified from the IHO's).
public enum OceanBasin: Int, CaseIterable, Sendable {
    case arctic, southern, indian, atlantic, pacific

    public var title: String {
        switch self {
        case .arctic: "Arctic Ocean"
        case .southern: "Southern Ocean"
        case .indian: "Indian Ocean"
        case .atlantic: "Atlantic Ocean"
        case .pacific: "Pacific Ocean"
        }
    }

    public init(_ p: GeoPoint) {
        let (lat, lon) = (p.latitude, p.longitude)
        if lat >= 66 { self = .arctic; return }
        if lat <= -58 { self = .southern; return }
        // The Mediterranean, the Black Sea and the Baltic belong to the Atlantic.
        if lat > 30 && lon >= 0 && lon < 60 { self = .atlantic; return }
        if lon >= 20 && lon < 147 && (lat < -2 || lon < 100) { self = .indian; return }
        let westLimit: Double = lat >= 18 ? -100 : (lat > 8 ? -84 : -70)
        if lon >= westLimit && lon < 20 { self = .atlantic; return }
        self = .pacific
    }
}

/// Labels for land and sea: land masses (optionally split further by
/// `separated` edges) and ocean basins. Pieces smaller than `minimum`
/// faces join their surroundings.
func landAndSeaLabels(_ context: LayoutContext, minimum: Int, separated: [Bool]? = nil) throws -> (labels: [Int], isLand: [Bool]) {
    let fraction = try context.landFraction()
    var land = fraction.map { $0 >= 0.5 }
    // Tiny islands join the sea, tiny lakes the land.
    let raw = context.components(of: land.map { $0 ? 1 : 0 })
    var sizes = [Int: Int]()
    for c in raw { sizes[c, default: 0] += 1 }
    for f in land.indices where sizes[raw[f]]! < minimum { land[f].toggle() }
    // Seas by basin, land by connected mass.
    let basins = context.faceLocations.map { OceanBasin($0).rawValue }
    let coarse = land.indices.map { land[$0] ? -1 : basins[$0] }
    let pieces = context.components(of: coarse) { e in separated.map { !$0[e] } ?? true }
    // Fragments of a basin cut off by land (a strait closed at this
    // resolution) rejoin the basin's largest piece only if they are tiny.
    var pieceSizes = [Int: Int]()
    for p in pieces { pieceSizes[p, default: 0] += 1 }
    var labels = pieces
    let mesh = context.mesh
    for _ in 0..<4 {
        var changed = false
        for f in labels.indices where pieceSizes[pieces[f]]! < minimum {
            if let g = mesh.topology.neighbors(of: f).first(where: { pieceSizes[pieces[$0]]! >= minimum && land[$0] == land[f] }) {
                if labels[f] != labels[g] { labels[f] = labels[g]; changed = true }
            }
        }
        if !changed { break }
    }
    return (labels, land)
}

/// Every land mass and every ocean its own piece: cut exactly along the
/// coastline, at the resolution of the mesh.
public struct CoastlineLayout: Layout {
    public init() {}

    public var descriptor: LayoutDescriptor {
        LayoutDescriptor(
            id: "coastline", title: "Coastlines",
            summary: "Land and sea come apart along the shore",
            story: "Every face is land or sea, and the sea is divided into the five oceans. Inside each land mass and each ocean the faces are hinged in rows; across the shore only one hinge per piece is kept, chosen near the equator and so that the piece hangs upright. The coast becomes the map's own edge: continents float free of the oceans that surround them.",
            symbol: "beach.umbrella", category: .planet,
            parameters: [
                centerParameter,
                .slider("island", "Smallest island", 1...200, step: 1, unit: " faces", default: 8,
                        help: "Land masses with fewer faces join the sea around them"),
            ],
            preferredMesh: .graticule(step: 1.5), requires: [.land])
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let (labels, land) = try landAndSeaLabels(context, minimum: Int(p.value("island", default: 8)))
        let center = p.value("center", default: 10)
        let root = Weights.root(context, longitude: center)
        let groups = RegionTree.splittingPolarCaps(labels, context: context)
        let hinges = RegionTree(centerLongitude: center).hinges(context, faceGroups: groups, root: root)
        let landPieces = Set(labels.indices.filter { land[$0] }.map { labels[$0] }).count
        return LayoutCut(hinges: hinges, root: root, faceGroups: land.map { $0 ? 1 : 0 },
                         groupNames: ["Sea", "Land"], notes: ["\(landPieces) land masses"])
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        LayoutAppearance(coloring: .relief, showGraticule: false)
    }
}

/// Cuts down the exact middle of the oceans: the ridges of the distance to
/// the nearest coast.
public struct MidOceanLayout: Layout {
    public init() {}

    public var descriptor: LayoutDescriptor {
        LayoutDescriptor(
            id: "mid-ocean", title: "Mid-Ocean",
            summary: "Torn exactly halfway between the shores",
            story: "Each edge weighs its signed great-circle distance to the nearest coastline: kilometres inland on land, kilometres out to sea at sea. Hinges hold where the coast is near, so the cuts run along the ridges of the distance field: the lines that are equally far from two shores, the true middles of the oceans. Point Nemo, 2 688 km from any land, lies on a seam.",
            symbol: "water.waves.and.arrow.trianglehead.up", category: .planet,
            parameters: [centerParameter],
            preferredMesh: .geodesic(frequency: 40), requires: [.land])
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let distance = try context.edgeValues(FieldKey("coastDistance"))
        let center = p.value("center", default: 10)
        let weights = Weights.add(distance.map { $0 / 1000 }, order(context, center: center))
        return LayoutCut(hinges: context.mesh.hinges(weights: weights), root: Weights.root(context, latitude: 10, longitude: center))
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        LayoutAppearance(coloring: .field(FieldKey("coastDistance")), showGraticule: false)
    }
}

/// The world's great rivers become seams of the map.
///
/// Van Wijk's recipe with a river's weights: each edge on land weighs its
/// distance to the nearest river, so hinges hold along the divides between
/// rivers and the cuts run down the rivers themselves. A cut opens by the
/// curvature of the land that hangs from it, so a river must stay cut from
/// its source all the way to the sea, never hinged across, and hang from its
/// own mouth: then it opens by the curvature of its whole basin.
public struct RiverLayout: Layout {
    public init() {}

    public var descriptor: LayoutDescriptor {
        LayoutDescriptor(
            id: "rivers", title: "Rivers",
            summary: "Every great river parts its left bank from its right",
            story: "Each edge on land weighs its distance to the nearest great river, so the hinges hold along the divides between rivers and the map is cut down the rivers themselves, from their sources to the sea. Each bank hangs from its divide, and a river opens as wide as the curvature of the land that drains into it: the Amazon, the Nile, the Congo and the Ob gape at their mouths, their tributaries open in turn, and the continents stay whole around them. Land and sea part along the shore.",
            symbol: "point.topleft.down.to.point.bottomright.curvepath", category: .planet,
            parameters: [
                centerParameter,
                .slider("rank", "River detail", 1...8, step: 1, default: 4,
                        help: "Natural Earth scale rank: 1 keeps only the largest rivers"),
            ],
            preferredMesh: .graticule(step: 1), requires: [.land, .rivers])
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let rank = Int(p.value("rank", default: 4))
        let center = p.value("center", default: 10)
        let (labels, land) = try landAndSeaLabels(context, minimum: 6)
        // Seas around a pole hang in sectors; land needs no such help, since
        // its rivers open it up.
        let polar = RegionTree.splittingPolarCaps(labels, context: context)
        let groups = labels.indices.map { land[$0] ? labels[$0] : polar[$0] }
        let tree = RegionTree(centerLongitude: center)
        let water = try waterDistance(context, rank: rank)
        let seams = try riverSeams(context, rank: rank, land: land)
        let crossings = context.cached("straits") { straits(context, land: land) }
        let strips = tree.stripWeights(context, faceGroups: groups)
        let tie = order(context, center: center, strength: 0.002)
        let edges = context.mesh.topology.edges
        let interior = edges.indices.map { e -> Double in
            guard land[edges[e].leftFace] && land[edges[e].rightFace] else { return strips[e] }
            let (river, coast) = water[e]
            // Seams are always cut. Where rivers close a loop (a delta, the
            // Casiquiare between the Amazon and the Orinoco) the seam far
            // from the sea gives way, so that every river hangs from its mouth.
            if seams[e] || crossings[e] { return coast / 1000 - 10 }
            // The coast holds only land much nearer to it than to a river,
            // and a gentle slope down to the sea makes a river's way to the
            // coast through its mouth cheaper than through its source.
            return (min(river, 3 * coast) + coast / 4) / 1000 + tie[e]
        }
        let root = Weights.root(context, longitude: center)
        let hinges = tree.hinges(context, faceGroups: groups, root: root, interior: interior, avoid: seams)
        let landPieces = Set(labels.indices.filter { land[$0] }.map { labels[$0] }).count
        return LayoutCut(hinges: hinges, root: root, faceGroups: land.map { $0 ? 1 : 0 }, groupNames: ["Sea", "Land"],
                         notes: ["\(landPieces) land masses"])
    }

    /// Per edge, kilometres from its midpoint to the nearest river of rank
    /// `rank` or less, and to the coast.
    func waterDistance(_ context: LayoutContext, rank: Int) throws -> [(river: Double, coast: Double)] {
        try context.cached("waterDistance:\(rank)") {
            let rivers = try riverIndex(context.data, rank: rank)
            let coast = try coastIndex(context.data)
            let edges = context.edges, radius = context.data.body.radius
            return parallelMap(edges.count) { e in
                let m = edges[e].midpoint
                return ((rivers.nearest(to: m)?.distance ?? .infinity) * radius, (coast.distance(to: m) ?? .infinity) * radius)
            }
        }
    }

    /// Per edge, whether a river runs between the centres of its two faces:
    /// the edges that part one bank from the other. A river crossing the arc
    /// between two face centres passes from one corner's side of their edge
    /// to the other's, so a river's seam edges always join up into one path.
    /// At its mouth the path goes on to the nearest face of sea, to meet the
    /// coast's own cut where the mesh draws a coarser shore.
    func riverSeams(_ context: LayoutContext, rank: Int, land: [Bool]) throws -> [Bool] {
        try context.cached("riverSeams:\(rank)") {
            let mesh = context.mesh, centers = context.faceCenters
            let typical = (4 * Double.pi / Double(mesh.faceCount)).squareRoot()
            let step = min(0.004, typical / 4)
            let coast = try coastIndex(context.data)
            /// The face of sea fewest steps away, if one is near.
            func nearestSea(from p: Vec3) -> Int? {
                var ring = [mesh.face(containing: p)], seen = Set(ring)
                for _ in 0..<6 {
                    if let sea = ring.filter({ !land[$0] }).min(by: { centers[$0].angle(to: p) < centers[$1].angle(to: p) }) {
                        return centers[sea].angle(to: p) < 4 * typical ? sea : nil
                    }
                    ring = ring.flatMap { mesh.topology.neighbors(of: $0) }.filter { seen.insert($0).inserted }
                }
                return nil
            }
            var seams = Array(repeating: false, count: mesh.edgeCount)
            for line in try context.data.lines(.rivers).lines where line.attribute <= rank {
                var points = line.points.map(\.unitVector)
                // The mouth is the end nearer the sea, if the sea is near.
                let ends = [points[0], points[points.count - 1]].map { coast.distance(to: $0) ?? .infinity }
                if min(ends[0], ends[1]) < 1.5 * typical {
                    if ends[0] < ends[1] { points.reverse() }
                    if let sea = nearestSea(from: points[points.count - 1]) { points.append(centers[sea]) }
                }
                for (u, v) in zip(points, points.dropFirst()) {
                    let n = max(1, Int((u.angle(to: v) / step).rounded(.up)))
                    var a = u
                    for k in 1...n {
                        let b = Spherical.slerp(u, v, Double(k) / Double(n))
                        let across = a.cross(b)
                        var faces = [mesh.face(containing: a), mesh.face(containing: b)]
                        if faces[0] != faces[1] { faces.append(mesh.face(containing: (a + b).normalized)) }
                        for f in Set(faces) {
                            for e in mesh.topology.faceEdges[f] where !seams[e] {
                                let c = centers[mesh.topology.edges[e].leftFace], d = centers[mesh.topology.edges[e].rightFace]
                                let between = c.cross(d)
                                seams[e] = c.dot(across) * d.dot(across) < 0 && a.dot(between) * b.dot(between) < 0
                            }
                        }
                        a = b
                    }
                }
            }
            return seams
        }
    }

    /// Seas the mesh closes off (the Mediterranean behind Gibraltar, the
    /// Black Sea behind the Bosporus) reach other sea by a cut across their
    /// strait: the shortest way over land, if it is a few edges long.
    /// Otherwise the curvature of all the land hanging from such a sea's
    /// shore would have to leave it along some river, and tear a continent.
    func straits(_ context: LayoutContext, land: [Bool]) -> [Bool] {
        let mesh = context.mesh, topology = mesh.topology
        let vertexCount = mesh.polyhedron.vertexCount
        let pieces = context.components(of: land.map { $0 ? -1 : 0 })
        var sizes: [Int: Int] = [:]
        for f in pieces.indices where !land[f] { sizes[pieces[f], default: 0] += 1 }
        var cut = Array(repeating: false, count: mesh.edgeCount)
        guard let ocean = sizes.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })?.key else { return cut }
        // The seas each vertex touches.
        var seas = Array(repeating: Set<Int>(), count: vertexCount)
        for (f, face) in mesh.polyhedron.faces.enumerated() where !land[f] { for v in face { seas[v].insert(pieces[f]) } }
        for sea in sizes.keys.sorted() where sea != ocean {
            // Breadth first over land from the sea's shore, three edges deep.
            var from = Array(repeating: -2, count: vertexCount)
            var level = (0..<vertexCount).filter { seas[$0].contains(sea) }
            for v in level { from[v] = -1 }
            search: for _ in 0..<3 {
                var next: [Int] = []
                for v in level {
                    for e in topology.vertexEdges[v] where land[topology.edges[e].leftFace] && land[topology.edges[e].rightFace] {
                        let w = topology.edges[e].a == v ? topology.edges[e].b : topology.edges[e].a
                        guard from[w] == -2 else { continue }
                        from[w] = e
                        if seas[w].contains(where: { $0 != sea }) {
                            var x = w
                            while from[x] >= 0 {
                                let e = from[x]
                                cut[e] = true
                                x = topology.edges[e].a == x ? topology.edges[e].b : topology.edges[e].a
                            }
                            break search
                        }
                        next.append(w)
                    }
                }
                level = next
            }
        }
        return cut
    }

    /// Points every 25 km along the rivers of rank `rank` or less.
    func riverIndex(_ data: BodyData, rank: Int) throws -> PointIndex {
        let rivers = try data.lines(.rivers)
        return try data.cached("riverIndex:\(rank)") {
            var points: [Vec3] = []
            for line in rivers.lines where line.attribute <= rank {
                let v = line.points.map(\.unitVector)
                for (a, b) in zip(v, v.dropFirst()) {
                    let n = max(1, Int((a.angle(to: b) / 0.004).rounded(.up)))
                    for k in 0..<n { points.append(Spherical.slerp(a, b, Double(k) / Double(n))) }
                }
                points.append(v[v.count - 1])
            }
            return PointIndex(points)
        }
    }

    func coastIndex(_ data: BodyData) throws -> CoastIndex {
        let land = try data.land()
        return try data.cached("index:coast") { CoastIndex(land: land) }
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        LayoutAppearance(coloring: .relief, lines: [.rivers], showGraticule: false)
    }
}

/// The lithosphere's own seams: one piece per tectonic plate.
public struct TectonicLayout: Layout {
    public init() {}

    public var descriptor: LayoutDescriptor {
        LayoutDescriptor(
            id: "tectonic", title: "Tectonic Plates",
            summary: "The crust comes apart where it really does",
            story: "Peter Bird's model of 52 plates partitions the globe. Cut along the plate boundaries, each plate unfolds as one piece: the Pacific plate spread wide, the Nazca and Cocos plates beside it, the slivers of Asia like shards. Ridges, trenches and transform faults are drawn in their own colours.",
            symbol: "square.3.layers.3d.down.right", category: .planet,
            parameters: [centerParameter],
            preferredMesh: .graticule(step: 1.5), requires: [.plates, .plateBoundaries])
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let plates = try context.faceRegions(.plates)
        let regions = try context.data.regions(.plates)
        // Faces outside every polygon (gaps in the data) join their neighbours.
        let groups = fillUnassigned(plates, context: context)
        let center = p.value("center", default: 10)
        let root = Weights.root(context, longitude: center)
        let hinges = RegionTree(centerLongitude: center)
            .hinges(context, faceGroups: RegionTree.splittingPolarCaps(groups, context: context), root: root)
        return LayoutCut(hinges: hinges, root: root, faceGroups: groups, groupNames: regions.regions.map(\.name),
                         notes: ["\(Set(groups).count) plates"])
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        LayoutAppearance(coloring: .regions(.plates), lines: [.plateBoundaries], showGraticule: false)
    }
}

/// Gives faces labelled -1 the label of a labelled neighbour.
func fillUnassigned(_ labels: [Int], context: LayoutContext) -> [Int] {
    var labels = labels
    var queue = labels.indices.filter { labels[$0] >= 0 }
    var head = 0
    while head < queue.count {
        let f = queue[head]
        head += 1
        for g in context.mesh.topology.neighbors(of: f) where labels[g] < 0 {
            labels[g] = labels[f]
            queue.append(g)
        }
    }
    return labels.map { max($0, 0) }
}

// MARK: - People

/// Myriamap's map: the seams follow the borders between timezones.
public struct TimeZoneLayout: Layout {
    public init() {}

    public var descriptor: LayoutDescriptor {
        LayoutDescriptor(
            id: "timezones", title: "Timezones",
            summary: "Where the clocks change, the map does too",
            story: "The cuts follow the borders between regions whose clocks differ. Each timezone unfolds like a little polyconic map and hangs from an equatorial belt like a globe gore, upright. With UTC offsets as the grouping the seams move when daylight saving starts or ends. This is the map of myriamap, where JJ began.",
            symbol: "clock", category: .people,
            parameters: [
                centerParameter,
                .choice("grouping", "Borders", ["Distinct clocks", "UTC offset now"], default: 0),
            ],
            preferredMesh: .graticule(step: 1.875), requires: [.timeZones])
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let regions = try context.faceRegions(.timeZones)
        let atlas = try context.data.timeZones()
        var groups = fillUnassigned(regions, context: context)
        var names = atlas.zones.map(\.placeName)
        if p.index("grouping") == 1 {
            let offsets = atlas.zones.map { $0.utcOffset(at: p.date) }
            let distinct = Array(Set(offsets)).sorted()
            let index = Dictionary(uniqueKeysWithValues: distinct.enumerated().map { ($1, $0) })
            groups = groups.map { index[offsets[$0]]! }
            names = distinct.map { TimeZoneRegion.offsetLabel(seconds: $0) }
        }
        let center = p.value("center", default: 10)
        let root = Weights.root(context, longitude: center)
        let hinges = RegionTree(centerLongitude: center)
            .hinges(context, faceGroups: RegionTree.splittingPolarCaps(groups, context: context), root: root)
        return LayoutCut(hinges: hinges, root: root, faceGroups: groups, groupNames: names)
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        LayoutAppearance(coloring: .regions(.timeZones), showGraticule: false, showNight: true)
    }
}

/// Every nation its own piece; the open sea in 30° sectors.
public struct CountriesLayout: Layout {
    public init() {}

    public var descriptor: LayoutDescriptor {
        LayoutDescriptor(
            id: "countries", title: "Nations",
            summary: "Every country its own piece of the puzzle",
            story: "The world as a jigsaw of nations: cut along every international border and coastline, each country unfolds by itself and hangs upright from the equatorial belt. The open sea, which belongs to no one, is sliced into 30° sectors so it can lie flat too.",
            symbol: "flag", category: .people,
            parameters: [centerParameter],
            preferredMesh: .graticule(step: 1), requires: [.countries])
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let countries = try context.faceRegions(.countries)
        let regions = try context.data.regions(.countries)
        let n = regions.count
        let locations = context.faceLocations
        let groups = countries.indices.map { f -> Int in
            if countries[f] >= 0 { return countries[f] }
            let sector = Int(((locations[f].longitude + 180) / 30).rounded(.down)) % 12
            return n + sector
        }
        let center = p.value("center", default: 10)
        let root = Weights.root(context, longitude: center)
        let hinges = RegionTree(centerLongitude: center)
            .hinges(context, faceGroups: RegionTree.splittingPolarCaps(groups, context: context), root: root)
        let names = regions.regions.map(\.name) + (0..<12).map { "Open sea \($0 * 30 - 180)°" }
        return LayoutCut(hinges: hinges, root: root, faceGroups: groups.map { $0 < n ? $0 : -1 }, groupNames: names,
                         notes: ["\(Set(countries.filter { $0 >= 0 }).count) countries"])
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        LayoutAppearance(coloring: .regions(.countries), lines: [.countryBorders], showGraticule: false)
    }
}

/// Where people live stays whole; the empty places tear.
public struct PopulationLayout: Layout {
    public init() {}

    public var descriptor: LayoutDescriptor {
        LayoutDescriptor(
            id: "population", title: "Population",
            summary: "Cut through the empty places, keep the crowds whole",
            story: "A density of people is spread from the populations of 7 000 cities with a Gaussian on the sphere. Edges weigh the density at their midpoints, so the spanning tree holds the crowded world together (the Ganges plain, the Nile, Java, the Pearl River delta) and lets the map tear through the Sahara, Siberia, the Amazon, the polar ice and the open sea.",
            symbol: "person.3", category: .people,
            parameters: [
                centerParameter,
                .choice("sigma", "Spread", ["Sharp", "Medium", "Broad"], default: 1),
            ],
            preferredMesh: .geodesic(frequency: 40), requires: [.places])
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let sigma = ["0.5", "1", "2"][min(max(p.index("sigma", default: 1), 0), 2)]
        let density = try context.edgeValues(FieldKey("population", sigma))
        let center = p.value("center", default: 80)
        let weights = Weights.add(density, order(context, center: center))
        return LayoutCut(hinges: context.mesh.hinges(weights: weights), root: Weights.root(context, latitude: 25, longitude: center))
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        let sigma = ["0.5", "1", "2"][min(max(parameters.index("sigma", default: 1), 0), 2)]
        return LayoutAppearance(coloring: .field(FieldKey("population", sigma)), showGraticule: false, showCities: true)
    }
}

/// The sky lanes stay intact.
public struct FlightsLayout: Layout {
    public init() {}

    public var descriptor: LayoutDescriptor {
        LayoutDescriptor(
            id: "flights", title: "Air Corridors",
            summary: "Cut where no one flies",
            story: "Sixty thousand airline routes, each flown along its great circle, add up to a density of traffic in the sky. The busiest corridors (the North Atlantic, Europe to Asia, the Pacific rim) hold the map together; it tears where no aircraft pass: the South Pacific, the Southern Ocean, the heart of Antarctica.",
            symbol: "airplane", category: .people,
            parameters: [centerParameter],
            preferredMesh: .geodesic(frequency: 40), requires: [.flights])
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let density = try context.edgeValues(FieldKey("flights"))
        let center = p.value("center", default: 10)
        let weights = Weights.add(density, order(context, center: center))
        return LayoutCut(hinges: context.mesh.hinges(weights: weights), root: Weights.root(context, latitude: 40, longitude: center))
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        LayoutAppearance(coloring: .field(FieldKey("flights")), showGraticule: false, showFlights: true)
    }
}

// MARK: - Sky and climate

let monthNames = ["Annual"] + Calendar(identifier: .gregorian).shortMonthSymbols
func monthVariant(_ p: LayoutParameters) -> String {
    let m = p.index("month", default: 0)
    return m == 0 ? "annual" : String(format: "%02d", m)
}

/// The rain belts stay whole; the dry lands and seas come apart.
public struct RainfallLayout: Layout {
    public init() {}

    public var descriptor: LayoutDescriptor {
        LayoutDescriptor(
            id: "rainfall", title: "Rainfall",
            summary: "The wet world holds; the deserts tear",
            story: "Thirty years of satellite and gauge precipitation (GPCP, 1991–2020) weigh the edges. The intertropical convergence zone, the monsoons and the storm tracks hold together; the cuts run through the dry: the Sahara, the subtropical highs over the oceans, the polar deserts. Step through the months and watch the seams follow the monsoon.",
            symbol: "cloud.rain", category: .climate,
            parameters: [centerParameter, .choice("month", "Month", monthNames, default: 0)],
            preferredMesh: .geodesic(frequency: 40), requires: [.precipitation])
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let rain = try context.edgeValues(FieldKey("precipitation", monthVariant(p)))
        let center = p.value("center", default: 10)
        let weights = Weights.add(rain.map { log1p(max($0, 0)) }, order(context, center: center))
        return LayoutCut(hinges: context.mesh.hinges(weights: weights), root: Weights.root(context, longitude: center))
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        LayoutAppearance(coloring: .field(FieldKey("precipitation", monthVariant(parameters))), showGraticule: false)
    }
}

/// Strips that follow the prevailing winds.
public struct WindLayout: Layout {
    public init() {}

    public var descriptor: LayoutDescriptor {
        LayoutDescriptor(
            id: "winds", title: "Prevailing Winds",
            summary: "Ribbons along the trade winds and westerlies",
            story: "A hinge holds two faces together when the wind blows from one to the other: edges weigh how well the line between the faces lines up with the mean surface wind, times its strength. The map peels into ribbons along the trade winds, the westerlies of the roaring forties and the polar easterlies, and breaks in the doldrums and the horse latitudes where the air is still. A nod to van Wijk the flow visualiser.",
            symbol: "wind", category: .climate,
            parameters: [centerParameter, .choice("month", "Month", monthNames, default: 0)],
            preferredMesh: .geodesic(frequency: 40), requires: [.wind])
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let wind = try context.data.wind(monthVariant(p))
        let edges = context.edges
        let alignment = parallelMap(edges.count) { e -> Double in
            let w = wind.vector(at: edges[e].midpoint)
            let speed = w.length
            guard speed > 1e-6 else { return 0 }
            return abs(edges[e].crossing.dot(w / speed)) * min(speed / 4, 2)
        }
        let center = p.value("center", default: 10)
        let weights = Weights.add(alignment, order(context, center: center, strength: 0.05))
        return LayoutCut(hinges: context.mesh.hinges(weights: weights), root: Weights.root(context, latitude: 15, longitude: center))
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        LayoutAppearance(coloring: .field(FieldKey("windSpeed", monthVariant(parameters))), showGraticule: false, showWind: true)
    }
}

/// The world splits along the line between day and night, live.
public struct DayNightLayout: Layout {
    public init() {}

    public var descriptor: LayoutDescriptor {
        LayoutDescriptor(
            id: "day-night", title: "Day and Night",
            summary: "Torn along the terminator, right now",
            story: "Edges weigh how high or low the Sun stands at them, |sin elevation|. The weakest edges run along the terminator, so the globe splits into a day side and a night side, each unfolding like an azimuthal map around the point where the Sun is overhead, or opposite it. The seam moves with the clock: scrub through the day and watch it sweep around the world.",
            symbol: "sun.horizon", category: .climate,
            parameters: [],
            preferredMesh: .geodesic(frequency: 32), isTimeDependent: true, bodies: ["earth"])
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let sun = SolarPosition.sunDirection(at: p.date)
        let subsolar = GeoPoint(sun)
        let elevation = context.edges.map { abs($0.midpoint.dot(sun)) }
        // Day and night are held together by one hinge on the terminator;
        // keep it at dusk on the equator, so night always hangs east of day.
        let dusk = GeoPoint(latitude: 0, longitude: subsolar.longitude + 90).unitVector
        let bridge = context.edges.map { 0.01 * max(0, $0.midpoint.dot(dusk)) }
        let weights = Weights.add(Weights.add(elevation, order(context, center: subsolar.longitude, strength: 0.002)), bridge)
        return LayoutCut(hinges: context.mesh.hinges(weights: weights), root: context.face(at: subsolar))
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        LayoutAppearance(coloring: .landSea, showGraticule: true, showCities: true, showNight: true)
    }
}

// MARK: - Other worlds, and this one

/// Floods the world to a level and tears the map along the shore.
public struct WaterlineLayout: Layout {
    public init() {}

    public var descriptor: LayoutDescriptor {
        LayoutDescriptor(
            id: "waterline", title: "Waterline",
            summary: "Flood the world to any level; the map tears along the shore",
            story: "Choose a water level and the edges weigh how far above or below it the ground lies. The weakest edges run along the shoreline of the flooded world, so the map's outline becomes that shore: the coast of today at 0 m, the coast of the Ice Age at −120 m, on Mars the shoreline of the ocean that may once have filled its northern plains, near −3.8 km, and on Venus, flooded to just below its median height, the plains go under and Ishtar and Aphrodite Terra stand out as continents.",
            symbol: "water.waves", category: .worlds,
            parameters: [
                .slider("level", "Water level", -8000...8000, step: 50, unit: " m", default: 0),
                .slider("center", "Centre longitude", -180...180, step: 5, unit: "°", default: 10),
            ],
            preferredMesh: .geodesic(frequency: 40), requires: [.elevation])
    }

    public func defaults(for body: Body) -> [String: Double] {
        switch body.id {
        case "mars": ["level": -3800, "center": -60]
        case "moon": ["level": -1800, "center": 0]
        // Just below the median height: the plains, planitiae, under water.
        case "venus": ["level": 600, "center": 60]
        default: [:]
        }
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let elevation = try context.edgeValues(FieldKey("elevation"))
        let level = p.value("level", default: 0)
        let center = p.value("center", default: 10)
        let weights = Weights.add(elevation.map { abs($0 - level) / 1000 }, order(context, center: center, strength: 0.05))
        return LayoutCut(hinges: context.mesh.hinges(weights: weights), root: Weights.root(context, latitude: 20, longitude: center))
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        LayoutAppearance(coloring: .relief, showGraticule: false)
    }
}

/// Craters stay whole; the smooth plains tear.
public struct CraterLayout: Layout {
    public init() {}

    public var descriptor: LayoutDescriptor {
        LayoutDescriptor(
            id: "craters", title: "Craters",
            summary: "Every named crater stays whole; the plains tear",
            story: "Each crater the International Astronomical Union has named is spread over its own disc. Edges weigh the crater density, so the spanning tree holds the battered highlands together and the map tears through the smooth, young plains: the lunar maria, the northern lowlands of Mars.",
            symbol: "circle.dotted.circle", category: .worlds,
            parameters: [.slider("center", "Centre longitude", -180...180, step: 5, unit: "°", default: 0)],
            preferredMesh: .geodesic(frequency: 40), requires: [.features])
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let density = try context.edgeValues(FieldKey("craters"))
        let center = p.value("center", default: 0)
        let weights = Weights.add(density.map { log1p(max($0, 0)) }, order(context, center: center, strength: 0.05))
        return LayoutCut(hinges: context.mesh.hinges(weights: weights), root: Weights.root(context, latitude: 0, longitude: center))
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        LayoutAppearance(coloring: .relief, showGraticule: false)
    }
}
