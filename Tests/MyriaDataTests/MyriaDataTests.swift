import Foundation
import Testing
import MyriaCore
@testable import MyriaData

@Suite("Grids and fields")
struct GridTests {
    @Test(arguments: [GridFile.Header.ValueType.float32, .int16, .uint8])
    func gridFileRoundTrip(type: GridFile.Header.ValueType) throws {
        let values: [Float] = (0..<24).map { Float($0 * 3) }
        var withMissing = values
        withMissing[5] = .nan
        let header = GridFile.Header(width: 6, height: 4, layers: ["a", "b"], type: type, lon0: -150, lat0: -67.5,
                                     dlon: 60, dlat: 45, scale: type == .float32 ? 1 : 0.5, offset: 0, missing: 255,
                                     units: "x", source: "test")
        let grid = GridFile(header: header, layers: [values, withMissing])
        let decoded = try GridFile(data: try grid.encoded())
        #expect(decoded.header == header)
        #expect(decoded.layers[0] == values)
        #expect(decoded.layers[1][5].isNaN)
        #expect(try decoded.layer(named: "b")[6] == 18)
    }

    @Test func bilinearSamplingWrapsLongitude() {
        // Values equal to the cell's column index.
        let w = 8, h = 4
        let field = GridField(width: w, height: h, values: (0..<(w * h)).map { Float($0 % w) })
        #expect(field.value(latitude: field.lat0, longitude: field.lon0) == 0)
        #expect(abs(field.value(latitude: 0, longitude: field.lon0 + field.dlon * 2.5) - 2.5) < 1e-9)
        // Between the last and the first column, across the antimeridian.
        #expect(abs(field.value(latitude: 0, longitude: 180) - 3.5) < 1e-9)
    }

    @Test func gaussianOfAConstantIsConstant() {
        let field = GridField(width: 64, height: 32, values: [Float](repeating: 0.7, count: 64 * 32))
        let smooth = field.sphericalGaussian(sigma: 15)
        for v in smooth.values { #expect(abs(v - 0.7) < 1e-5) }
    }

    @Test func gaussianSpreadsAPoint() {
        var values = [Float](repeating: 0, count: 128 * 64)
        values[32 * 128 + 64] = 1
        let smooth = GridField(width: 128, height: 64, values: values).sphericalGaussian(sigma: 8)
        // The peak stays where it was, falls off with distance and does not
        // depend on the direction (the mask is round on the sphere).
        let peak = smooth[64, 32]
        #expect(peak == smooth.values.max())
        #expect(smooth[64 + 4, 32] < peak)
        let east = smooth.value(at: GeoPoint(latitude: smooth.lat0 + 32 * smooth.dlat, longitude: smooth.lon0 + 64 * smooth.dlon + 8))
        let north = smooth.value(at: GeoPoint(latitude: smooth.lat0 + 32 * smooth.dlat + 8, longitude: smooth.lon0 + 64 * smooth.dlon))
        #expect(abs(east - north) / Double(peak) < 0.08)
    }

    @Test func densityIntegratesToTheTotalWeight() {
        let points = [(GeoPoint(latitude: 10, longitude: 20), 1000.0), (GeoPoint(latitude: -40, longitude: 170), 500.0)]
        let radius = 6371.0
        let d = GridField.density(points: points, width: 720, height: 360, sigma: 2, radius: radius)
        var total = 0.0
        for j in 0..<d.height {
            let lat = (d.lat0 + Double(j) * d.dlat) * .pi / 180
            let cellArea = radius * radius * (d.dlon * .pi / 180) * (d.dlat * .pi / 180) * cos(lat)
            for i in 0..<d.width { total += Double(d[i, j]) * cellArea }
        }
        #expect(abs(total - 1500) / 1500 < 0.02)
    }

    @Test func pointIndexAgreesWithBruteForce() {
        var state: UInt64 = 1
        func random() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53) * 2 - 1
        }
        let points = (0..<2000).map { _ in Vec3(random(), random(), random()).normalized }
        let index = PointIndex(points)
        for _ in 0..<200 {
            let q = Vec3(random(), random(), random()).normalized
            let brute = points.indices.min { (points[$0] - q).lengthSquared < (points[$1] - q).lengthSquared }!
            let found = index.nearest(to: q)!
            #expect(found.index == brute)
            #expect(abs(found.distance - q.angle(to: points[brute])) < 1e-12)
        }
    }

    @Test func subsolarPointAtTheSolstice() {
        let solstice = ISO8601DateFormatter().date(from: "2026-06-21T08:24:00Z")!
        #expect(abs(SolarPosition.subsolarPoint(at: solstice).latitude - 23.44) < 0.05)
    }
}

