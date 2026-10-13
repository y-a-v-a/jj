import Foundation
import MyriaData

/// Arrays from an OPeNDAP ASCII response (`.ascii?var[...]`), keyed by both
/// their full name ("precip.lat") and their short name ("lat", first wins).
struct OPeNDAPASCII {
    var arrays: [String: (shape: [Int], values: [Double])] = [:]

    init(_ text: String) throws {
        guard let separator = text.range(of: "\n-------") else { throw PrepError("not an OPeNDAP ASCII response") }
        var name: String?
        var shape: [Int] = []
        var values: [Double] = []
        func flush() {
            guard let n = name else { return }
            arrays[n] = (shape, values)
            if let short = n.split(separator: ".").last.map(String.init), arrays[short] == nil { arrays[short] = (shape, values) }
            name = nil
        }
        for line in text[separator.upperBound...].split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); continue }
            if name == nil {
                // Header such as "precip.precip[12][72][144]".
                guard let open = trimmed.firstIndex(of: "[") else { continue }
                name = String(trimmed[..<open])
                shape = trimmed[open...].split(whereSeparator: { $0 == "[" || $0 == "]" }).compactMap { Int($0) }
                values = []
                values.reserveCapacity(shape.reduce(1, *))
                continue
            }
            var body = Substring(trimmed)
            if body.hasPrefix("["), let comma = body.firstIndex(of: ",") { body = body[body.index(after: comma)...] }
            for token in body.split(separator: ",") {
                guard let v = Double(token.trimmingCharacters(in: .whitespaces)) else {
                    throw PrepError("bad value \(token) in \(name ?? "?")")
                }
                values.append(v)
            }
        }
        flush()
    }

    func array(_ name: String, count: Int? = nil) throws -> [Double] {
        guard let a = arrays[name] else { throw PrepError("OPeNDAP response has no array \(name)") }
        if let count, a.values.count != count { throw PrepError("\(name): expected \(count) values, got \(a.values.count)") }
        return a.values
    }
}

/// Packing attributes of one variable from an OPeNDAP `.das` response.
struct Packing {
    var scale = 1.0, offset = 0.0
    var missing: [Double] = []
    var validRange: ClosedRange<Double>?

    init(das: String, variable: String) {
        guard let start = das.range(of: "\n    \(variable) {") else { return }
        let block = das[start.upperBound...].prefix { $0 != "}" }
        for line in block.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ";", with: "")
                .split(separator: " ").map(String.init)
            guard parts.count >= 3 else { continue }
            let numbers = parts[2...].compactMap { Double($0.replacingOccurrences(of: ",", with: "")) }
            guard let first = numbers.first else { continue }
            switch parts[1] {
            case "scale_factor": scale = first
            case "add_offset": offset = first
            case "missing_value", "_FillValue": missing.append(first)
            case "valid_range" where numbers.count == 2: validRange = numbers[0]...numbers[1]
            default: break
            }
        }
    }

    /// Unpacks a raw value; missing or out-of-range values become NaN.
    func unpack(_ raw: Double) -> Float {
        if missing.contains(where: { abs(raw - $0) <= abs($0) * 1e-6 }) || abs(raw) > 1e30 { return .nan }
        let v = raw * scale + offset
        if let validRange, !validRange.contains(v) { return .nan }
        return Float(v)
    }

    var summary: String {
        "scale \(scale), offset \(offset), missing \(missing.map { String($0) }.joined(separator: "/"))"
            + (validRange.map { ", valid \($0.lowerBound)…\($0.upperBound)" } ?? "")
    }
}

/// Monthly climatologies from NOAA PSL's THREDDS OPeNDAP server.
enum ClimateGrids {
    static let thredds = "https://psl.noaa.gov/thredds/dodsC/Datasets/"

    /// A (time, lat, lon) field on a regular global grid, re-ordered so rows
    /// run south → north and columns start at the first longitude ≥ −180.
    struct Field {
        var layers: [[Float]]
        var width: Int, height: Int
        var lon0: Double, lat0: Double, dlon: Double, dlat: Double
    }

