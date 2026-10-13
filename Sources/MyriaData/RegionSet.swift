import Foundation
import MyriaCore

/// Named regions that partition (part of) a body's surface: countries,
/// tectonic plates, timezones. Each region may consist of many polygons.
public struct RegionSet: Sendable {
    public struct Region: Sendable, Identifiable, Hashable {
        public let id: Int
        public let name: String
        /// A short code (ISO country code, plate code, IANA zone).
        public let code: String
        /// Where a label for the region belongs, when the data says so.
        public let labelPoint: GeoPoint?
        public let properties: [String: String]
    }

    public let regions: [Region]
    public let polygons: PolygonLayer
    /// Borders between different regions, each drawn once.
    public let borders: SegmentLayer

    public init(features: [GeoFeature], nameKey: String = "name", codeKey: String = "code",
                labelKeys: (lon: String, lat: String)? = nil, tileSize: Double = 5) {
        regions = features.enumerated().map { i, f in
            let label: GeoPoint? = labelKeys.flatMap { keys in
                guard let lon = f.double(keys.lon), let lat = f.double(keys.lat) else { return nil }
                return GeoPoint(latitude: lat, longitude: lon)
            }
            return Region(id: i, name: f.string(nameKey) ?? "", code: f.string(codeKey) ?? "",
                          labelPoint: label, properties: f.properties)
        }
        polygons = PolygonLayer(features: features.map(\.polygons), tileSize: tileSize)
        borders = SegmentLayer(polylines: Self.borderPolylines(features), tileSize: tileSize)
    }

    public var count: Int { regions.count }

    public func region(at p: GeoPoint) -> Region? {
        polygons.feature(at: p).map { regions[$0] }
    }

    public func region(code: String) -> Region? {
        regions.first { $0.code == code }
    }

    /// Border polylines: ring edges whose twin edge belongs to another region.
    /// Twins within one region (antimeridian splits) and pole-degenerate edges
    /// are dropped.
    static func borderPolylines(_ features: [GeoFeature]) -> [[Vec2]] {
        struct Key: Hashable {
            let a: Int64, b: Int64, c: Int64, d: Int64
            init(_ p: Vec2, _ q: Vec2) {
                func quantize(_ v: Vec2) -> (Int64, Int64) {
                    if abs(v.y) >= 89.99999 { return (Int64((v.y * 1e6).rounded()), 0) }
                    let lon = v.x >= 180 ? v.x - 360 : v.x
                    return (Int64((v.y * 1e6).rounded()), Int64((lon * 1e6).rounded()))
                }
                let (p0, p1) = quantize(p), (q0, q1) = quantize(q)
                if (p0, p1) <= (q0, q1) { (a, b, c, d) = (p0, p1, q0, q1) } else { (a, b, c, d) = (q0, q1, p0, p1) }
            }
        }
        var owners: [Key: [Int]] = [:]
        let rings: [(Int, [Vec2])] = features.enumerated().flatMap { i, f in
            f.polygons.flatMap { $0.rings.map { (i, GeoPolygon.planar($0)) } }
        }
        for (region, ring) in rings {
            for j in ring.indices {
                owners[Key(ring[j], ring[(j + 1) % ring.count]), default: []].append(region)
            }
        }
        var emitted = Set<Key>()
        var result: [[Vec2]] = []
        for (region, ring) in rings {
            result += SegmentLayer.polylines(fromRings: [ring]) { a, b in
                let key = Key(a, b)
                let regions = owners[key] ?? []
                let shared = regions.contains { $0 != region }
                if !shared { return false }
                return emitted.insert(key).inserted
            }
        }
        return result
    }
}

/// Land polygons and their coastlines.
public struct LandMask: Sendable {
    public let polygons: PolygonLayer
    public let coastlines: SegmentLayer
    /// The land rings in (longitude, latitude), outer rings counter-clockwise.
    public let rings: [[Vec2]]

    public init(features: [GeoFeature], tileSize: Double = 5) {
        let all = features.flatMap(\.polygons)
        polygons = PolygonLayer(features: [all], tileSize: tileSize)
        rings = all.flatMap { $0.rings.map(GeoPolygon.planar) }
        coastlines = SegmentLayer(
            polylines: SegmentLayer.polylines(fromRings: rings) { !SegmentLayer.isArtificial($0, $1) },
            tileSize: tileSize)
    }

    public func isLand(_ p: GeoPoint) -> Bool { polygons.feature(at: p) != nil }
}

/// Polylines with an integer attribute each: rivers (rank), plate
/// boundaries (kind), country borders.
public struct LineSet: Sendable {
    public struct Line: Sendable {
        public let name: String
        public let attribute: Int
        public let points: [GeoPoint]
    }

    public let lines: [Line]
    public let segments: SegmentLayer

    public init(lines: [Line], tileSize: Double = 5) {
        self.lines = lines
        let planar = lines.map { GeoPolygon.densifyLine(GeoPolygon.planar($0.points), maxStep: PolygonLayer.maxEdgeDegrees) }
        segments = SegmentLayer(polylines: planar, attributes: lines.map { Int32($0.attribute) }, tileSize: tileSize)
    }

    /// Lines from GeoJSON features, the attribute read by `attribute`.
    public init(features: [GeoFeature], nameKey: String = "name", attribute: (GeoFeature) -> Int = { _ in 0 }) {
        self.init(lines: features.flatMap { f in
            f.lines.filter { $0.count >= 2 }.map { Line(name: f.string(nameKey) ?? "", attribute: attribute(f), points: $0) }
        })
    }
}