@Suite("Earth data")
struct EarthDataTests {
    let data = BodyData.earth

    @Test func landAndSea() throws {
        let land = try data.land()
        #expect(land.isLand(GeoPoint(latitude: 52.37, longitude: 4.89)))  // Amsterdam
        #expect(!land.isLand(GeoPoint(latitude: 30, longitude: -40)))      // Atlantic
        #expect(land.isLand(GeoPoint(latitude: -85, longitude: 0)))       // Antarctica
    }

    @Test func landCoversAboutAThirdOfTheGlobe() throws {
        let raster = GridField.coverage(rings: try data.land().rings, width: 720, height: 360, supersample: 2)
        var land = 0.0, total = 0.0
        for j in 0..<raster.height {
            let w = cos((raster.lat0 + Double(j) * raster.dlat) * .pi / 180)
            for i in 0..<raster.width {
                land += Double(raster[i, j]) * w
                total += w
            }
        }
        // 29.2 % of the Earth's surface is land (Antarctica included).
        #expect(abs(land / total - 0.292) < 0.01)
    }

    @Test func timeZonesNameTheirClocks() throws {
        let tz = try data.timeZones()
        let amsterdam = try #require(tz.zone(at: GeoPoint(latitude: 52.37, longitude: 4.89)))
        #expect(amsterdam.timeZone.secondsFromGMT(for: ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z")!) == 3600)
        let tokyo = try #require(tz.zone(at: GeoPoint(latitude: 35.68, longitude: 139.69)))
        #expect(tokyo.utcOffset(at: Date()) == 9 * 3600)
    }

    /// "As a result, for instance the value for the South Pole is similar to
    /// that of the centre of South America." (van Wijk 2008, on figure 9)
    @Test func vanWijkLandDensity() throws {
        let f = try data.field(FieldKey("landDensity", "10"))
        let southPole = f.value(latitude: -90, longitude: 0)
        let southAmerica = f.value(latitude: -10, longitude: -55)
        let pacific = f.value(latitude: -30, longitude: -130)
        #expect(abs(southPole - southAmerica) < 0.15)
        #expect(southAmerica > 0.6)
        #expect(pacific < 0.1)
        #expect(f.range.lowerBound >= 0 && f.range.upperBound <= 1.0001)
    }

    @Test func coastDistanceIsSigned() throws {
        let d = try data.field(FieldKey("coastDistance"))
        // Point Nemo, the oceanic pole of inaccessibility: 2,688 km from land.
        let nemo = d.value(latitude: -48.88, longitude: -123.39)
        #expect(nemo < -2400 && nemo > -2900)
        // The centre of Australia is far inland; Amsterdam is near the coast.
        #expect(d.value(latitude: -25, longitude: 134) > 500)
        #expect(abs(d.value(latitude: 52.37, longitude: 4.89)) < 80)
    }
}

@Suite("Earth datasets")
struct EarthDatasetTests {
    let data = BodyData.earth

    @Test func everyDatasetLoads() throws {
        for d in Body.earth.datasets {
            #expect(FileManager.default.fileExists(atPath: try data.url(of: d.id).path), "\(d.id)")
        }
        #expect(try data.regions(.countries).count > 200)
        #expect(try data.regions(.plates).count == 52)
        #expect(try data.lines(.rivers).lines.count > 400)
        #expect(try data.places().places.count > 7000)
        #expect(try data.flights().routes.count > 15000)
    }

