import Foundation
import MyriaData

/// Loads every resource in the Earth, Moon and Mars folders the way the app
/// would and runs structural and geographic sanity checks.
enum Verification {
    final class Report {
        var failures: [String] = []
        func check(_ ok: Bool, _ label: String) {
            print("   [\(ok ? "ok" : "FAIL")] \(label)")
            if !ok { failures.append(label) }
        }
    }

    static func run(_ ws: Workspace) throws {
        let report = Report()
        let layers: [(String, Set<String>, [String])] = [
            ("rivers.geojson", ["LineString", "MultiLineString"], ["name", "rank"]),
            ("lakes.geojson", ["Polygon", "MultiPolygon"], ["name", "rank"]),
            ("countries.geojson", ["Polygon", "MultiPolygon"], ["name", "iso", "continent", "pop", "color", "labelLon", "labelLat"]),
            ("country-borders.geojson", ["LineString", "MultiLineString"], ["name"]),
            ("plates.geojson", ["Polygon", "MultiPolygon"], ["code", "name"]),
            ("plate-boundaries.geojson", ["LineString", "MultiLineString"], ["kind", "plates"]),
        ]
        for (file, types, keys) in layers {
            try checkGeoJSON(ws.output(file), types: types, keys: keys, report: report)
        }
        try checkPlaces(ws.output("places.json"), report: report)
        try checkFlights(ws.output("flights.json"), report: report)
        try checkGrids(ws, report: report)

        let files = try FileManager.default.contentsOfDirectory(at: ws.earthDirectory, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            total += size
            print("   " + url.lastPathComponent.padding(toLength: 26, withPad: " ", startingAt: 0) + formatBytes(size))
        }
        print("   Resources/Earth total: \(formatBytes(total))")
        report.check(total < 25 * 1_048_576, "Earth resources total under 25 MB")
        try checkMoonAndMars(ws, report: report)
        if !report.failures.isEmpty {
            throw PrepError("\(report.failures.count) verification check(s) failed: \(report.failures.joined(separator: "; "))")
        }
    }

    // MARK: GeoJSON

    static func checkGeoJSON(_ url: URL, types: Set<String>, keys: [String], report: Report) throws {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "FeatureCollection",
              let features = root["features"] as? [[String: Any]]
        else { report.check(false, "\(url.lastPathComponent) is a FeatureCollection"); return }

        var vertices = 0, badParts = 0, badCoordinates = 0, badProperties = 0, badTypes = 0
        var lo = (lon: 180.0, lat: 90.0), hi = (lon: -180.0, lat: -90.0)
        func position(_ any: Any) {
            guard let p = any as? [Double], p.count == 2, abs(p[0]) <= 180, abs(p[1]) <= 90,
                  p.allSatisfy({ abs($0 * 1000 - ($0 * 1000).rounded()) < 1e-6 })
            else { badCoordinates += 1; return }
            vertices += 1
            lo = (min(lo.lon, p[0]), min(lo.lat, p[1]))
            hi = (max(hi.lon, p[0]), max(hi.lat, p[1]))
        }
        func line(_ any: Any) {
            let ps = any as? [Any] ?? []
            if ps.count < 2 { badParts += 1 }
            ps.forEach(position)
        }
        func ring(_ any: Any) {
            let ps = any as? [[Double]] ?? []
            if ps.count < 4 || ps.first != ps.last { badParts += 1 }
            ps.forEach(position)
        }
        for f in features {
            let props = f["properties"] as? [String: Any] ?? [:]
            if Set(props.keys) != Set(keys) { badProperties += 1 }
            guard let g = f["geometry"] as? [String: Any], let type = g["type"] as? String, types.contains(type),
                  let c = g["coordinates"] as? [Any]
            else { badTypes += 1; continue }
            switch type {
            case "LineString": line(c)
            case "MultiLineString": c.forEach(line)
            case "Polygon": c.forEach(ring)
            case "MultiPolygon": c.forEach { ($0 as? [Any] ?? []).forEach(ring) }
            default: badTypes += 1
            }
        }
        print("   \(url.lastPathComponent): \(formatBytes(data.count)), \(features.count) features, \(vertices) vertices, "
            + String(format: "lon %.1f…%.1f, lat %.1f…%.1f", lo.lon, hi.lon, lo.lat, hi.lat))
        report.check(!features.isEmpty && badTypes == 0 && badParts == 0 && badCoordinates == 0 && badProperties == 0,
                     "\(url.lastPathComponent): geometry types, part sizes, 3-decimal coordinates, properties \(keys)"
                        + (badTypes + badParts + badCoordinates + badProperties > 0
                            ? " (types \(badTypes), parts \(badParts), coords \(badCoordinates), props \(badProperties))" : ""))
    }

    // MARK: Places and flights

    static func checkPlaces(_ url: URL, report: Report) throws {
        let data = try Data(contentsOf: url)
        let places = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        let keys: Set<String> = ["name", "country", "lat", "lon", "pop", "rank", "capital"]
        let pops = places.compactMap { $0["pop"] as? Int }
        let sorted = zip(pops, pops.dropFirst()).allSatisfy { $0 >= $1 }
        let capitals = places.filter { $0["capital"] as? Bool == true }.count
        print("   places.json: \(formatBytes(data.count)), \(places.count) places, \(capitals) capitals, first: "
            + places.prefix(3).map { "\($0["name"] ?? "?")" }.joined(separator: ", "))
        report.check(places.count > 1000 && places.allSatisfy { Set($0.keys) == keys } && pops.count == places.count && sorted,
                     "places.json: keys and descending population order")
    }

