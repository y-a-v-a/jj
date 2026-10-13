import Foundation
import MyriaCore

/// Peter Bird's PB2002 plate model (G-cubed 4(3), 1027, 2003) as converted to
/// GeoJSON by Hugo Ahlenius (github.com/fraxen/tectonicplates).
///
/// Inspection of PB2002_plates.json (all rings are closed and clockwise in lon/lat):
/// - Plates straddling the antimeridian are already split into separate rings
///   that run along lon = ±180: PA (3 polygons), AU (2), and KE and BR, which
///   come as two features each (merged here into one MultiPolygon per code).
/// - AN and NA contain a pole: their single rings run along ±180 up to the
///   pole and close with an explicit edge along lat = −90 / +90 from +180 to
///   −180 (the only lon jumps > 180° in the data).
/// So the rings are already valid for an even–odd test in lon/lat space; the
/// tool asserts that no other kind of antimeridian jump exists and checks
/// coverage of a 1° grid plus a few known points instead of rewriting rings.
enum TectonicPlates {
    static let repository = "https://raw.githubusercontent.com/fraxen/tectonicplates/master/GeoJSON/"

    static func run(_ ws: Workspace) throws {
        let plates = try platePolygons(ws)
        try boundaries(ws, plates: plates)
    }

    // MARK: Plates

    struct Plate {
        let code: String
        let name: String
        var polygons: [[[Vec2]]]
    }

    static func platePolygons(_ ws: Workspace) throws -> [Plate] {
        let features = try GeoJSON.readFeatures(ws.raw("PB2002_plates.json", from: repository + "PB2002_plates.json"))
        var plates: [Plate] = []
        for f in features {
            let code = f.properties.string("Code"), name = f.properties.string("PlateName")
            let polygons = VectorLayers.polygons(of: f)
            if let i = plates.firstIndex(where: { $0.code == code }) {
                plates[i].polygons += polygons
            } else {
                plates.append(Plate(code: code, name: name, polygons: polygons))
            }
        }
        print("   \(features.count) input features → \(plates.count) plates")

        // Antimeridian / pole inspection.
        var straddling: [String] = [], polar: [String] = []
        for plate in plates {
            let rings = plate.polygons.joined()
            if rings.contains(where: { $0.contains { abs($0.x) == 180 } }) && !plate.polygons.isEmpty {
                straddling.append("\(plate.code)×\(plate.polygons.count)")
            }
            for ring in rings {
                for (a, b) in zip(ring, ring.dropFirst()) where abs(a.x - b.x) > 180 {
                    guard abs(a.y) == 90, a.y == b.y else {
                        throw PrepError("\(plate.code): unexpected antimeridian jump \(a) → \(b); rings need splitting")
                    }
                    polar.append("\(plate.code) (closes along lat \(Int(a.y)))")
                }
            }
        }
        print("   rings touching lon ±180 (code×polygons): \(straddling.joined(separator: ", "))")
        print("   pole-encircling rings: \(polar.joined(separator: ", "))")

        let layer = plates.map(\.polygons)
        let simplified = TopologySimplifier.simplify(layer, tolerance: 0.02)
        let naive = layer.map { Planar.simplifyPolygons($0, tolerance: 0.02) }
        print("   shared borders, input:                  \(TopologySimplifier.describe(TopologySimplifier.sharedEdgeStatistics(layer)))")
        print("   shared borders, topology-preserving DP: \(TopologySimplifier.describe(TopologySimplifier.sharedEdgeStatistics(simplified)))")
        print("   shared borders, per-ring DP (unused):   \(TopologySimplifier.describe(TopologySimplifier.sharedEdgeStatistics(naive)))")
        print("   1° grid coverage, input:      \(coverage(layer))")
        print("   1° grid coverage, simplified: \(coverage(simplified))")

        var output = plates
        for i in output.indices { output[i].polygons = simplified[i] }
        try checkTestPoints(output)

        var w = FeatureCollectionWriter()
        for plate in output where !plate.polygons.isEmpty {
            w.add(polygons: plate.polygons, properties: [("code", .string(plate.code)), ("name", .string(plate.name))])
        }
        let input = layer.joined().joined().reduce(0) { $0 + $1.count }
        print(VectorLayers.summary(w, inputVertices: input))
        try ws.write(w.data(), to: "plates.geojson")
        return output
    }

