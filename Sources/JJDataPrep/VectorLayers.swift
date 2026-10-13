import Foundation
import MyriaCore

/// Natural Earth vector layers: rivers, lakes, countries and land borders.
enum VectorLayers {
    static let naturalEarth = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/"

    static func naturalEarthFeatures(_ ws: Workspace, _ name: String) throws -> [Feature] {
        try GeoJSON.readFeatures(ws.raw("\(name).geojson", from: naturalEarth + "\(name).geojson"))
    }

    static func lines(of feature: Feature) -> [[Vec2]] {
        if case .lines(let l) = feature.geometry { return l }
        return []
    }

    static func polygons(of feature: Feature) -> [[[Vec2]]] {
        if case .polygons(let p) = feature.geometry { return p }
        return []
    }

    static func simplifiedLines(_ lines: [[Vec2]], tolerance: Double) -> [[Vec2]] {
        lines.flatMap { Planar.splitAtAntimeridian($0) }.compactMap { Planar.simplifyLine($0, tolerance: tolerance) }
    }

    static func summary(_ w: FeatureCollectionWriter, inputVertices: Int) -> String {
        "   \(w.featureCount) features, \(inputVertices) → \(w.vertexCount) vertices"
    }

    // MARK: Rivers

    static func rivers(_ ws: Workspace) throws {
        let features = try naturalEarthFeatures(ws, "ne_50m_rivers_lake_centerlines")
        var w = FeatureCollectionWriter()
        var input = 0
        for f in features {
            let l = lines(of: f)
            input += l.reduce(0) { $0 + $1.count }
            w.add(lines: simplifiedLines(l, tolerance: 0.01), properties: [
                ("name", .string(f.properties.string("name"))),
                ("rank", .int(Int(f.properties.number("scalerank") ?? 0))),
            ])
        }
        print(summary(w, inputVertices: input))
        try ws.write(w.data(), to: "rivers.geojson")
    }

    // MARK: Lakes

    static func lakes(_ ws: Workspace) throws {
        let features = try naturalEarthFeatures(ws, "ne_50m_lakes")
        var w = FeatureCollectionWriter()
        var input = 0
        for f in features {
            let p = polygons(of: f)
            input += p.joined().reduce(0) { $0 + $1.count }
            w.add(polygons: Planar.simplifyPolygons(p, tolerance: 0.01), properties: [
                ("name", .string(f.properties.string("name"))),
                ("rank", .int(Int(f.properties.number("scalerank") ?? 0))),
            ])
        }
        print(summary(w, inputVertices: input))
        try ws.write(w.data(), to: "lakes.geojson")
    }

    // MARK: Countries

    static func countries(_ ws: Workspace) throws {
        let features = try naturalEarthFeatures(ws, "ne_50m_admin_0_countries")
        let layer = features.map(polygons(of:))
        let simplified = TopologySimplifier.simplify(layer, tolerance: 0.02)
        let naive = layer.map { Planar.simplifyPolygons($0, tolerance: 0.02) }
        print("   shared borders, input:                  \(TopologySimplifier.describe(TopologySimplifier.sharedEdgeStatistics(layer)))")
        print("   shared borders, topology-preserving DP: \(TopologySimplifier.describe(TopologySimplifier.sharedEdgeStatistics(simplified)))")
        print("   shared borders, per-ring DP (unused):   \(TopologySimplifier.describe(TopologySimplifier.sharedEdgeStatistics(naive)))")

        var w = FeatureCollectionWriter()
        let input = layer.joined().joined().reduce(0) { $0 + $1.count }
        var continents = Set<String>()
        for (i, f) in features.enumerated() {
            let p = f.properties
            var result = simplified[i]
            if result.isEmpty {
                // Keep every country: fall back to the largest unsimplified ring.
                let rings = layer[i].compactMap(\.first)
                if let ring = rings.max(by: { abs(Planar.signedArea($0)) < abs(Planar.signedArea($1)) }),
                   let clean = Planar.cleanRing(ring) {
                    result = [[clean]]
                }
                print("   note: \(p.string("NAME")) collapsed; kept its largest ring unsimplified")
            }
            continents.insert(p.string("CONTINENT"))
            w.add(polygons: result, properties: [
                ("name", .string(p.string("NAME"))),
                ("iso", .string(p.string("ADM0_A3"))),
                ("continent", .string(p.string("CONTINENT"))),
                ("pop", .number(p.number("POP_EST") ?? 0, decimals: 0)),
                ("color", .int(Int(p.number("MAPCOLOR7") ?? 0))),
                ("labelLon", .number(p.number("LABEL_X") ?? 0, decimals: 3)),
                ("labelLat", .number(p.number("LABEL_Y") ?? 0, decimals: 3)),
            ])
        }
        print(summary(w, inputVertices: input) + ", \(continents.count) continents")
        try ws.write(w.data(), to: "countries.geojson")
    }

    // MARK: Country borders

    static func countryBorders(_ ws: Workspace) throws {
        let features = try naturalEarthFeatures(ws, "ne_50m_admin_0_boundary_lines_land")
        var w = FeatureCollectionWriter()
        var input = 0
        for f in features {
            let l = lines(of: f)
            input += l.reduce(0) { $0 + $1.count }
            w.add(lines: simplifiedLines(l, tolerance: 0.02), properties: [("name", .string(f.properties.string("NAME")))])
        }
        print(summary(w, inputVertices: input))
        try ws.write(w.data(), to: "country-borders.geojson")
    }
}
