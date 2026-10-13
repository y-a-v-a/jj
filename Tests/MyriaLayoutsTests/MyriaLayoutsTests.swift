import Foundation
import Testing
import MyriaCore
import MyriaData
@testable import MyriaLayouts

/// Contexts are expensive; share them between tests.
enum Shared {
    static let data = BodyData.earth
    static let cache = OnceCache()

    static func context(_ kind: MeshKind) throws -> LayoutContext {
        try cache.value(kind.argument) { try LayoutContext(spec: MeshSpec(kind), data: data) }
    }

    static func cut(_ id: String, mesh kind: MeshKind, _ values: [String: Double] = [:],
                    date: Date = Date()) throws -> (LayoutContext, LayoutCut) {
        let layout = try #require(LayoutCatalog.layout(id: id))
        var p = layout.descriptor.defaultParameters
        p.date = date
        for (k, v) in values { p[k] = v }
        let spec = try layout.mesh(for: p, chosen: MeshSpec(kind), body: data)
        let context = spec == MeshSpec(kind) ? try Shared.context(kind) : try LayoutContext(spec: spec, data: data)
        return (context, try layout.cut(context, parameters: p))
    }

    /// Mean of `values` over edges where `select` holds.
    static func mean(_ values: [Double], where select: (Int) -> Bool) -> Double {
        var sum = 0.0, n = 0
        for i in values.indices where select(i) && values[i].isFinite {
            sum += values[i]
            n += 1
        }
        return n > 0 ? sum / Double(n) : .nan
    }
}

@Suite("Every layout cuts a spanning tree")
struct SpanningTreeTests {
    static let ids = LayoutCatalog.available(for: .earth).map(\.descriptor.id)

