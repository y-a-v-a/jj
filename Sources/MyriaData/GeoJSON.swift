import Foundation
import MyriaCore

/// A polygon in longitude/latitude: the outer ring followed by any holes.
/// Rings are open (the closing point is not repeated).
public struct GeoPolygon: Sendable {
    public var rings: [[GeoPoint]]

    public init(rings: [[GeoPoint]]) {
        self.rings = rings
    }

    public var outer: [GeoPoint] { rings.first ?? [] }
}

/// A GeoJSON feature reduced to its geometry and scalar properties
/// (numbers and booleans are kept in their string form).
public struct GeoFeature: Sendable {
    public var properties: [String: String]
    public var polygons: [GeoPolygon]
    public var lines: [[GeoPoint]]
    public var points: [GeoPoint]

    public init(properties: [String: String], polygons: [GeoPolygon] = [], lines: [[GeoPoint]] = [], points: [GeoPoint] = []) {
        self.properties = properties
        self.polygons = polygons
        self.lines = lines
        self.points = points
    }

    public func string(_ key: String) -> String? { properties[key] }
    public func double(_ key: String) -> Double? { properties[key].flatMap(Double.init) }
    public func int(_ key: String) -> Int? { properties[key].flatMap { Int($0) ?? Double($0).map { Int($0) } } }
}

public enum GeoJSONError: Error, CustomStringConvertible {
    case notAFeatureCollection
    case malformedGeometry(String)

    public var description: String {
        switch self {
        case .notAFeatureCollection: "expected a GeoJSON FeatureCollection"
        case .malformedGeometry(let detail): "malformed geometry: \(detail)"
        }
    }
}

/// Minimal GeoJSON reader for feature collections of polygons, lines and points.
public enum GeoJSON {
    public static func features(from data: Data) throws -> [GeoFeature] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "FeatureCollection",
              let features = root["features"] as? [[String: Any]]
        else { throw GeoJSONError.notAFeatureCollection }

        return try features.map { feature in
            var properties: [String: String] = [:]
            for (key, value) in feature["properties"] as? [String: Any] ?? [:] {
                switch value {
                case let s as String: properties[key] = s
                case let n as NSNumber: properties[key] = n.stringValue
                default: break
                }
            }
            var result = GeoFeature(properties: properties)
            if let geometry = feature["geometry"] as? [String: Any] {
                try collect(geometry, into: &result)
            }
            return result
        }
    }

    static func collect(_ geometry: [String: Any], into feature: inout GeoFeature) throws {
        let coords = geometry["coordinates"] as? [Any]
        switch geometry["type"] as? String {
        case "Polygon":
            guard let coords else { throw GeoJSONError.malformedGeometry("Polygon without coordinates") }
            feature.polygons.append(try polygon(coords))
        case "MultiPolygon":
            guard let coords else { throw GeoJSONError.malformedGeometry("MultiPolygon without coordinates") }
            for item in coords {
                guard let p = item as? [Any] else { throw GeoJSONError.malformedGeometry("MultiPolygon member") }
                feature.polygons.append(try polygon(p))
            }
        case "LineString":
            guard let coords else { throw GeoJSONError.malformedGeometry("LineString without coordinates") }
            feature.lines.append(try positions(coords))
        case "MultiLineString":
            guard let coords else { throw GeoJSONError.malformedGeometry("MultiLineString without coordinates") }
            for item in coords {
                guard let l = item as? [Any] else { throw GeoJSONError.malformedGeometry("MultiLineString member") }
                feature.lines.append(try positions(l))
            }
        case "Point":
            guard let coords else { throw GeoJSONError.malformedGeometry("Point without coordinates") }
            feature.points.append(try position(coords))
        case "MultiPoint":
            guard let coords else { throw GeoJSONError.malformedGeometry("MultiPoint without coordinates") }
            feature.points += try positions(coords)
        case "GeometryCollection":
            for member in geometry["geometries"] as? [[String: Any]] ?? [] {
                try collect(member, into: &feature)
            }
        default:
            break
        }
    }

    static func position(_ value: Any) throws -> GeoPoint {
        guard let position = value as? [Any], position.count >= 2,
              let lon = (position[0] as? NSNumber)?.doubleValue,
              let lat = (position[1] as? NSNumber)?.doubleValue
        else { throw GeoJSONError.malformedGeometry("position") }
        return GeoPoint(latitude: lat, longitude: lon)
    }

    static func positions(_ value: [Any]) throws -> [GeoPoint] {
        try value.map(position)
    }

    static func polygon(_ coords: [Any]) throws -> GeoPolygon {
        let rings: [[GeoPoint]] = try coords.map { ringValue in
            guard let ring = ringValue as? [Any] else { throw GeoJSONError.malformedGeometry("ring") }
            var points = try positions(ring)
            if points.count > 1, points.first == points.last { points.removeLast() }
            return GeoPolygon.expandingPoles(points)
        }
        return GeoPolygon(rings: rings.filter { $0.count >= 3 })
    }
}

extension GeoPolygon {
    /// On the sphere a pole is a single point, so spherical simplifiers may
    /// drop the second corner of an edge running along latitude ±90°. In the
    /// planar longitude/latitude view that edge matters: each pole vertex is
    /// replaced by points at its neighbours' longitudes so the ring runs
    /// along the pole line instead of cutting diagonally across.
    static func expandingPoles(_ ring: [GeoPoint]) -> [GeoPoint] {
        func isPole(_ p: GeoPoint) -> Bool { abs(p.latitude) >= 90 - 1e-9 }
        guard ring.count >= 3, ring.contains(where: isPole) else { return ring }
        var out: [GeoPoint] = []
        for i in ring.indices {
            let p = ring[i]
            guard isPole(p) else {
                out.append(p)
                continue
            }
            let prev = ring[(i + ring.count - 1) % ring.count], next = ring[(i + 1) % ring.count]
            if !isPole(prev) { out.append(GeoPoint(latitude: p.latitude, longitude: prev.longitude)) }
            if !isPole(next) { out.append(GeoPoint(latitude: p.latitude, longitude: next.longitude)) }
        }
        return out
    }

    /// Planar (longitude, latitude) coordinates of a ring.
    public static func planar(_ ring: [GeoPoint]) -> [Vec2] { ring.map { Vec2($0.longitude, $0.latitude) } }

    /// Inserts points so no edge is longer than `maxStep` degrees in
    /// longitude/latitude. Short edges then follow great circles closely,
    /// and long meridian edges (pole to pole) stay well defined on the sphere.
    public static func densify(_ ring: [Vec2], maxStep: Double) -> [Vec2] {
        guard ring.count > 1 else { return ring }
        var out: [Vec2] = []
        out.reserveCapacity(ring.count)
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            out.append(a)
            let steps = Int((max(abs(b.x - a.x), abs(b.y - a.y)) / maxStep).rounded(.up))
            if steps > 1 {
                for k in 1..<steps { out.append(Vec2.lerp(a, b, Double(k) / Double(steps))) }
            }
        }
        return out
    }

    /// Densifies an open polyline (no closing edge).
    public static func densifyLine(_ line: [Vec2], maxStep: Double) -> [Vec2] {
        guard line.count > 1 else { return line }
        var out: [Vec2] = [line[0]]
        for i in 1..<line.count {
            let a = line[i - 1], b = line[i]
            let steps = max(1, Int((max(abs(b.x - a.x), abs(b.y - a.y)) / maxStep).rounded(.up)))
            for k in 1...steps { out.append(Vec2.lerp(a, b, Double(k) / Double(steps))) }
        }
        return out
    }
}
