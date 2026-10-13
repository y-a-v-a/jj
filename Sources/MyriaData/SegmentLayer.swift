import Foundation
import MyriaCore

/// Great-circle segments (coastlines, borders, rivers, routes) bucketed by tile.
public struct SegmentLayer: Sendable {
    public struct Segment: Sendable {
        public let a: Vec3
        public let b: Vec3
    }

    public let grid: TileGrid
    /// Segments in polyline order, so consecutive indices usually chain.
    public let segments: [Segment]
    /// Per segment, the attribute of the polyline it came from (a rank, a
    /// kind or a feature index; 0 when none was given).
    public let attributes: [Int32]
    /// Segment indices per tile, ascending.
    public let tiles: [[Int32]]

    /// - Parameters:
    ///   - polylines: open polylines in (longitude, latitude).
    ///   - attributes: one value per polyline.
    public init(polylines: [[Vec2]], attributes: [Int32]? = nil, tileSize: Double = 5) {
        let grid = TileGrid(size: tileSize)
        var segments: [Segment] = []
        var segmentAttributes: [Int32] = []
        var tiles = Array(repeating: [Int32](), count: grid.count)
        for (l, line) in polylines.enumerated() where line.count >= 2 {
            let attribute = attributes?[l] ?? 0
            for i in 0..<(line.count - 1) {
                let p = line[i], q = line[i + 1]
                let index = Int32(segments.count)
                segments.append(Segment(a: GeoPoint(latitude: p.y, longitude: p.x).unitVector,
                                        b: GeoPoint(latitude: q.y, longitude: q.x).unitVector))
                segmentAttributes.append(attribute)
                let (y0, y1) = (min(p.y, q.y), max(p.y, q.y))
                // A segment crossing the antimeridian covers both ends of the row.
                let boxes = abs(p.x - q.x) > 180
                    ? [Rect2(minX: max(p.x, q.x), minY: y0, maxX: 180, maxY: y1),
                       Rect2(minX: -180, minY: y0, maxX: min(p.x, q.x), maxY: y1)]
                    : [Rect2(minX: min(p.x, q.x), minY: y0, maxX: max(p.x, q.x), maxY: y1)]
                for box in boxes {
                    for t in grid.tiles(overlapping: box) where tiles[t].last != index { tiles[t].append(index) }
                }
            }
        }
        self.grid = grid
        self.segments = segments
        self.attributes = segmentAttributes
        self.tiles = tiles
    }

    /// Indices of the segments in the given tiles, ascending and unique.
    public func segmentIndices(inTiles tileIDs: [Int]) -> [Int] {
        var set = Set<Int32>()
        for t in tileIDs { set.formUnion(tiles[t]) }
        return set.map(Int.init).sorted()
    }

    /// Splits closed rings into polylines, dropping edges for which `keep` is
    /// false, and densifies the result.
    public static func polylines(fromRings rings: [[Vec2]], keep: (Vec2, Vec2) -> Bool) -> [[Vec2]] {
        var out: [[Vec2]] = []
        for ring in rings where ring.count >= 2 {
            var current: [Vec2] = []
            for i in ring.indices {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                if keep(a, b) {
                    if current.isEmpty { current.append(a) }
                    current.append(b)
                } else if !current.isEmpty {
                    out.append(current)
                    current = []
                }
            }
            if !current.isEmpty { out.append(current) }
        }
        return out.map { GeoPolygon.densifyLine($0, maxStep: PolygonLayer.maxEdgeDegrees) }
    }

    /// Edges that are artefacts of how polygons were stored: splits along
    /// the antimeridian and degenerate edges at the poles.
    public static func isArtificial(_ a: Vec2, _ b: Vec2) -> Bool {
        (abs(a.x) == 180 && abs(b.x) == 180) || (abs(a.y) >= 89.9999 && abs(b.y) >= 89.9999)
    }
}