    static func checkFlights(_ url: URL, report: Report) throws {
        let data = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let airports = root["airports"] as? [[Any]] ?? []
        let routes = root["routes"] as? [[Int]] ?? []
        let counts = airports.compactMap { $0.count == 7 ? $0[6] as? Int : nil }
        let indexOK = routes.allSatisfy { $0.count == 3 && $0[0] >= 0 && $0[0] < $0[1] && $0[1] < airports.count && $0[2] > 0 }
        var degree = [Int](repeating: 0, count: airports.count)
        for r in routes where indexOK { degree[r[0]] += r[2]; degree[r[1]] += r[2] }
        print("   flights.json: \(formatBytes(data.count)), \(airports.count) airports, \(routes.count) routes; top: "
            + airports.prefix(3).map { "\($0[2]) (\($0[6]))" }.joined(separator: ", "))
        report.check(counts.count == airports.count && indexOK && degree == counts
                        && zip(counts, counts.dropFirst()).allSatisfy { $0 >= $1 } && degree.allSatisfy { $0 > 0 },
                     "flights.json: indices a < b, route counts match airport totals, sorted by count")
    }

    // MARK: Grids

    /// Bilinear (or nearest) lookup with longitude wrap-around on global grids.
    static func sample(_ grid: GridFile, _ layer: String, lat: Double, lon: Double, nearest: Bool = false) throws -> Double {
        let h = grid.header
        let values = try grid.layer(named: layer)
        let fx = (lon - h.lon0) / h.dlon, fy = (lat - h.lat0) / h.dlat
        let global = abs(Double(h.width) * h.dlon - 360) < 1e-6
        func x(_ i: Int) -> Int { global ? ((i % h.width) + h.width) % h.width : min(max(i, 0), h.width - 1) }
        func y(_ j: Int) -> Int { min(max(j, 0), h.height - 1) }
        func v(_ i: Int, _ j: Int) -> Double { Double(values[y(j) * h.width + x(i)]) }
        if nearest { return v(Int(fx.rounded()), Int(fy.rounded())) }
        let (i0, j0) = (Int(fx.rounded(.down)), Int(fy.rounded(.down)))
        let (tx, ty) = (fx - Double(i0), fy - Double(j0))
        return (1 - ty) * ((1 - tx) * v(i0, j0) + tx * v(i0 + 1, j0)) + ty * ((1 - tx) * v(i0, j0 + 1) + tx * v(i0 + 1, j0 + 1))
    }

    static func describe(_ url: URL, _ grid: GridFile) -> String {
        let h = grid.header
        let finite = grid.layers.joined().filter { !$0.isNaN }
        return "\(url.lastPathComponent): \(formatBytes((try? Data(contentsOf: url).count) ?? 0)), \(h.width)×\(h.height)×\(h.layers.count) \(h.type), "
            + String(format: "lon0 %.4f lat0 %.4f d %.4f/%.4f, values %.2f…%.2f %@", h.lon0, h.lat0, h.dlon, h.dlat,
                     finite.min() ?? .nan, finite.max() ?? .nan, h.units)
    }

    static func checkGrids(_ ws: Workspace, report: Report) throws {
        let precipURL = ws.output("precipitation.grid")
        let precip = try GridFile(contentsOf: precipURL)
        print("   " + describe(precipURL, precip))
        report.check(precip.header.layers == ClimateGrids.months + ["annual"] && precip.header.dlat > 0,
                     "precipitation.grid: layers 01…12 + annual, south → north")
        let amazon = try sample(precip, "annual", lat: 0, lon: -60)
        let sahara = try sample(precip, "annual", lat: 23, lon: 10)
        report.check(amazon > sahara, String(format: "annual precipitation Amazon (0°, 60°W) %.2f > Sahara (23°N, 10°E) %.2f mm/day", amazon, sahara))

        let windURL = ws.output("wind.grid")
        let wind = try GridFile(contentsOf: windURL)
        print("   " + describe(windURL, wind))
        report.check(wind.header.layers.count == 26 && wind.header.dlat > 0, "wind.grid: 26 layers, south → north")
        let trades = try sample(wind, "u", lat: 15, lon: -140)
        let westerlies = try sample(wind, "u", lat: -45, lon: 90)
        report.check(trades < 0, String(format: "annual u at 15°N 140°W (trade easterlies) %.2f m/s < 0", trades))
        report.check(westerlies > 0, String(format: "annual u at 45°S 90°E (westerlies) %.2f m/s > 0", westerlies))

        let elevationURL = ws.output("elevation.grid")
        let elevation = try GridFile(contentsOf: elevationURL)
        print("   " + describe(elevationURL, elevation))
        let everest = try sample(elevation, "elevation", lat: 27.99, lon: 86.93, nearest: true)
        let mariana = try sample(elevation, "elevation", lat: 11.35, lon: 142.2, nearest: true)
        let amsterdam = try sample(elevation, "elevation", lat: 52.37, lon: 4.9, nearest: true)
        report.check(everest > 6000, "elevation near Everest (27.99°N 86.93°E) \(Int(everest)) m > 6000")
        report.check(mariana < -6000, "elevation in the Mariana Trench (11.35°N 142.2°E) \(Int(mariana)) m < −6000"
            + (mariana < -8000 ? " (and < −8000)" : ""))
        report.check((-10...20).contains(amsterdam), "elevation at Amsterdam (52.37°N 4.9°E) \(Int(amsterdam)) m in −10…20")
    }
}
