import Foundation
import MyriaData

/// The Moon and Mars: laser-altimetry grids from the PDS Geosciences Node
/// (LRO LOLA, MGS MOLA) and named features from the IAU/USGS Gazetteer of
/// Planetary Nomenclature, written into `Sources/MyriaData/Resources/<Body>/`.
enum PlanetaryData {
    struct Spec: Sendable {
        /// Resource folder name ("Moon", "Mars").
        let body: String
        /// PDS directory holding the image and its detached label.
        let pdsDirectory: String
        /// Image file name; the label has the same stem and a `.lbl` extension.
        let image: String
        /// What the heights are relative to, and the product; becomes the grid's `source`.
        let source: String
        /// Gazetteer target name in the download file names ("MOON", "MARS").
        let gazetteer: String

        var label: String { (image as NSString).deletingPathExtension + ".lbl" }
    }

    static let moon = Spec(
        body: "Moon",
        pdsDirectory: "https://pds-geosciences.wustl.edu/lro/lro-l-lola-3-rdr-v1/lrolol_1xxx/data/lola_gdr/cylindrical/img/",
        image: "ldem_4.img",
        source: "LRO LOLA Gridded Data Record LDEM_4 (LRO-L-LOLA-4-GDR-V1.0, product V3.0, 2017), 4 px/deg, pixel "
            + "registered: height in metres above the 1737.4 km lunar reference sphere (planetary radius − 1737.4 km, "
            + "not a selenoid), stored as the source's 0.5 m digital numbers. Smith, D. E. et al. (2010), Initial "
            + "observations from the Lunar Orbiter Laser Altimeter (LOLA), Geophys. Res. Lett. 37, L18204, "
            + "doi:10.1029/2010GL043751; LRO LOLA team, NASA PDS Geosciences Node. Mean Earth/polar axis frame; "
            + "columns shifted from 0…360°E to −180…180°E.",
        gazetteer: "MOON")

    static let mars = Spec(
        body: "Mars",
        pdsDirectory: "https://pds-geosciences.wustl.edu/mgs/mgs-m-mola-5-megdr-l3-v1/mgsl_300x/meg004/",
        image: "megt90n000cb.img",
        source: "MGS MOLA Mission Experiment Gridded Data Record MEGT90N000CB (MGS-M-MOLA-5-MEGDR-L3-V1.0, version 2.0), "
            + "4 px/deg median topography: height in metres above the areoid (GMM-3 equipotential surface, mean "
            + "equatorial radius 3396.0 km). Smith, D. E. et al. (2001), Mars Orbiter Laser Altimeter: Experiment "
            + "summary after the first year of global mapping of Mars, J. Geophys. Res. 106(E10), 23689–23722, "
            + "doi:10.1029/2000JE001364; MGS MOLA team, NASA PDS Geosciences Node. Planetocentric IAU 2000 "
            + "coordinates; columns shifted from 0…360°E to −180…180°E.",
        gazetteer: "MARS")

    static let gazetteerBase = "https://asc-planetarynames-data.s3.us-west-2.amazonaws.com/"
    /// At most this many features, the largest kept.
    static let featureLimit = 2500

    // MARK: Elevation