    @Test func platesAndCountries() throws {
        let plates = try data.regions(.plates)
        #expect(plates.region(at: GeoPoint(latitude: 0, longitude: -160))?.code == "PA")
        #expect(plates.region(at: GeoPoint(latitude: -80, longitude: 0))?.code == "AN")
        #expect(plates.region(at: GeoPoint(latitude: 35, longitude: 100))?.code == "EU")
        let countries = try data.regions(.countries)
        #expect(countries.region(at: GeoPoint(latitude: 52.37, longitude: 4.89))?.code == "NLD")
        #expect(countries.region(at: GeoPoint(latitude: -15.8, longitude: -47.9))?.code == "BRA")
        #expect(countries.region(at: GeoPoint(latitude: 30, longitude: -40)) == nil)
    }

    @Test func boundaryKindsAreAllPresent() throws {
        let kinds = Set(try data.lines(.plateBoundaries).lines.map(\.attribute))
        for kind in [PlateBoundaryKind.ridge, .subduction, .transform] { #expect(kinds.contains(kind.rawValue)) }
    }

    @Test func climateFieldsMakeSense() throws {
        let rain = try data.field(FieldKey("precipitation", "annual"))
        #expect(rain.value(latitude: 0, longitude: -60) > 4 * rain.value(latitude: 23, longitude: 10))
        // The Indian monsoon: Mumbai is wet in July and dry in January.
        let july = try data.field(FieldKey("precipitation", "07")), january = try data.field(FieldKey("precipitation", "01"))
        #expect(july.value(latitude: 19, longitude: 73) > 10 * january.value(latitude: 19, longitude: 73))
        // Trade winds blow from the east, the roaring forties from the west.
        let wind = try data.wind()
        let trade = wind.vector(at: GeoPoint(latitude: 15, longitude: -140).unitVector)
        let forties = wind.vector(at: GeoPoint(latitude: -45, longitude: 90).unitVector)
        #expect(trade.dot(Spherical.tangentFrame(at: GeoPoint(latitude: 15, longitude: -140).unitVector).east) < -3)
        #expect(forties.dot(Spherical.tangentFrame(at: GeoPoint(latitude: -45, longitude: 90).unitVector).east) > 5)
        let elevation = try data.field(FieldKey("elevation"))
        #expect(elevation.value(latitude: 27.99, longitude: 86.93) > 5000)
        #expect(elevation.value(latitude: 11.35, longitude: 142.2) < -6000)
    }

    @Test func peopleLiveInCities() throws {
        let population = try data.field(FieldKey("population", "1"))
        #expect(population.value(latitude: 23.8, longitude: 90.4) > population.value(latitude: 23, longitude: 10) + 2)
        let nearest = try #require(try data.places().nearest(to: GeoPoint(latitude: 48.85, longitude: 2.35).unitVector))
        #expect(nearest.place.name == "Paris")
    }
}

@Suite("Other worlds")
struct OtherWorldTests {
    @Test func marsHasItsLandmarks() throws {
        let mars = BodyData.mars
        let elevation = try mars.field(FieldKey("elevation"))
        #expect(elevation.value(latitude: 18.65, longitude: -133.8) > 18_000)   // Olympus Mons
        #expect(elevation.value(latitude: -42.4, longitude: 70.5) < -6_000)     // Hellas Planitia
        let olympus = try #require(try mars.features().features.first { $0.name == "Olympus Mons" })
        #expect(abs(olympus.lat - 18.65) < 0.5 && abs(olympus.lon + 133.8) < 0.5)
    }

    @Test func theMoonHasItsLandmarks() throws {
        let moon = BodyData.moon
        let elevation = try moon.field(FieldKey("elevation"))
        // South Pole–Aitken, the largest basin, lies far below the highlands.
        #expect(elevation.value(latitude: -53, longitude: -169) < -5_000)
        #expect(try moon.features().features.contains { $0.name == "Tycho" })
        // High ground is about half the surface, by construction of f.
        let f = try moon.field(FieldKey("landDensity", "10"))
        #expect(abs(f.quantile(0.5) - 0.5) < 0.2)
    }

    @Test func worldsHaveTheirOwnCatalogues() {
        #expect(Body.all.map(\.id) == ["earth", "moon", "mars"])
        #expect(!Body.moon.hasSeas && !Body.mars.hasSeas && Body.earth.hasSeas)
        #expect(Body.mars.availableFields.contains { $0.id == "craters" })
        #expect(!Body.mars.has(.land))
    }
}