    static func loadField(_ ws: Workspace, path: String, variable: String, times: Int, rawName: String) throws -> Field {
        let dasURL = try ws.raw("\(rawName).das", from: thredds + path + ".das")
        let packing = Packing(das: try String(contentsOf: dasURL, encoding: .utf8), variable: variable)
        print("   \(variable): \(packing.summary)")
        let asciiURL = try ws.raw("\(rawName).ascii", from: thredds + path + ".ascii?\(variable)")
        let response = try OPeNDAPASCII(String(contentsOf: asciiURL, encoding: .utf8))
        guard let shape = response.arrays[variable]?.shape, shape.count == 3, shape[0] == times else {
            throw PrepError("\(variable): unexpected shape \(response.arrays[variable]?.shape ?? [])")
        }
        let (height, width) = (shape[1], shape[2])
        let data = try response.array(variable, count: times * height * width)
        let lats = try response.array("lat", count: height), lons = try response.array("lon", count: width)

        let dlatRaw = (lats[height - 1] - lats[0]) / Double(height - 1)
        let dlon = (lons[width - 1] - lons[0]) / Double(width - 1)
        guard abs(abs(dlon) * Double(width) - 360) < 1e-3 else { throw PrepError("\(variable): grid is not global in longitude") }
        for (i, lat) in lats.enumerated() where abs(lat - (lats[0] + Double(i) * dlatRaw)) > 1e-3 {
            throw PrepError("\(variable): latitudes are not regular")
        }
        let flip = dlatRaw < 0
        // Rotate columns so that longitudes, normalised to [−180, 180), ascend
        // from the westernmost one (0…360 grids start at their 180° column).
        guard dlon > 0 else { throw PrepError("\(variable): longitudes must ascend") }
        let normalised = lons.map { $0 - 360 * (($0 + 180) / 360).rounded(.down) }
        let shift = normalised.indices.min { normalised[$0] < normalised[$1] }!
        let lonStart = normalised[shift]
        var layers: [[Float]] = []
        for t in 0..<times {
            var layer = [Float](repeating: .nan, count: width * height)
            for j in 0..<height {
                let srcRow = flip ? height - 1 - j : j
                for i in 0..<width {
                    let srcCol = (i + shift) % width
                    layer[j * width + i] = packing.unpack(data[(t * height + srcRow) * width + srcCol])
                }
            }
            layers.append(layer)
        }
        return Field(layers: layers, width: width, height: height, lon0: lonStart,
                     lat0: flip ? lats[height - 1] : lats[0], dlon: dlon, dlat: abs(dlatRaw))
    }

    static func mean(_ layers: [[Float]]) -> [Float] {
        (0..<layers[0].count).map { k in
            let values = layers.map { $0[k] }
            return values.contains(where: \.isNaN) ? .nan : values.reduce(0, +) / Float(values.count)
        }
    }

    static func range(_ values: [Float]) -> String {
        let finite = values.filter { !$0.isNaN }
        let nan = values.count - finite.count
        return String(format: "%.2f…%.2f", finite.min() ?? .nan, finite.max() ?? .nan) + (nan > 0 ? " (\(nan) NaN)" : "")
    }

    static func write(_ ws: Workspace, _ field: Field, names: [String], layers: [[Float]], units: String, source: String, to file: String) throws {
        let header = GridFile.Header(
            width: field.width, height: field.height, layers: names, type: .float32,
            lon0: field.lon0, lat0: field.lat0, dlon: field.dlon, dlat: field.dlat,
            units: units, source: source, compression: "lzfse")
        let grid = GridFile(header: header, layers: layers)
        print("   \(field.width)×\(field.height), \(names.count) layers, lon0 \(field.lon0), lat0 \(field.lat0), dlon \(field.dlon), dlat \(field.dlat)")
        try ws.write(grid.encoded(), to: file)
    }

    static let months = (1...12).map { String(format: "%02d", $0) }

    static func precipitation(_ ws: Workspace) throws {
        let field = try loadField(ws, path: "gpcp/precip.mon.ltm.1991-2020.nc", variable: "precip",
                                  times: 12, rawName: "gpcp_precip.mon.ltm.1991-2020")
        let annual = mean(field.layers)
        print("   monthly range \(range(Array(field.layers.joined()))) mm/day; annual \(range(annual))")
        try write(ws, field, names: months + ["annual"], layers: field.layers + [annual], units: "mm/day",
                  source: "GPCP v2.3 monthly precipitation, long-term mean 1991–2020 (Adler et al. 2018, "
                      + "Atmosphere 9(4), 138, doi:10.3390/atmos9040138). Data provided by NOAA PSL, Boulder, Colorado, USA, "
                      + "https://psl.noaa.gov. Layers 01–12 are calendar months; annual is their mean.",
                  to: "precipitation.grid")
    }

    static func wind(_ ws: Workspace) throws {
        let base = "ncep.reanalysis.derived/surface/"
        let u = try loadField(ws, path: base + "uwnd.sig995.mon.ltm.1991-2020.nc", variable: "uwnd",
                              times: 12, rawName: "ncep_uwnd.sig995.mon.ltm.1991-2020")
        let v = try loadField(ws, path: base + "vwnd.sig995.mon.ltm.1991-2020.nc", variable: "vwnd",
                              times: 12, rawName: "ncep_vwnd.sig995.mon.ltm.1991-2020")
        guard (u.width, u.height, u.lon0, u.lat0) == (v.width, v.height, v.lon0, v.lat0) else {
            throw PrepError("u and v wind grids differ")
        }
        let (uMean, vMean) = (mean(u.layers), mean(v.layers))
        print("   u \(range(Array(u.layers.joined()))) m/s, v \(range(Array(v.layers.joined()))) m/s; "
            + "annual u \(range(uMean)), v \(range(vMean))")
        try write(ws, u, names: months.map { "u" + $0 } + months.map { "v" + $0 } + ["u", "v"],
                  layers: u.layers + v.layers + [uMean, vMean], units: "m/s",
                  source: "NCEP/NCAR Reanalysis 1 near-surface (sigma 0.995) wind, monthly long-term mean 1991–2020 "
                      + "(Kalnay et al. 1996, Bull. Amer. Meteor. Soc. 77, 437–471). Data provided by NOAA PSL, "
                      + "Boulder, Colorado, USA, https://psl.noaa.gov. u: eastward, v: northward; u/v are annual means.",
                  to: "wind.grid")
    }
}