    /// Reads a PDS simple-cylindrical 16-bit image of the whole globe as the
    /// label describes it (byte order, scaling, extent) and writes it as a
    /// south → north, −180°-first `elevation.grid` in metres.
    static func elevation(_ ws: Workspace, _ spec: Spec) throws {
        let labelURL = try ws.raw(spec.label, from: spec.pdsDirectory + spec.label)
        let imageURL = try ws.raw(spec.image, from: spec.pdsDirectory + spec.image)
        let label = PDSLabel(String(decoding: try Data(contentsOf: labelURL), as: UTF8.self))

        func require<T>(_ value: T?, _ key: String) throws -> T {
            guard let value else { throw PrepError("\(spec.label): no \(key)") }
            return value
        }
        let lines = try require(label.int("LINES"), "LINES")
        let samples = try require(label.int("LINE_SAMPLES"), "LINE_SAMPLES")
        let sampleType = try require(label.string("SAMPLE_TYPE"), "SAMPLE_TYPE")
        let resolution = try require(label.number("MAP_RESOLUTION"), "MAP_RESOLUTION")
        let west = try require(label.number("WESTERNMOST_LONGITUDE"), "WESTERNMOST_LONGITUDE")
        let east = try require(label.number("EASTERNMOST_LONGITUDE"), "EASTERNMOST_LONGITUDE")
        let north = try require(label.number("MAXIMUM_LATITUDE"), "MAXIMUM_LATITUDE")
        let south = try require(label.number("MINIMUM_LATITUDE"), "MINIMUM_LATITUDE")
        let scale = label.number("SCALING_FACTOR") ?? 1
        let missing = label.number("MISSING_CONSTANT")

        let littleEndian: Bool
        switch sampleType {
        case "LSB_INTEGER", "PC_INTEGER", "VAX_INTEGER": littleEndian = true
        case "MSB_INTEGER", "SUN_INTEGER", "MAC_INTEGER", "INTEGER": littleEndian = false
        default: throw PrepError("\(spec.label): unsupported SAMPLE_TYPE \(sampleType)")
        }
        guard label.int("SAMPLE_BITS") == 16 else { throw PrepError("\(spec.label): expected 16-bit samples") }
        guard label.string("MAP_PROJECTION_TYPE") == "SIMPLE CYLINDRICAL",
              label.string("POSITIVE_LONGITUDE_DIRECTION") == "EAST"
        else { throw PrepError("\(spec.label): expected a simple cylindrical map with east-positive longitudes") }
        // Pixel registered over the whole globe: line 1 is centred half a
        // pixel below the north pole, sample 1 half a pixel east of `west`.
        guard north == 90, south == -90, east - west == 360,
              Double(samples) == 360 * resolution, Double(lines) == 180 * resolution
        else {
            throw PrepError("\(spec.label): expected a global grid, got \(samples)×\(lines) at \(resolution) px/deg, "
                + "lon \(west)…\(east), lat \(south)…\(north)")
        }
        if let recordBytes = label.int("RECORD_BYTES"), recordBytes != 2 * samples {
            throw PrepError("\(spec.label): RECORD_BYTES \(recordBytes) ≠ 2 × \(samples)")
        }
        let data = try Data(contentsOf: imageURL)
        guard data.count == lines * samples * 2 else {
            throw PrepError("\(spec.image): \(data.count) bytes, expected \(lines) × \(samples) × 2")
        }

        // Output column c is centred at −180 + (c + ½)/res, which is source
        // sample (c + shift) mod samples.
        let shift = ((Int(((-180 - west) * resolution).rounded()) % samples) + samples) % samples
        var layer = [Float](repeating: 0, count: lines * samples)
        var dnLow = Int16.max, dnHigh = Int16.min, missingCount = 0
        data.withUnsafeBytes { raw in
            for j in 0..<lines {
                let row = lines - 1 - j  // source rows run north → south
                for c in 0..<samples {
                    let bits = raw.loadUnaligned(fromByteOffset: 2 * (row * samples + (c + shift) % samples), as: UInt16.self)
                    let dn = Int16(bitPattern: littleEndian ? UInt16(littleEndian: bits) : UInt16(bigEndian: bits))
                    if let missing, Double(dn) == missing {
                        layer[j * samples + c] = .nan
                        missingCount += 1
                        continue
                    }
                    dnLow = min(dnLow, dn)
                    dnHigh = max(dnHigh, dn)
                    layer[j * samples + c] = Float(Double(dn) * scale)
                }
            }
        }

        let step = 1 / resolution
        let header = GridFile.Header(
            width: samples, height: lines, layers: ["elevation"], type: .int16,
            lon0: -180 + step / 2, lat0: -90 + step / 2, dlon: step, dlat: step,
            scale: scale, offset: 0, missing: missingCount > 0 ? -32768 : nil,
            units: "m", source: spec.source, compression: "lzfse")
        let encoded = try GridFile(header: header, layers: [layer]).encoded()
        print("   \(spec.label): \(sampleType), \(samples)×\(lines) at \(formatNumber(resolution, decimals: 3)) px/deg, "
            + "lon \(formatNumber(west, decimals: 1))…\(formatNumber(east, decimals: 1))°E, × \(formatNumber(scale, decimals: 3)) m"
            + " → shifted \(shift) columns, flipped to south → north")
        print("   elevation \(formatNumber(Double(dnLow) * scale, decimals: 1))…\(formatNumber(Double(dnHigh) * scale, decimals: 1)) m"
            + (missingCount > 0 ? ", \(missingCount) missing" : ""))
        try ws.write(encoded, to: "elevation.grid", body: spec.body)
    }

