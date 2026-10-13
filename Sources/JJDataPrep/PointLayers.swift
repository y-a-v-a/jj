import Foundation
import MyriaCore

/// Point datasets: populated places and the OpenFlights network.
enum PointLayers {
    // MARK: Places

    static func places(_ ws: Workspace) throws {
        let name = "ne_10m_populated_places_simple"
        let url = try ws.raw("\(name).geojson", from: VectorLayers.naturalEarth + "\(name).geojson")
        struct Place { let name, country: String; let lat, lon: Double; let pop, rank: Int; let capital: Bool }
        var places: [Place] = []
        for f in try GeoJSON.readFeatures(url) {
            guard case .point(let p) = f.geometry else { continue }
            let props = f.properties
            places.append(Place(
                name: props.string("name"), country: props.string("adm0name"), lat: p.y, lon: p.x,
                pop: Int(props.number("pop_max") ?? 0), rank: Int(props.number("scalerank") ?? 0),
                capital: props.string("featurecla").contains("Admin-0 capital")))
        }
        places.sort { ($0.pop, $1.name) > ($1.pop, $0.name) }
        let rows = places.map { p in
            jsonObject([
                ("name", .string(p.name)), ("country", .string(p.country)),
                ("lat", .number(p.lat, decimals: 4)), ("lon", .number(p.lon, decimals: 4)),
                ("pop", .int(p.pop)), ("rank", .int(p.rank)), ("capital", .bool(p.capital)),
            ])
        }
        let capitals = places.filter(\.capital).count
        print("   \(places.count) places, \(capitals) capitals; largest: "
            + places.prefix(3).map { "\($0.name) \($0.pop)" }.joined(separator: ", "))
        try ws.write(Data(("[" + rows.joined(separator: ",") + "]").utf8), to: "places.json")
    }

    // MARK: Flights

    /// Parses RFC 4180-style CSV ("" escapes a quote; \N is OpenFlights' null).
    static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        while let c = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let n = iterator.next() {
                        if n == "\"" { field.unicodeScalars.append("\"") } else { quoted = false; pending = n }
                    } else { quoted = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": row.append(field); field = ""
                case "\n", "\r":
                    if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
                    row = []; field = ""
                default: field.unicodeScalars.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func flights(_ ws: Workspace) throws {
        let base = "https://raw.githubusercontent.com/jpatokal/openflights/master/data/"
        let airportRows = try csvRows(String(contentsOf: ws.raw("airports.dat", from: base + "airports.dat"), encoding: .utf8))
        let routeRows = try csvRows(String(contentsOf: ws.raw("routes.dat", from: base + "routes.dat"), encoding: .utf8))

        struct Airport { let lat, lon: Double; let code, name, city, country: String }
        func value(_ s: String) -> String? { s == "\\N" || s.isEmpty ? nil : s }
        var airports: [Int: Airport] = [:]
        var byCode: [String: Int] = [:]
        for r in airportRows where r.count >= 8 {
            guard let id = Int(r[0]), let lat = Double(r[6]), let lon = Double(r[7]) else { continue }
            let iata = value(r[4]), icao = value(r[5])
            airports[id] = Airport(lat: lat, lon: lon, code: iata ?? icao ?? "", name: r[1], city: r[2], country: r[3])
            if let iata { byCode[iata] = id }
            if let icao { byCode[icao] = id }
        }

        struct Pair: Hashable { let a, b: Int }
        var pairs: [Pair: Int] = [:]
        var unresolved = 0, loops = 0
        for r in routeRows where r.count >= 6 {
            func resolve(_ code: String, _ id: String) -> Int? {
                if let id = Int(id), airports[id] != nil { return id }
                return byCode[code]
            }
            guard let s = resolve(r[2], r[3]), let d = resolve(r[4], r[5]) else { unresolved += 1; continue }
            guard s != d else { loops += 1; continue }
            pairs[Pair(a: min(s, d), b: max(s, d)), default: 0] += 1
        }

        var routeCount: [Int: Int] = [:]
        for (p, n) in pairs {
            routeCount[p.a, default: 0] += n
            routeCount[p.b, default: 0] += n
        }
        let ids = routeCount.keys.sorted {
            let (a, b) = (routeCount[$0]!, routeCount[$1]!)
            return a != b ? a > b : (airports[$0]!.code, $0) < (airports[$1]!.code, $1)
        }
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let airportJSON = ids.map { id -> String in
            let a = airports[id]!
            return "[\(formatNumber(a.lat, decimals: 4)),\(formatNumber(a.lon, decimals: 4)),\(jsonString(a.code)),"
                + "\(jsonString(a.name)),\(jsonString(a.city)),\(jsonString(a.country)),\(routeCount[id]!)]"
        }
        let routes = pairs.map { (p, n) -> (Int, Int, Int) in
            let (i, j) = (index[p.a]!, index[p.b]!)
            return (min(i, j), max(i, j), n)
        }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        let routeJSON = routes.map { "[\($0.0),\($0.1),\($0.2)]" }

        let total = pairs.values.reduce(0, +)
        print("   \(airportRows.count) airports, \(routeRows.count) airline routes (\(unresolved) unresolved, \(loops) self-loops)")
        print("   → \(ids.count) connected airports, \(routes.count) airport pairs carrying \(total) routes; busiest: "
            + ids.prefix(3).map { "\(airports[$0]!.code) \(routeCount[$0]!)" }.joined(separator: ", "))
        let json = "{\"airports\":[" + airportJSON.joined(separator: ",") + "],\"routes\":[" + routeJSON.joined(separator: ",") + "]}"
        try ws.write(Data(json.utf8), to: "flights.json")
    }
}
