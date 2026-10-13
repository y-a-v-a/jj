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
public struct RiverLayout: Layout {
    public init() {}

    public var descriptor: LayoutDescriptor {
        LayoutDescriptor(
            id: "rivers", title: "Rivers",
            summary: "Every great river parts its left bank from its right",
            story: "Each piece of land belongs to the nearest great river, on the bank it lies on. So every river becomes a seam between its two banks: the Amazon, the Mississippi, the Nile, the Congo, the Yangtze and the Ob open up, and the lands between them hang from an equatorial belt beside the oceans. Land far from any great river keeps to its coast.",
            symbol: "point.topleft.down.to.point.bottomright.curvepath", category: .planet,
            parameters: [
                centerParameter,
                .slider("rank", "River detail", 1...8, step: 1, default: 4,
                        help: "Natural Earth scale rank: 1 keeps only the largest rivers"),
                .slider("reach", "Reach", 200...1500, step: 50, unit: " km", default: 700,
                        help: "How far from a river its banks extend"),
            ],
            preferredMesh: .graticule(step: 1), requires: [.land, .rivers])
    }

    /// Points along the rivers with the direction of flow and the river.
    struct RiverPoints: Sendable {
        let index: PointIndex
        let tangents: [Vec3]
        let rivers: [Int]
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let rank = Int(p.value("rank", default: 4))
        let reach = p.value("reach", default: 700) / context.data.body.radius
        let rivers = try context.data.lines(.rivers)
        let points = try context.data.cached("riverPoints:\(rank)") { () -> RiverPoints in
            var points: [Vec3] = [], tangents: [Vec3] = [], ids: [Int] = []
            for (r, line) in rivers.lines.enumerated() where line.attribute <= rank {
                let v = line.points.map(\.unitVector)
                for i in 0..<(v.count - 1) {
                    let a = v[i], b = v[i + 1]
                    let n = max(1, Int((a.angle(to: b) / 0.004).rounded(.up)))
                    let t = (b - a).normalized
                    for k in 0..<n {
                        points.append(Spherical.slerp(a, b, Double(k) / Double(n)))
                        tangents.append(t)
                        ids.append(r)
                    }
                }
            }
            return RiverPoints(index: PointIndex(points), tangents: tangents, rivers: ids)
        }
        let (coastLabels, land) = try landAndSeaLabels(context, minimum: 6)
        let centers = context.faceCenters
        let baseCount = (coastLabels.max() ?? 0) + 1
        // Land: the nearest river and the bank it is on, within reach.
        var labels = coastLabels.indices.map { f -> Int in
            guard land[f], let (i, d) = points.index.nearest(to: centers[f]), d < reach else { return coastLabels[f] }
            let q = points.index.points[i]
            let side = points.tangents[i].cross(centers[f] - q).dot(q) > 0 ? 1 : 0
            return baseCount + points.rivers[i] * 2 + side
        }
        // Banks split by the sea or by other banks become separate pieces;
        // crumbs join a neighbour.
        labels = context.components(of: labels)
        var sizes = [Int: Int]()
        for l in labels { sizes[l, default: 0] += 1 }
        for _ in 0..<6 {
            for f in labels.indices where sizes[labels[f]]! < 6 {
                if let g = context.mesh.topology.neighbors(of: f).first(where: { land[$0] == land[f] && sizes[labels[$0]]! >= 6 }) {
                    labels[f] = labels[g]
                }
            }
            sizes = [:]
            for l in labels { sizes[l, default: 0] += 1 }
        }
        let center = p.value("center", default: 10)
        let root = Weights.root(context, longitude: center)
        // Banks should not be hinged across their river, or the seam closes.
        let crossed = context.cached("rivers:\(rank)") { context.edgesCrossed(by: rivers.segments) { $0 <= Int32(rank) } }
        let hinges = RegionTree(centerLongitude: center)
            .hinges(context, faceGroups: RegionTree.splittingPolarCaps(labels, context: context), root: root, avoid: crossed)
        let landPieces = Set(labels.indices.filter { land[$0] }.map { labels[$0] }).count
        return LayoutCut(hinges: hinges, root: root, faceGroups: land.map { $0 ? 1 : 0 }, groupNames: ["Sea", "Land"],
                         notes: ["\(landPieces) pieces of land"])
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
            preferredMesh: .geodesic(frequency: 32), isTimeDependent: true)
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        let sun = SolarPosition.sunDirection(at: p.date)
        let subsolar = GeoPoint(sun)
        let elevation = context.edges.map { abs($0.midpoint.dot(sun)) }
        let weights = Weights.add(elevation, order(context, center: subsolar.longitude, strength: 0.002))
        return LayoutCut(hinges: context.mesh.hinges(weights: weights), root: context.face(at: subsolar))
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        LayoutAppearance(coloring: .landSea, showGraticule: true, showCities: true, showNight: true)
    }
}