    // MARK: Named features

    /// The gazetteer's centre points (shapefile attribute table): name, type,
    /// planetocentric latitude, 0…360°E longitude and diameter in km.
    static func features(_ ws: Workspace, _ spec: Spec) throws {
        let stem = "\(spec.gazetteer)_nomenclature_center_pts"
        let archive = try ws.raw(stem + ".zip", from: gazetteerBase + stem + ".zip")
        let table = try DBFTable(contentsOf: try ws.extract(stem + ".dbf", from: archive))
        let name = try table.column("name"), type = try table.column("type"), lat = try table.column("center_lat"),
            lon = try table.column("center_lon"), diameter = try table.column("diameter")
        let approval = table.fields.firstIndex(of: "approval")

        struct Feature { let name, type: String; let lat, lon, diameter: Double }
        var features: [Feature] = []
        var noDiameter = 0, unapproved = 0, invalid = 0
        for row in table.rows {
            if let approval, !row[approval].isEmpty, !row[approval].hasPrefix("Adopted") { unapproved += 1; continue }
            guard !row[name].isEmpty, let la = Double(row[lat]), let lo = Double(row[lon]), abs(la) <= 90, lo.isFinite
            else { invalid += 1; continue }
            guard let d = Double(row[diameter]), d > 0 else { noDiameter += 1; continue }
            var east = lo.truncatingRemainder(dividingBy: 360)
            if east > 180 { east -= 360 } else if east <= -180 { east += 360 }
            // "Crater, craters" → "Crater"
            let kind = row[type].split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            features.append(Feature(name: row[name], type: kind, lat: la, lon: east, diameter: d))
        }
        features.sort { ($0.diameter, $1.name) > ($1.diameter, $0.name) }
        let kept = features.prefix(featureLimit)
        var types: [String: Int] = [:]
        for f in kept { types[f.type, default: 0] += 1 }

        print("   \(table.rows.count) gazetteer entries: \(noDiameter) without diameter, \(unapproved) not adopted, "
            + "\(invalid) invalid → kept \(kept.count) of \(features.count)"
            + (kept.count < features.count ? String(format: " (diameter ≥ %.1f km)", kept.last!.diameter) : ""))
        print("   largest: " + kept.prefix(3).map { "\($0.name) \(Int($0.diameter)) km" }.joined(separator: ", ")
            + "; types: " + types.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(6)
                .map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        let rows = kept.map { f in
            jsonObject([
                ("name", .string(f.name)), ("type", .string(f.type)),
                ("lat", .number(f.lat, decimals: 4)), ("lon", .number(f.lon, decimals: 4)),
                ("diameter", .number(f.diameter, decimals: 3)),
            ])
        }
        try ws.write(Data(("[" + rows.joined(separator: ",") + "]").utf8), to: "features.json", body: spec.body)
    }
}

// MARK: - Workspace

extension Workspace {
    func bodyDirectory(_ body: String) -> URL {
        root.appendingPathComponent("Sources/MyriaData/Resources/\(body)", isDirectory: true)
    }

    func output(_ name: String, body: String) -> URL { bodyDirectory(body).appendingPathComponent(name) }

    /// Writes a resource into `Resources/<body>/` and reports its size.
    @discardableResult
    func write(_ data: Data, to name: String, body: String) throws -> Int {
        try FileManager.default.createDirectory(at: bodyDirectory(body), withIntermediateDirectories: true)
        try data.write(to: output(name, body: body), options: .atomic)
        print("   wrote \(body)/\(name): \(formatBytes(data.count))")
        return data.count
    }