    /// Counts 1° grid cell centres covered by no plate or by several plates.
    static func coverage(_ layer: [[[[Vec2]]]]) -> String {
        var none = 0, multiple = 0
        let boxes = layer.map(boundingBox)
        for j in 0..<180 {
            for i in 0..<360 {
                let p = Vec2(-179.5 + Double(i), -89.5 + Double(j))
                var count = 0
                for (k, polygons) in layer.enumerated() where boxes[k].contains(p) && Planar.contains(polygons, p) {
                    count += 1
                }
                if count == 0 { none += 1 } else if count > 1 { multiple += 1 }
            }
        }
        return "\(360 * 180) points, \(none) in no plate, \(multiple) in several"
    }

    struct Box {
        var lo = Vec2(.infinity, .infinity), hi = Vec2(-.infinity, -.infinity)
        func contains(_ p: Vec2) -> Bool { p.x >= lo.x && p.x <= hi.x && p.y >= lo.y && p.y <= hi.y }
    }

    static func boundingBox(_ polygons: [[[Vec2]]]) -> Box {
        var b = Box()
        for p in polygons.joined().joined() {
            b.lo = Vec2(min(b.lo.x, p.x), min(b.lo.y, p.y))
            b.hi = Vec2(max(b.hi.x, p.x), max(b.hi.y, p.y))
        }
        return b
    }

    static func platesContaining(_ p: Vec2, in plates: [Plate]) -> [String] {
        plates.filter { Planar.contains($0.polygons, p) }.map(\.code)
    }

    static func checkTestPoints(_ plates: [Plate]) throws {
        let tests: [(String, Double, Double, String?)] = [
            ("0°N 160°W (central Pacific)", 0, -160, "PA"),
            ("64.1°N 21.9°W (Reykjavik)", 64.1, -21.9, nil),
            ("75°S 0°E (Antarctica)", -75, 0, "AN"),
            ("35°N 100°E (Tibet)", 35, 100, "EU"),
            ("0°N 25°E (Congo basin)", 0, 25, "AF"),
            ("89.9°N 0°E (near North Pole)", 89.9, 0, nil),
            ("89.9°S 180°W (near South Pole)", -89.9, -179.9, "AN"),
            ("52°N 179.9°E (Bering Sea)", 52, 179.9, nil),
            ("40°S 179.9°W (SW Pacific)", -40, -179.9, nil),
        ]
        var failures: [String] = []
        for (label, lat, lon, expected) in tests {
            let found = platesContaining(Vec2(lon, lat), in: plates)
            let verdict: String
            if let expected {
                verdict = found == [expected] ? "ok" : "FAIL (expected \(expected))"
                if found != [expected] { failures.append(label) }
            } else {
                verdict = found.count == 1 ? "ok (single plate)" : "FAIL (expected exactly one plate)"
                if found.count != 1 { failures.append(label) }
            }
            print("   test \(label): \(found.isEmpty ? "none" : found.joined(separator: ",")) — \(verdict)")
        }
        if !failures.isEmpty { throw PrepError("plate containment tests failed: \(failures.joined(separator: "; "))") }
    }

    // MARK: Boundaries

    /// PB2002 step classes (Bird 2003, §3) and the `kind` written for them:
    ///
    ///     OSR  oceanic spreading ridge          → "ridge"
    ///     CRB  continental rift boundary        → "ridge"       (divergent, spreading)
    ///     OTF  oceanic transform fault          → "transform"
    ///     CTF  continental transform fault      → "transform"
    ///     SUB  subduction zone                  → "subduction"
    ///     OCB  oceanic convergent boundary      → "convergent"  (no subduction polarity)
    ///     CCB  continental convergent boundary  → "convergent"
    ///     anything else                         → "other"
    static func kind(of stepClass: String) -> String {
        switch stepClass {
        case "OSR", "CRB": "ridge"
        case "OTF", "CTF": "transform"
        case "SUB": "subduction"
        case "OCB", "CCB": "convergent"
        default: "other"
        }
    }

