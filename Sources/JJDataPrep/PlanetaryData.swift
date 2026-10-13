import Foundation
import MyriaData

/// The Moon, Mars and Venus: altimetry grids from the PDS Geosciences Node and USGS
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

    static let venus = Spec(
        body: "Venus",
        pdsDirectory: "https://asc-pds-services.s3.us-west-2.amazonaws.com/mosaic/",
        image: "Venus_Magellan_Topography_Global_4641m_v02.tif",
        source: "Magellan Global Topography 4641 m v2 (USGS Astrogeology Science Center, from the Magellan GTDR, "
            + "NASA PDS), averaged from 22.8 to 4 px/deg: height in metres above the 6051.0 km reference sphere. "
            + "Ford, P. G. and Pettengill, G. H. (1992), Venus topography and kilometer-scale slopes, "
            + "J. Geophys. Res. 97(E8), 13103–13114, doi:10.1029/92JE01085. Simple cylindrical, −180…180°E.",
        gazetteer: "VENUS")

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

    /// Venus: Magellan's global topography mosaic, an uncompressed simple
    /// cylindrical GeoTIFF of signed 16-bit metres, averaged down to the
    /// 4 px/deg of the Moon and Mars.
    static func venusElevation(_ ws: Workspace, _ spec: Spec) throws {
        let url = try ws.raw(spec.image, from: spec.pdsDirectory + spec.image)
        let tiff = try GeoTIFF16(contentsOf: url)
        let (W, H) = (tiff.width, tiff.height)
        // A whole-globe grid, top-left corner at 180°W 90°N.
        let radius = tiff.datumRadius
        let west = tiff.tieX / radius * 180 / .pi, north = tiff.tieY / radius * 180 / .pi
        let spanX = Double(W) * tiff.pixelX / radius * 180 / .pi, spanY = Double(H) * tiff.pixelY / radius * 180 / .pi
        guard abs(west + 180) < 1e-3, abs(north - 90) < 1e-3, abs(spanX - 360) < 1e-3, abs(spanY - 180) < 1e-3 else {
            throw PrepError("\(spec.image): expected a global grid, got \(west)°E, \(north)°N, \(spanX)° × \(spanY)°")
        }
        let resolution = 4, outW = 360 * resolution, outH = 180 * resolution
        var sum = [Double](repeating: 0, count: outW * outH), count = [Int](repeating: 0, count: outW * outH)
        let column = (0..<W).map { i in min(outW - 1, Int((Double(i) + 0.5) / Double(W) * Double(outW))) }
        var low = Int16.max, high = Int16.min
        for r in 0..<H {
            // Source rows run north → south; output rows south → north.
            let row = min(outH - 1, Int((1 - (Double(r) + 0.5) / Double(H)) * Double(outH)))
            tiff.row(r) { values in
                for i in 0..<W where values[i] != tiff.noData {
                    let k = row * outW + column[i]
                    sum[k] += Double(values[i])
                    count[k] += 1
                    low = min(low, values[i])
                    high = max(high, values[i])
                }
            }
        }
        var height = (0..<(outW * outH)).map { count[$0] > 0 ? sum[$0] / Double(count[$0]) : Double.nan }
        let missing = height.filter(\.isNaN).count
        fillGaps(&height, width: outW, height: outH)
        let layer = height.map { Float($0.rounded()) }
        let step = 1 / Double(resolution)
        let share = 100 * Double(missing) / Double(outW * outH)
        let header = GridFile.Header(
            width: outW, height: outH, layers: ["elevation"], type: .int16,
            lon0: -180 + step / 2, lat0: -90 + step / 2, dlon: step, dlat: step,
            scale: 1, offset: 0, missing: nil, units: "m",
            source: spec.source + String(format: " Gaps in Magellan's coverage (%.1f %% of cells, mostly near the poles) "
                + "are filled smoothly from their surroundings.", share),
            compression: "lzfse")
        print("   \(spec.image): \(W)×\(H) signed 16-bit, \(formatNumber(tiff.pixelX, decimals: 1)) m pixels on a "
            + "\(formatNumber(radius / 1000, decimals: 1)) km sphere → \(outW)×\(outH)")
        print("   elevation \(low)…\(high) m" + (missing > 0 ? String(format: ", %d cells (%.1f %%) without data, filled", missing, share) : ""))
        try ws.write(try GridFile(header: header, layers: [layer]).encoded(), to: "elevation.grid", body: spec.body)
    }

    /// Fills NaN cells of a global grid (longitude wraps) from their
    /// surroundings: layer by layer from the edges of each gap, then smoothed
    /// by Laplace iterations with the measured cells held fixed.
    static func fillGaps(_ grid: inout [Double], width: Int, height: Int) {
        let gaps = grid.indices.filter { grid[$0].isNaN }
        guard !gaps.isEmpty else { return }
        func neighbours(_ k: Int) -> [Int] {
            let (r, c) = (k / width, k % width)
            var n = [r * width + (c + 1) % width, r * width + (c + width - 1) % width]
            if r > 0 { n.append(k - width) }
            if r < height - 1 { n.append(k + width) }
            return n
        }
        // Onion peeling: each pass fills cells next to known ones.
        var open = Set(gaps)
        while !open.isEmpty {
            var filled: [(Int, Double)] = []
            for k in open {
                let known = neighbours(k).map { grid[$0] }.filter { !$0.isNaN }
                if !known.isEmpty { filled.append((k, known.reduce(0, +) / Double(known.count))) }
            }
            if filled.isEmpty { break }
            for (k, v) in filled {
                grid[k] = v
                open.remove(k)
            }
        }
        // Smooth the filled cells.
        for _ in 0..<200 {
            for k in gaps {
                let n = neighbours(k)
                grid[k] = n.reduce(0) { $0 + grid[$1] } / Double(n.count)
            }
        }
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

    static func checkOtherWorlds(_ ws: Workspace, report: Report) throws {
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

        // Venus
        let venus = try checkBodyElevation(ws, body: "Venus", report: report)
        let maxwell = try sample(venus, "elevation", lat: 65.2, lon: 3.3, nearest: true)
        let atalanta = try sample(venus, "elevation", lat: 46, lon: 165, nearest: true)
        report.check(maxwell > 8_000, "Maxwell Montes (65.2°N 3.3°E) \(Int(maxwell)) m > 8000")
        report.check(atalanta < 300, "Atalanta Planitia (46°N 165°E) \(Int(atalanta)) m < 300")
        let venusFeatures = try checkFeatures(ws, body: "Venus", report: report)
        let venusNames = Set(venusFeatures.compactMap { $0["name"] as? String })
        report.check(venusNames.contains("Maxwell Montes") && venusNames.contains("Aphrodite Terra"),
                     "Venus features include Maxwell Montes and Aphrodite Terra")
        checkBodyTotal(ws, body: "Venus", report: report)
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

// MARK: - GeoTIFF

/// Just enough of TIFF for an uncompressed, single-band, signed 16-bit
/// GeoTIFF in a simple cylindrical projection on a sphere.
struct GeoTIFF16 {
    let data: Data
    let littleEndian: Bool
    let width: Int, height: Int
    let rowOffsets: [Int]
    /// Metres per pixel, and the model coordinates of the top-left corner.
    let pixelX: Double, pixelY: Double, tieX: Double, tieY: Double
    /// The sphere's radius (GeoKey 2057, semi-major axis) in metres.
    let datumRadius: Double
    let noData: Int16

    init(contentsOf url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 8 else { throw PrepError("\(url.lastPathComponent): not a TIFF") }
        littleEndian = data[0] == 0x49
        let d = data, le = littleEndian
        func u16(_ o: Int) -> Int { Int(le ? UInt16(d[o]) | UInt16(d[o + 1]) << 8 : UInt16(d[o]) << 8 | UInt16(d[o + 1])) }
        func u32(_ o: Int) -> Int { le ? u16(o) | u16(o + 2) << 16 : u16(o) << 16 | u16(o + 2) }
        func f64(_ o: Int) -> Double {
            var bits: UInt64 = 0
            for k in 0..<8 { bits |= UInt64(d[o + k]) << (le ? 8 * k : 8 * (7 - k)) }
            return Double(bitPattern: bits)
        }
        guard u16(2) == 42 else { throw PrepError("\(url.lastPathComponent): not a classic TIFF") }
        let ifd = u32(4)
        var tags: [Int: (type: Int, count: Int, offset: Int)] = [:]
        for e in 0..<u16(ifd) {
            let o = ifd + 2 + 12 * e
            let type = u16(o + 2), count = u32(o + 4)
            let size = [1: 1, 2: 1, 3: 2, 4: 4, 12: 8][type, default: 1] * count
            tags[u16(o)] = (type, count, size <= 4 ? o + 8 : u32(o + 8))
        }
        func value(_ tag: Int, _ k: Int = 0) throws -> Int {
            guard let t = tags[tag] else { throw PrepError("\(url.lastPathComponent): no TIFF tag \(tag)") }
            return t.type == 3 ? u16(t.offset + 2 * k) : u32(t.offset + 4 * k)
        }
        func doubles(_ tag: Int) throws -> [Double] {
            guard let t = tags[tag], t.type == 12 else { throw PrepError("\(url.lastPathComponent): no TIFF tag \(tag)") }
            return (0..<t.count).map { f64(t.offset + 8 * $0) }
        }
        let w = try value(256), h = try value(257)
        (width, height) = (w, h)
        guard try value(258) == 16, try value(259) == 1, (try? value(277)) ?? 1 == 1, (try? value(339)) ?? 1 == 2 else {
            throw PrepError("\(url.lastPathComponent): expected one uncompressed band of signed 16-bit samples")
        }
        let rowsPerStrip = (try? value(278)) ?? h
        let strips = (h + rowsPerStrip - 1) / rowsPerStrip
        let stripOffsets = try (0..<strips).map { try value(273, $0) }
        rowOffsets = (0..<h).map { r in stripOffsets[r / rowsPerStrip] + (r % rowsPerStrip) * 2 * w }
        let scale = try doubles(33550), tie = try doubles(33922)
        (pixelX, pixelY, tieX, tieY) = (scale[0], scale[1], tie[3], tie[4])
        // GeoKeys: the directory (tag 34735) points semi-major axis 2057 at a double in tag 34736.
        guard let keys = tags[34735], let params = try? doubles(34736) else {
            throw PrepError("\(url.lastPathComponent): no GeoKeys")
        }
        var radius: Double?
        for k in 1...u16(keys.offset + 6) {
            let o = keys.offset + 8 * k
            if u16(o) == 2057, u16(o + 2) == 34736 { radius = params[u16(o + 6)] }
        }
        guard let radius else { throw PrepError("\(url.lastPathComponent): no semi-major axis") }
        datumRadius = radius
        if let t = tags[42113] {
            noData = Int16(String(decoding: d[t.offset..<(t.offset + t.count)], as: UTF8.self)
                .trimmingCharacters(in: .controlCharacters.union(.whitespaces))) ?? .min
        } else {
            noData = .min
        }
    }

    /// The samples of row `r` (north first).
    func row(_ r: Int, _ body: ([Int16]) -> Void) {
        let o = rowOffsets[r]
        let values: [Int16] = data.withUnsafeBytes { raw in
            (0..<width).map { i in
                let bits = raw.loadUnaligned(fromByteOffset: o + 2 * i, as: UInt16.self)
                return Int16(bitPattern: littleEndian ? UInt16(littleEndian: bits) : UInt16(bigEndian: bits))
            }
        }
        body(values)
    }
}