    /// The cached `data/raw/<member>`, extracted from the zip `archive` first if missing.
    func extract(_ member: String, from archive: URL) throws -> URL {
        let fm = FileManager.default
        let destination = rawDirectory.appendingPathComponent(member)
        if let size = (try? fm.attributesOfItem(atPath: destination.path))?[.size] as? Int, size > 0 {
            return destination
        }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-j", "-q", archive.path, member, "-d", rawDirectory.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0, fm.fileExists(atPath: destination.path) else {
            throw PrepError("could not extract \(member) from \(archive.lastPathComponent) (unzip exit \(unzip.terminationStatus))")
        }
        return destination
    }
}

// MARK: - PDS3 labels

/// The `KEY = value` statements of a PDS3 label, first occurrence of each key
/// (nested OBJECTs are flattened). Quoted strings and `{…}`/`(…)` sets may
/// span lines; `/* … */` comments are skipped; units like `<deg>` are kept in
/// the raw string and dropped by `number(_:)`.
struct PDSLabel {
    private(set) var values: [String: String] = [:]

    init(_ text: String) {
        let c = Array(text.unicodeScalars)
        var i = 0
        func isKey(_ s: Unicode.Scalar) -> Bool {
            ("A"..."Z").contains(s) || ("a"..."z").contains(s) || ("0"..."9").contains(s) || s == "_" || s == "^" || s == ":"
        }
        let closing: [Unicode.Scalar: Unicode.Scalar] = ["\"": "\"", "'": "'", "{": "}", "(": ")"]
        while i < c.count {
            if c[i] == "/", i + 1 < c.count, c[i + 1] == "*" {
                i += 2
                while i + 1 < c.count, !(c[i] == "*" && c[i + 1] == "/") { i += 1 }
                i += 2
                continue
            }
            guard isKey(c[i]) else { i += 1; continue }
            var key = ""
            while i < c.count, isKey(c[i]) { key.unicodeScalars.append(c[i]); i += 1 }
            while i < c.count, c[i] == " " || c[i] == "\t" { i += 1 }
            guard i < c.count, c[i] == "=" else { continue }
            i += 1
            while i < c.count, c[i] == " " || c[i] == "\t" || c[i] == "\r" || c[i] == "\n" { i += 1 }
            var value = ""
            if i < c.count, let close = closing[c[i]] {
                let open = c[i]
                i += 1
                while i < c.count, c[i] != close { value.unicodeScalars.append(c[i]); i += 1 }
                i += 1
                if open == "{" || open == "(" { value = String(open) + value + String(close) }
            } else {
                while i < c.count, c[i] != "\n", c[i] != "\r", !(c[i] == "/" && i + 1 < c.count && c[i + 1] == "*") {
                    value.unicodeScalars.append(c[i])
                    i += 1
                }
            }
            if values[key] == nil { values[key] = value.trimmingCharacters(in: .whitespaces) }
        }
    }

    func string(_ key: String) -> String? { values[key] }

    func number(_ key: String) -> Double? {
        guard var s = values[key] else { return nil }
        if let unit = s.firstIndex(of: "<") { s = String(s[..<unit]) }
        s = s.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix(".") { s += "0" }
        return Double(s)
    }

    func int(_ key: String) -> Int? { number(key).flatMap { $0 == $0.rounded() ? Int($0) : nil } }
}

// MARK: - dBASE tables

/// The attribute table (.dbf) of a shapefile: every field as trimmed text,
/// deleted records skipped. Assumes UTF-8 text (the gazetteer's `.cpg`).
struct DBFTable {
    let fields: [String]
    let rows: [[String]]