    /// Bird names a boundary "L-R" after the plates on the left and right of
    /// its digitising direction; subduction zones use "/" or "\" instead of
    /// "-", with the overriding plate on the low side of the slash ("/": the
    /// left plate overrides, "\": the right plate overrides; e.g. "NZ\SA",
    /// "OK/PA"). The output `plates` is "L-R" for the line as written; for
    /// subduction lines the line is oriented so that the overriding plate is
    /// on the left, i.e. `plates` is "overriding-subducting" and the teeth go
    /// on the left side of the line.
    static func boundaries(_ ws: Workspace, plates: [Plate]) throws {
        let url = try ws.raw("PB2002_steps.json", from: repository + "PB2002_steps.json")
        struct Step { let seq: Double; let bound: String; let stepClass: String; let line: [Vec2] }
        let steps = try GeoJSON.readFeatures(url).compactMap { f -> Step? in
            guard case .lines(let lines) = f.geometry, let line = lines.first, line.count >= 2 else { return nil }
            return Step(seq: f.properties.number("SEQNUM") ?? 0, bound: f.properties.string("PLATEBOUND"),
                        stepClass: f.properties.string("STEPCLASS"), line: line)
        }.sorted { $0.seq < $1.seq }
        let classes = Dictionary(grouping: steps, by: \.stepClass).mapValues(\.count)
        print("   \(steps.count) steps; classes: " + classes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))

        // Check Bird's left/right convention against the plate polygons.
        var agree = 0, swapped = 0, other = 0
        for s in steps {
            let m = s.line.count / 2
            let a = s.line[max(m - 1, 0)], b = s.line[min(m + 1, s.line.count - 1)]
            guard abs(b.x - a.x) < 180, a != b else { continue }
            let d = (b - a).normalized
            let left = Vec2(-d.y, d.x) * 0.1
            let names = s.bound.split(whereSeparator: { "-/\\".contains($0) }).map(String.init)
            guard names.count == 2 else { continue }
            let l = platesContaining(s.line[m] + left, in: plates)
            let r = platesContaining(s.line[m] - left, in: plates)
            if l == [names[0]] && r == [names[1]] { agree += 1 } else if l == [names[1]] && r == [names[0]] { swapped += 1 } else { other += 1 }
        }
        print("   left/right check at step midpoints (±0.1°): \(agree) agree, \(swapped) swapped, \(other) other")

        // Merge consecutive steps of the same boundary and kind into polylines.
        struct Run { var bound: String; var kind: String; var line: [Vec2] }
        var runs: [Run] = []
        for s in steps {
            let k = kind(of: s.stepClass)
            if var last = runs.last, last.bound == s.bound, last.kind == k,
               let end = last.line.last, (end - s.line[0]).length < 1e-3 {
                last.line += s.line.dropFirst()
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(bound: s.bound, kind: k, line: s.line))
            }
        }

        var w = FeatureCollectionWriter()
        var kinds: [String: Int] = [:]
        var unpolarised = 0
        let input = steps.reduce(0) { $0 + $1.line.count }
        for run in runs {
            let names = run.bound.split(whereSeparator: { "-/\\".contains($0) }).map(String.init)
            guard names.count == 2 else { throw PrepError("unexpected PB2002 boundary name \(run.bound)") }
            var line = run.line
            var plates = "\(names[0])-\(names[1])"
            if run.kind == "subduction" {
                if run.bound.contains("\\") {
                    line.reverse()
                    plates = "\(names[1])-\(names[0])"
                } else if !run.bound.contains("/") {
                    unpolarised += 1
                }
            }
            let lines = VectorLayers.simplifiedLines([line], tolerance: 0.02)
            guard !lines.isEmpty else { continue }
            kinds[run.kind, default: 0] += 1
            w.add(lines: lines, properties: [("kind", .string(run.kind)), ("plates", .string(plates))])
        }
        print("   \(runs.count) merged polylines; kinds: " + kinds.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            + (unpolarised > 0 ? "; \(unpolarised) subduction runs without polarity" : ""))
        print(VectorLayers.summary(w, inputVertices: input))
        try ws.write(w.data(), to: "plate-boundaries.geojson")
    }
}
