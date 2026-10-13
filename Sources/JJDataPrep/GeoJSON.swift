import Foundation
import MyriaCore

// Points are `Vec2(longitude, latitude)` in degrees throughout this tool.

/// The geometry of a GeoJSON feature, with Multi* and single variants merged.
enum Geometry {
    case point(Vec2)
    /// LineString or MultiLineString.
    case lines([[Vec2]])
    /// Polygon or MultiPolygon: polygons → rings (outer ring first) → closed positions.
    case polygons([[[Vec2]]])
}

struct Feature {
    var properties: [String: Any]
    var geometry: Geometry?
}

enum GeoJSON {
    static func readFeatures(_ url: URL) throws -> [Feature] {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]]
        else { throw PrepError("\(url.lastPathComponent) is not a GeoJSON FeatureCollection") }
        return features.map { f in
            Feature(properties: f["properties"] as? [String: Any] ?? [:],
                    geometry: (f["geometry"] as? [String: Any]).flatMap(geometry))
        }
    }

    static func geometry(_ g: [String: Any]) -> Geometry? {
        guard let type = g["type"] as? String, let c = g["coordinates"] else { return nil }
        switch type {
        case "Point": return position(c).map(Geometry.point)
        case "LineString": return .lines([line(c)])
        case "MultiLineString": return .lines((c as? [Any] ?? []).map(line))
        case "Polygon": return .polygons([polygon(c)])
        case "MultiPolygon": return .polygons((c as? [Any] ?? []).map(polygon))
        default: return nil
        }
    }

    private static func position(_ any: Any) -> Vec2? {
        guard let a = any as? [Any], a.count >= 2,
              let x = (a[0] as? NSNumber)?.doubleValue, let y = (a[1] as? NSNumber)?.doubleValue
        else { return nil }
        return Vec2(x, y)
    }

    private static func line(_ any: Any) -> [Vec2] { (any as? [Any] ?? []).compactMap(position) }
    private static func polygon(_ any: Any) -> [[Vec2]] { (any as? [Any] ?? []).map(line) }
}

extension Dictionary where Key == String, Value == Any {
    /// The property as a string; "" when missing or null.
    func string(_ key: String) -> String {
        switch self[key] {
        case let s as String: s
        case let n as NSNumber: n.stringValue
        default: ""
        }
    }

    func number(_ key: String) -> Double? {
        switch self[key] {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }
}

// MARK: - Writing compact JSON

/// A JSON scalar for hand-written, key-ordered, compact output.
enum JSONValue {
    case string(String)
    case int(Int)
    case number(Double, decimals: Int)
    case bool(Bool)

    var json: String {
        switch self {
        case .string(let s): jsonString(s)
        case .int(let i): String(i)
        case .number(let v, let decimals): formatNumber(v, decimals: decimals)
        case .bool(let b): b ? "true" : "false"
        }
    }
}

func jsonString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
        default: out.unicodeScalars.append(scalar)
        }
    }
    return out + "\""
}

/// Shortest decimal text for `v` rounded to `decimals` places ("12.5", "-3", "0").
func formatNumber(_ v: Double, decimals: Int) -> String {
    guard v.isFinite else { return "null" }
    let p = pow(10, Double(decimals))
    let r = (v * p).rounded() / p
    if r == r.rounded(), abs(r) < 1e15 { return String(Int64(r)) }
    var s = String(format: "%.\(decimals)f", r)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return s == "-0" ? "0" : s
}

func jsonObject(_ pairs: [(String, JSONValue)]) -> String {
    "{" + pairs.map { "\(jsonString($0.0)):\($0.1.json)" }.joined(separator: ",") + "}"
}

/// Accumulates a compact GeoJSON FeatureCollection with coordinates already
/// rounded to `decimals` places.
struct FeatureCollectionWriter {
    let decimals: Int
    private var body: [String] = []
    private(set) var vertexCount = 0
    var featureCount: Int { body.count }

    init(decimals: Int = 3) { self.decimals = decimals }

    private func position(_ p: Vec2) -> String {
        "[\(formatNumber(p.x, decimals: decimals)),\(formatNumber(p.y, decimals: decimals))]"
    }

    private mutating func positions(_ ps: [Vec2]) -> String {
        vertexCount += ps.count
        return "[" + ps.map(position).joined(separator: ",") + "]"
    }

    private mutating func append(type: String, coordinates: String, properties: [(String, JSONValue)]) {
        body.append("{\"type\":\"Feature\",\"properties\":\(jsonObject(properties)),"
            + "\"geometry\":{\"type\":\"\(type)\",\"coordinates\":\(coordinates)}}")
    }

    /// Adds a LineString (one line) or MultiLineString feature; empty input is skipped.
    mutating func add(lines: [[Vec2]], properties: [(String, JSONValue)]) {
        guard !lines.isEmpty else { return }
        if lines.count == 1 {
            append(type: "LineString", coordinates: positions(lines[0]), properties: properties)
        } else {
            var parts: [String] = []
            for l in lines { parts.append(positions(l)) }
            append(type: "MultiLineString", coordinates: "[" + parts.joined(separator: ",") + "]", properties: properties)
        }
    }

    /// Adds a Polygon (one polygon) or MultiPolygon feature; empty input is skipped.
    mutating func add(polygons: [[[Vec2]]], properties: [(String, JSONValue)]) {
        guard !polygons.isEmpty else { return }
        var encoded: [String] = []
        for polygon in polygons {
            var rings: [String] = []
            for ring in polygon { rings.append(positions(ring)) }
            encoded.append("[" + rings.joined(separator: ",") + "]")
        }
        if encoded.count == 1 {
            append(type: "Polygon", coordinates: encoded[0], properties: properties)
        } else {
            append(type: "MultiPolygon", coordinates: "[" + encoded.joined(separator: ",") + "]", properties: properties)
        }
    }

    func data() -> Data {
        Data(("{\"type\":\"FeatureCollection\",\"features\":[" + body.joined(separator: ",") + "]}").utf8)
    }
}