    init(contentsOf url: URL) throws {
        let d = [UInt8](try Data(contentsOf: url))
        guard d.count >= 32 else { throw PrepError("\(url.lastPathComponent): not a dBASE table") }
        func u16(_ at: Int) -> Int { Int(d[at]) | Int(d[at + 1]) << 8 }
        let count = u16(4) | u16(6) << 16, headerLength = u16(8), recordLength = u16(10)
        var specs: [(name: String, length: Int)] = []
        var at = 32
        while at + 32 <= min(headerLength, d.count), d[at] != 0x0D {
            let name = d[at..<(at + 11)].prefix { $0 != 0 }
            specs.append((String(decoding: name, as: UTF8.self), Int(d[at + 16])))
            at += 32
        }
        guard !specs.isEmpty, specs.reduce(1, { $0 + $1.length }) == recordLength,
              headerLength + count * recordLength <= d.count
        else { throw PrepError("\(url.lastPathComponent): inconsistent dBASE header") }
        let trim = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\0"))
        var rows: [[String]] = []
        rows.reserveCapacity(count)
        for r in 0..<count {
            var offset = headerLength + r * recordLength
            guard d[offset] != 0x2A else { continue }  // "*": deleted
            offset += 1
            rows.append(specs.map { spec in
                defer { offset += spec.length }
                return String(decoding: d[offset..<(offset + spec.length)], as: UTF8.self).trimmingCharacters(in: trim)
            })
        }
        fields = specs.map(\.name)
        self.rows = rows
    }

    func column(_ name: String) throws -> Int {
        guard let i = fields.firstIndex(of: name) else { throw PrepError("dBASE table has no field \(name) (fields: \(fields))") }
        return i
    }
}

// MARK: - Verification

extension Verification {
    static let bodySizeLimit = 4 * 1_048_576

    static func checkMoonAndMars(_ ws: Workspace, report: Report) throws {
        // The Moon
        let moon = try checkBodyElevation(ws, body: "Moon", report: report)
        let moonValues = try moon.layer(named: "elevation").filter { !$0.isNaN }
        let (low, high) = (Double(moonValues.min() ?? .nan), Double(moonValues.max() ?? .nan))
        report.check((-10_000 ... -8_000).contains(low) && (9_500...11_500).contains(high),
                     "Moon elevation range \(Int(low))…\(Int(high)) m ≈ −9 km…+11 km")
        // Tycho: 85 km across, 43.3°S 11.2°W. Compare the floor (within half
        // the radius) with the rim (a ring at the radius).
        let tycho = (lat: -43.3, lon: -11.2), tychoRadius = 42.6 / 1737.4 * 180 / .pi
        func ringMean(_ radius: Double) throws -> Double {
            let n = 16
            return try (0..<n).map { k -> Double in
                let a = Double(k) / Double(n) * 2 * .pi
                return try sample(moon, "elevation", lat: tycho.lat + radius * cos(a),
                                  lon: tycho.lon + radius * sin(a) / cos(tycho.lat * .pi / 180))
            }.reduce(0, +) / Double(n)
        }
        let floor = try (sample(moon, "elevation", lat: tycho.lat, lon: tycho.lon)
            + ringMean(0.25 * tychoRadius) + ringMean(0.5 * tychoRadius)) / 3
        let rim = try ringMean(tychoRadius)
        report.check(rim - floor > 1000, "Tycho (43.3°S 11.2°W): floor \(Int(floor)) m is \(Int(rim - floor)) m below its rim \(Int(rim)) m (> 1000)")
        let aitken = try sample(moon, "elevation", lat: -53, lon: -169)
        report.check(aitken < -3000, "South Pole–Aitken basin (53°S 169°W) \(Int(aitken)) m < −3000")
        let moonFeatures = try checkFeatures(ws, body: "Moon", report: report)
        let moonNames = Set(moonFeatures.compactMap { $0["name"] as? String })
        report.check(moonNames.contains("Tycho") && moonNames.contains("Mare Imbrium"), "Moon features include Tycho and Mare Imbrium")
        if let imbrium = moonFeatures.first(where: { $0["name"] as? String == "Mare Imbrium" }),
           let lat = imbrium["lat"] as? Double, let lon = imbrium["lon"] as? Double {
            let height = try sample(moon, "elevation", lat: lat, lon: lon)
            report.check(height < -1000, "elevation at the Mare Imbrium feature (\(formatNumber(lat, decimals: 1))°, "
                + "\(formatNumber(lon, decimals: 1))°) \(Int(height)) m < −1000 (grid and features agree)")
        }
        checkBodyTotal(ws, body: "Moon", report: report)

        // Mars
        let mars = try checkBodyElevation(ws, body: "Mars", report: report)
        let olympus = try sample(mars, "elevation", lat: 18.65, lon: -133.8, nearest: true)
        let hellas = try sample(mars, "elevation", lat: -42.4, lon: 70.5, nearest: true)
        let lowlands = try sample(mars, "elevation", lat: 60, lon: 0, nearest: true)
        report.check(olympus > 15_000, "Olympus Mons (18.65°N 133.8°W) \(Int(olympus)) m > 15000")
        report.check(hellas < -6_000, "Hellas Planitia (42.4°S 70.5°E) \(Int(hellas)) m < −6000")
        report.check(lowlands < 0, "northern lowlands (60°N 0°E) \(Int(lowlands)) m < 0")
        let marsFeatures = try checkFeatures(ws, body: "Mars", report: report)
        let mons = marsFeatures.first { $0["name"] as? String == "Olympus Mons" }
        let monsLat = mons?["lat"] as? Double ?? .nan, monsLon = mons?["lon"] as? Double ?? .nan
        report.check(abs(monsLat - 18.65) < 0.2 && abs(monsLon + 133.8) < 0.5,
                     "Mars features: Olympus Mons at \(formatNumber(monsLat, decimals: 2))°, \(formatNumber(monsLon, decimals: 2))° ≈ 18.6°N 134°W")
        if mons != nil {
            let height = try sample(mars, "elevation", lat: monsLat, lon: monsLon, nearest: true)
            report.check(height > 15_000, "elevation at the Olympus Mons feature \(Int(height)) m > 15000 (grid and features agree)")
        }
        checkBodyTotal(ws, body: "Mars", report: report)
    }