    @Test(arguments: ids)
    func cutsFormASpanningTree(id: String) throws {
        let (context, cut) = try Shared.cut(id, mesh: .graticule(step: 6), ["optimise": 0, "levels": 2])
        let mesh = context.mesh
        #expect(cut.hinges.count == mesh.edgeCount)
        #expect(cut.hinges.filter { $0 }.count == mesh.faceCount - 1, "F − 1 hinges")
        #expect(cut.hinges.filter { !$0 }.count == mesh.polyhedron.vertexCount - 1, "V − 1 cuts")
        var sets = UnionFind(count: mesh.faceCount)
        for (e, edge) in mesh.topology.edges.enumerated() where cut.hinges[e] { sets.union(edge.leftFace, edge.rightFace) }
        #expect(sets.componentCount == 1, "one connected map")
        #expect((0..<mesh.faceCount).contains(cut.root))
        // Edges inside a cell are never cut.
        for e in mesh.isInternalEdge.indices where mesh.isInternalEdge[e] { #expect(cut.hinges[e]) }
    }

    @Test func catalogueIsConsistent() {
        let ids = LayoutCatalog.all.map(\.descriptor.id)
        #expect(Set(ids).count == ids.count, "unique ids")
        // Every layout but the craters (which need named craters) works on Earth.
        #expect(LayoutCatalog.available(for: .earth).count == ids.count - 1)
        for layout in LayoutCatalog.all {
            let d = layout.descriptor
            #expect(!d.title.isEmpty && !d.summary.isEmpty && d.story.count > 80)
            for p in d.parameters {
                if case .slider(let range, _, _) = p.kind { #expect(range.contains(p.defaultValue), "\(d.id).\(p.id)") }
                if case .choice(let options) = p.kind { #expect(Int(p.defaultValue) < options.count) }
            }
        }
    }
}

@Suite("Van Wijk's graticular projections")
struct GraticularTests {
    /// High W_φ: "cuts along meridians".
    @Test func cylindricalCutsAlongMeridians() throws {
        let (context, cut) = try Shared.cut("graticular-cylindrical", mesh: .graticule(step: 5))
        let edges = context.edges
        let cuts = edges.indices.filter { !cut.hinges[$0] && abs(GeoPoint(edges[$0].midpoint).latitude) < 80 }
        let alongMeridians = cuts.filter { edges[$0].eastWestness > 0.9 }.count
        #expect(Double(alongMeridians) / Double(cuts.count) > 0.97)
        // The equator holds: every edge crossing it is a hinge.
        let equator = edges.indices.filter { abs(GeoPoint(edges[$0].midpoint).latitude) < 0.01 && edges[$0].eastWestness < 0.1 }
        #expect(equator.allSatisfy { cut.hinges[$0] })
    }

    /// High W_λ: "cuts along parallels", like Hassler's polyconic.
    @Test func polyconicCutsAlongParallels() throws {
        let (context, cut) = try Shared.cut("graticular-polyconic", mesh: .graticule(step: 5))
        let edges = context.edges
        let cuts = edges.indices.filter { !cut.hinges[$0] && abs(GeoPoint(edges[$0].midpoint).latitude) < 80 }
        let alongParallels = cuts.filter { edges[$0].eastWestness < 0.1 }.count
        #expect(Double(alongParallels) / Double(cuts.count) > 0.97)
    }

    /// A negative W_φ "gives two hemispheres": the equator is cut but for one hinge.
    @Test func twoHemispheresHangByOneHinge() throws {
        let (context, cut) = try Shared.cut("graticular-twoHemispheres", mesh: .graticule(step: 5))
        let edges = context.edges
        let equator = edges.indices.filter { abs(GeoPoint(edges[$0].midpoint).latitude) < 0.01 && edges[$0].eastWestness < 0.1 }
        #expect(equator.count == 72)
        #expect(equator.filter { cut.hinges[$0] }.count == 1)
    }
}

@Suite("Thematic cuts follow their themes")
struct ThemeTests {
    /// Edges between faces whose nearest shores are far apart lie on the
    /// medial axis of the sea, the "exact middle": they are cut.
    @Test func midOceanCutsAlongTheMedialAxis() throws {
        let (context, cut) = try Shared.cut("mid-ocean", mesh: .geodesic(frequency: 16))
        let land = try context.data.land()
        let coast = CoastIndex(land: land, step: 0.004)
        let nearest = context.faceCenters.map { coast.index.nearest(to: $0)! }
        let d = try context.faceValues(FieldKey("coastDistance"))
        let mesh = context.mesh
        let medial = mesh.topology.edges.indices.filter { e in
            let edge = mesh.topology.edges[e]
            let (l, r) = (edge.leftFace, edge.rightFace)
            guard d[l] < -300, d[r] < -300 else { return false }
            let a = coast.index.points[nearest[l].index], b = coast.index.points[nearest[r].index]
            return a.angle(to: b) * 6371 > 1500
        }
        #expect(medial.count > 50)
        #expect(Double(medial.filter { !cut.hinges[$0] }.count) / Double(medial.count) > 0.85)
    }

    /// Day and night unfold as two pieces, held together by a hinge or two.
    @Test func dayAndNightHangByAThread() throws {
        let date = ISO8601DateFormatter().date(from: "2026-06-21T12:00:00Z")!
        let (context, cut) = try Shared.cut("day-night", mesh: .geodesic(frequency: 16), date: date)
        let sun = SolarPosition.sunDirection(at: date)
        // Edges whose midpoints lie on the terminator (within 0.6°): nearly
        // all of them are cut, so day and night barely touch.
        let onTerminator = context.edges.indices.filter { abs(context.edges[$0].midpoint.dot(sun)) < 0.01 }
        let held = onTerminator.filter { cut.hinges[$0] }
        #expect(onTerminator.count > 30)
        #expect(Double(held.count) / Double(onTerminator.count) < 0.05)
    }

    @Test func windRibbonsFollowTheWind() throws {
        let (context, cut) = try Shared.cut("winds", mesh: .geodesic(frequency: 16))
        let wind = try context.data.wind()
        let alignment = context.edges.map { e -> Double in
            let w = wind.vector(at: e.midpoint)
            return w.length > 1 ? abs(e.crossing.dot(w.normalized)) : .nan
        }
        #expect(Shared.mean(alignment) { cut.hinges[$0] } > Shared.mean(alignment) { !cut.hinges[$0] } + 0.15)
    }

    @Test func populationHoldsTheCrowdsTogether() throws {
        let (context, cut) = try Shared.cut("population", mesh: .geodesic(frequency: 16))
        let density = try context.edgeValues(FieldKey("population", "1"))
        #expect(Shared.mean(density) { cut.hinges[$0] } > 2 * Shared.mean(density) { !cut.hinges[$0] })
    }

    @Test func rainfallTearsTheDryWorld() throws {
        let (context, cut) = try Shared.cut("rainfall", mesh: .geodesic(frequency: 16))
        let rain = try context.edgeValues(FieldKey("precipitation", "annual"))
        #expect(Shared.mean(rain) { cut.hinges[$0] } > 1.2 * Shared.mean(rain) { !cut.hinges[$0] })
    }

    /// Region layouts cut (nearly) every border between their regions.
    @Test(arguments: [("timezones", DatasetID.timeZones), ("tectonic", .plates), ("countries", .countries)])
    func regionBordersAreCut(id: String, dataset: DatasetID) throws {
        let (context, cut) = try Shared.cut(id, mesh: .graticule(step: 2))
        let regions = try context.faceRegions(dataset)
        let borders = context.mesh.topology.edges.indices.filter {
            let e = context.mesh.topology.edges[$0]
            return regions[e.leftFace] >= 0 && regions[e.rightFace] >= 0 && regions[e.leftFace] != regions[e.rightFace]
        }
        // Each region hangs by one hinge on its border; tiny ones make that count.
        let cutBorders = borders.filter { !cut.hinges[$0] }.count
        #expect(Double(cutBorders) / Double(borders.count) > 0.8)
    }

    @Test func coastlinesAreCut() throws {
        let (context, cut) = try Shared.cut("coastline", mesh: .graticule(step: 2))
        let land = try #require(cut.faceGroups)
        let coast = context.mesh.topology.edges.indices.filter {
            let e = context.mesh.topology.edges[$0]
            return land[e.leftFace] != land[e.rightFace]
        }
        #expect(Double(coast.filter { !cut.hinges[$0] }.count) / Double(coast.count) > 0.9)
    }

    /// At sea level the waterline follows today's coast.
    @Test func waterlineAtSeaLevelFollowsTheCoast() throws {
        let (context, cut) = try Shared.cut("waterline", mesh: .geodesic(frequency: 16))
        let land = try context.landFraction()
        let elevation = try context.edgeValues(FieldKey("elevation"))
        // Edges between clear land and clear sea faces are nearly all cut.
        let shore = context.mesh.topology.edges.indices.filter {
            let e = context.mesh.topology.edges[$0]
            return (land[e.leftFace] > 0.9 && land[e.rightFace] < 0.1) || (land[e.leftFace] < 0.1 && land[e.rightFace] > 0.9)
        }
        #expect(Double(shore.filter { !cut.hinges[$0] }.count) / Double(shore.count) > 0.6)
        #expect(Shared.mean(elevation.map(abs)) { !cut.hinges[$0] } < Shared.mean(elevation.map(abs)) { cut.hinges[$0] })
    }

    @Test func oceanBasins() {
        #expect(OceanBasin(GeoPoint(latitude: 30, longitude: -40)) == .atlantic)
        #expect(OceanBasin(GeoPoint(latitude: 0, longitude: -150)) == .pacific)
        #expect(OceanBasin(GeoPoint(latitude: -20, longitude: 75)) == .indian)
        #expect(OceanBasin(GeoPoint(latitude: 35, longitude: 18)) == .atlantic)   // Mediterranean
        #expect(OceanBasin(GeoPoint(latitude: 12, longitude: -88)) == .pacific)  // off El Salvador
        #expect(OceanBasin(GeoPoint(latitude: 15, longitude: -80)) == .atlantic) // Caribbean
        #expect(OceanBasin(GeoPoint(latitude: 85, longitude: 0)) == .arctic)
        #expect(OceanBasin(GeoPoint(latitude: -65, longitude: 100)) == .southern)
    }

    /// "For the tetrahedron a perfect ... mapping is achieved." (figure 8)
    @Test func fieldLabWeighsAnyField() throws {
        // Kept whole where many live, the map is cut where few do; kept
        // whole where few live, the other way round.
        let index = try #require(Body.earth.availableFields.firstIndex { $0.id == "population" })
        func cutAndHinged(_ mode: Int) throws -> (Double, Double) {
            let (context, cut) = try Shared.cut("field-lab", mesh: .geodesic(frequency: 16), ["field": Double(index), "mode": Double(mode)])
            let people = try context.edgeValues(Body.earth.availableFields[index].defaultKey)
            return (Shared.mean(people) { !cut.hinges[$0] }, Shared.mean(people) { cut.hinges[$0] })
        }
        let (cutHigh, hingedHigh) = try cutAndHinged(0), (cutLow, hingedLow) = try cutAndHinged(1)
        #expect(cutHigh < hingedHigh && cutLow > hingedLow, "\(cutHigh) \(hingedHigh) \(cutLow) \(hingedLow)")
    }

    @Test func spilhausPutsAntarcticaAtSea() throws {
        // With −f the cuts run through the land, so Antarctica is torn up
        // along the map's rim; without Antarctica in f it holds together at
        // the centre of the oceans: neighbours across its cuts stay close.
        func antarcticaTorn(_ spilhaus: Bool) throws -> Double {
            let (context, cut) = try Shared.cut("geo-coastline", mesh: .geodesic(frequency: 32), ["spilhaus": spilhaus ? 1 : 0])
            let projection = MyriahedralProjection(mesh: context.mesh, hinges: cut.hinges, root: cut.root)
            let centers = projection.mapPolygons.map(Planar.centroid)
            let typical = (4 * Double.pi / Double(context.mesh.faceCount)).squareRoot()
            let cuts = context.mesh.topology.edges.indices.filter { e in
                !cut.hinges[e] && GeoPoint(context.edges[e].midpoint).latitude < -72
            }
            let torn = cuts.filter { e in
                let edge = context.mesh.topology.edges[e]
                return (centers[edge.leftFace] - centers[edge.rightFace]).length > 6 * typical
            }
            return Double(torn.count) / Double(cuts.count)
        }
        let ocean = try antarcticaTorn(false), spilhaus = try antarcticaTorn(true)
        #expect(spilhaus < ocean * 0.5, "Antarctica torn: \(ocean) without, \(spilhaus) with Antarctica at sea")
    }

    @Test func tetrahedronFoldsOutWithoutCuttingLand() throws {
        let orientation = try PlatonicOptimizer.bestOrientation(.tetrahedron, data: Shared.data, step: 10)
        let context = try LayoutContext(spec: MeshSpec(.platonic(.tetrahedron, levels: 0), orientation: orientation),
                                        data: Shared.data)
        let landCut = try PlatonicOptimizer.landCut(context)
        let hinges = context.mesh.hinges(weights: landCut)
        let cutLand = zip(hinges, landCut).filter { !$0.0 }.reduce(0) { $0 + $1.1 }
        // A tetrahedron edge is 109.5° long; the three cut edges cross under 2° of land.
        #expect(cutLand * 180 / .pi < 2)
    }
}

@Suite("Unfolded maps")
struct UnfoldedMapTests {
    /// "We found empirically that the schemes we use in the following
    /// almost never lead to fold-overs."
    @Test(arguments: ["graticular-cylindrical", "graticular-azimuthal", "geo-continents", "timezones", "mid-ocean", "point-of-view"])
    func foldOversAreRare(id: String) throws {
        let (context, cut) = try Shared.cut(id, mesh: .geodesic(frequency: 12))
        let projection = MyriahedralProjection(mesh: context.mesh, hinges: cut.hinges, root: cut.root)
        #expect(projection.overlapFraction() < 0.02)
    }
}

@Suite("Other worlds unfold too")
struct OtherWorldLayoutTests {
    static let cases: [(String, String)] = [Body.moon, Body.mars].flatMap { body in
        LayoutCatalog.available(for: body).map { (body.id, $0.descriptor.id) }
    }

    @Test(arguments: cases)
    func cutsFormASpanningTree(body: String, id: String) throws {
        let world = try #require(Body.all.first { $0.id == body })
        let data = BodyData.of(world)
        let layout = try #require(LayoutCatalog.layout(id: id))
        var p = layout.defaultParameters(for: world)
        p["optimise"] = 0
        p["levels"] = 2
        let spec = try layout.mesh(for: p, chosen: MeshSpec(.graticule(step: 6)), body: data)
        let context = try LayoutContext(spec: spec, data: data)
        let cut = try layout.cut(context, parameters: p)
        #expect(cut.hinges.filter { !$0 }.count == context.mesh.polyhedron.vertexCount - 1)
    }

    @Test func noEarthOnlyLayoutsElsewhere() {
        let moon = Set(LayoutCatalog.available(for: .moon).map(\.descriptor.id))
        for id in ["timezones", "coastline", "day-night", "rainfall", "countries"] { #expect(!moon.contains(id)) }
        for id in ["waterline", "craters", "graticular-polyconic", "platonic", "geo-coastline"] { #expect(moon.contains(id)) }
    }

    /// On Mars the waterline at −3.8 km cuts between the northern plains
    /// and the southern highlands.
    @Test func marsWaterlineFollowsItsShore() throws {
        let data = BodyData.mars
        let layout = WaterlineLayout()
        let p = layout.defaultParameters(for: .mars)
        #expect(p["level"] == -3800)
        let context = try LayoutContext(spec: MeshSpec(.geodesic(frequency: 16)), data: data)
        let cut = try layout.cut(context, parameters: p)
        let e = try context.edgeValues(FieldKey("elevation"))
        let near = e.indices.filter { abs(e[$0] + 3800) < 300 }
        let nearShare = Double(near.filter { !cut.hinges[$0] }.count) / Double(near.count)
        let overall = Double(cut.hinges.filter { !$0 }.count) / Double(cut.hinges.count)
        // A third of all edges are cut anywhere; along the shore far more.
        #expect(nearShare > 1.4 * overall)
    }
}

@Suite("Finding places")
struct GazetteerTests {
    @Test func findsCitiesWithoutTheirAccents() throws {
        let earth = Gazetteer.of(.earth)
        let sao = try #require(earth.search("sao paulo").first)
        #expect(sao.name == "São Paulo" && sao.kind == .city)
        #expect(abs(sao.location.latitude - -23.5) < 1 && abs(sao.location.longitude - -46.6) < 1)
        // Whole names come before names that merely start with the query.
        #expect(earth.search("Paris").first?.name == "Paris")
        #expect(earth.search("amster").first?.name == "Amsterdam")
        // A word inside a name counts: "york" finds New York.
        #expect(earth.search("york").contains { $0.name == "New York" })
    }

    @Test func everyEntryIsItsOwn() {
        // Three Albanys in the United States: told apart, never confused.
        for world in [BodyData.earth, .moon, .mars] {
            let entries = Gazetteer.of(world).entries
            #expect(Set(entries.map { $0.id }).count == entries.count)
        }
        let albanys = Gazetteer.of(.earth).search("albany", limit: 20).filter { $0.name == "Albany" }
        #expect(Set(albanys.map { $0.detail }).count == albanys.count)
    }

    @Test func countriesAndOceansComeFirst() throws {
        let earth = Gazetteer.of(.earth)
        #expect(earth.search("netherlands").first?.kind == .country)
        let pacific = try #require(earth.search("pacific").first)
        #expect(pacific.kind == .ocean)
        #expect(OceanBasin(pacific.location) == .pacific)
        for basin in OceanBasin.allCases { #expect(OceanBasin(basin.labelPoint) == basin) }
    }

    @Test func otherWorldsHaveTheirOwnNames() throws {
        let moon = Gazetteer.of(.moon), mars = Gazetteer.of(.mars)
        let karman = try #require(moon.search("von karman").first)
        #expect(karman.name.hasPrefix("Von K") && karman.kind == .feature)
        #expect(mars.search("olympus mons").first?.name == "Olympus Mons")
        #expect(mars.search("paris").allSatisfy { $0.kind == .feature })
        #expect(moon.search("x").isEmpty)
    }
}