    static func checkBodyElevation(_ ws: Workspace, body: String, report: Report) throws -> GridFile {
        let url = ws.output("elevation.grid", body: body)
        let grid = try GridFile(contentsOf: url)
        let h = grid.header
        print("   \(body)/" + describe(url, grid))
        report.check(h.layers == ["elevation"] && h.type == .int16 && h.compression == "lzfse" && h.units == "m"
                        && h.width == 1440 && h.height == 720 && h.dlon == 0.25 && h.dlat == 0.25
                        && h.lon0 == -179.875 && h.lat0 == -89.875 && grid.layers[0].allSatisfy { !$0.isNaN },
                     "\(body)/elevation.grid: 1440×720 int16 metres, lon −179.875…, south → north, lzfse, no gaps")
        return grid
    }

    static func checkFeatures(_ ws: Workspace, body: String, report: Report) throws -> [[String: Any]] {
        let url = ws.output("features.json", body: body)
        let data = try Data(contentsOf: url)
        let features = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        let keys: Set<String> = ["name", "type", "lat", "lon", "diameter"]
        let diameters = features.compactMap { $0["diameter"] as? Double }
        let wellFormed = features.allSatisfy { f in
            guard Set(f.keys) == keys, let name = f["name"] as? String, let type = f["type"] as? String,
                  let lat = f["lat"] as? Double, let lon = f["lon"] as? Double, let d = f["diameter"] as? Double
            else { return false }
            return !name.isEmpty && !type.isEmpty && abs(lat) <= 90 && abs(lon) <= 180 && d > 0
        }
        print("   \(body)/features.json: \(formatBytes(data.count)), \(features.count) features, largest: "
            + features.prefix(3).map { "\($0["name"] ?? "?") (\($0["type"] ?? "?"))" }.joined(separator: ", "))
        report.check((500...PlanetaryData.featureLimit).contains(features.count) && wellFormed && diameters.count == features.count
                        && zip(diameters, diameters.dropFirst()).allSatisfy { $0 >= $1 },
                     "\(body)/features.json: keys \(keys.sorted()), lon −180…180, sorted by diameter, ≤ \(PlanetaryData.featureLimit)")
        return features
    }

    static func checkBodyTotal(_ ws: Workspace, body: String, report: Report) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: ws.bodyDirectory(body), includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var total = 0
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += size
            print("   " + "\(body)/\(url.lastPathComponent)".padding(toLength: 26, withPad: " ", startingAt: 0) + formatBytes(size))
        }
        report.check(total > 0 && total < bodySizeLimit, "Resources/\(body) total \(formatBytes(total)) under \(formatBytes(bodySizeLimit))")
    }
}
