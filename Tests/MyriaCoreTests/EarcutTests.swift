import Foundation
import Testing
@testable import MyriaCore

@Suite("Earcut")
struct EarcutTests {
    // MARK: Helpers

    /// Shoelace area, positive for counter-clockwise rings.
    static func signedArea(_ ring: [Vec2]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var sum = 0.0
        var prev = ring[ring.count - 1]
        for p in ring {
            sum += prev.cross(p)
            prev = p
        }
        return sum / 2
    }

    /// Checks the triangulation's structure (whole triples, indices in range,
    /// every triangle strictly counter-clockwise) and returns its total area.
    @discardableResult
    static func checkedArea(
        _ vertices: [Vec2], _ indices: [Int], strictlyCounterClockwise: Bool = true,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Double {
        #expect(indices.count % 3 == 0, sourceLocation: sourceLocation)
        #expect(indices.allSatisfy { vertices.indices.contains($0) }, "index out of range", sourceLocation: sourceLocation)
        guard indices.count % 3 == 0, indices.allSatisfy({ vertices.indices.contains($0) }) else { return .nan }
        var total = 0.0
        var clockwise = 0
        for t in stride(from: 0, to: indices.count, by: 3) {
            let a = vertices[indices[t]], b = vertices[indices[t + 1]], c = vertices[indices[t + 2]]
            // Same expression as earcut's orientation test, so ears are exactly positive.
            let doubled = (b - a).cross(c - b)
            if doubled <= 0 { clockwise += 1 }
            total += abs(doubled) / 2
        }
        if strictlyCounterClockwise {
            #expect(clockwise == 0, "\(clockwise) triangles not counter-clockwise", sourceLocation: sourceLocation)
        }
        return total
    }

    static func expectClose(
        _ actual: Double, _ expected: Double, relative: Double = 1e-9,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let error = abs(actual - expected) / max(abs(expected), 1e-300)
        #expect(error < relative, "area \(actual) expected \(expected)", sourceLocation: sourceLocation)
    }

    /// Triangulates rings (outer first) and checks area and triangle count.
    static func verify(
        _ rings: [[Vec2]], expectedTriangles: Int? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let (vertices, indices) = Earcut.triangulate(rings: rings)
        #expect(vertices == rings.flatMap { $0 }, sourceLocation: sourceLocation)
        let area = checkedArea(vertices, indices, sourceLocation: sourceLocation)
        let expected = abs(signedArea(rings[0])) - rings.dropFirst().reduce(0) { $0 + abs(signedArea($1)) }
        expectClose(area, expected, sourceLocation: sourceLocation)
        if let expectedTriangles {
            #expect(indices.count / 3 == expectedTriangles, sourceLocation: sourceLocation)
        }
    }

    /// Deterministic generator (SplitMix64).
    struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// A counter-clockwise star-shaped ring with random radii in `radii`.
    static func randomStar(
        count: Int, center: Vec2 = .zero, radii: ClosedRange<Double>, using rng: inout SeededGenerator
    ) -> [Vec2] {
        (0..<count).map { k in
            let angle = 2 * Double.pi * Double(k) / Double(count)
            let r = Double.random(in: radii, using: &rng)
            return center + Vec2(cos(angle), sin(angle)) * r
        }
    }

    /// Sutherland–Hodgman clipping against a convex counter-clockwise polygon.
    /// Concave subjects come out as one ring whose separate pieces are joined
    /// by zero-width bridges running back and forth along the clip boundary.
    static func clip(_ subject: [Vec2], to convex: [Vec2]) -> [Vec2] {
        var output = subject
        var a = convex[convex.count - 1]
        for b in convex {
            let input = output
            output = []
            guard !input.isEmpty else { break }
            let edge = b - a
            var prev = input[input.count - 1]
            var prevSide = edge.cross(prev - a)
            for current in input {
                let side = edge.cross(current - a)
                if side >= 0 {
                    if prevSide < 0 { output.append(Vec2.lerp(prev, current, prevSide / (prevSide - side))) }
                    output.append(current)
                } else if prevSide >= 0 {
                    output.append(Vec2.lerp(prev, current, prevSide / (prevSide - side)))
                }
                prev = current
                prevSide = side
            }
            a = b
        }
        return output
    }

    static func regularPolygon(_ count: Int, radius: Double = 1, center: Vec2 = .zero) -> [Vec2] {
        (0..<count).map { k in
            let angle = 2 * Double.pi * Double(k) / Double(count)
            return center + Vec2(cos(angle), sin(angle)) * radius
        }
    }

    static func rectangle(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [Vec2] {
        [Vec2(x0, y0), Vec2(x1, y0), Vec2(x1, y1), Vec2(x0, y1)]
    }

    // MARK: Simple polygons

    struct Shape: Sendable, CustomTestStringConvertible {
        let name: String
        let ring: [Vec2]
        var testDescription: String { name }
    }

    static let simpleShapes: [Shape] = {
        var shapes = [
            Shape(name: "square", ring: rectangle(0, 0, 1, 1)),
            Shape(name: "triangle", ring: [Vec2(0, 0), Vec2(4, 1), Vec2(1, 3)]),
            Shape(name: "convex hexagon", ring: regularPolygon(6, radius: 2)),
            Shape(name: "L shape", ring: [Vec2(0, 0), Vec2(2, 0), Vec2(2, 1), Vec2(1, 1), Vec2(1, 2), Vec2(0, 2)]),
        ]
        // A comb: a spine along the bottom with teeth pointing up.
        var comb: [Vec2] = [Vec2(0, 0), Vec2(19, 0)]
        for tooth in stride(from: 9, through: 0, by: -1) {
            let x = Double(2 * tooth)
            comb += [Vec2(x + 1, 5), Vec2(x, 5), Vec2(x, 1), Vec2(x - 1, 1)]
        }
        comb.removeLast(2) // the first tooth's left side closes down to the spine's start
        shapes.append(Shape(name: "comb", ring: comb))
        // Stars with alternating radii; the larger ones use z-order hashing.
        for points in [5, 12, 60] {
            let star = (0..<(2 * points)).map { k in
                let angle = Double.pi * Double(k) / Double(points)
                return Vec2(cos(angle), sin(angle)) * (k % 2 == 0 ? 1.0 : 0.4)
            }
            shapes.append(Shape(name: "\(points)-point star", ring: star))
        }
        // A rectangular spiral corridor: deeply concave, every ear is tested.
        var inner: [Vec2] = [], outer: [Vec2] = []
        for turn in 0..<24 {
            let angle = Double(turn) * Double.pi / 2
            let direction = Vec2(cos(angle), sin(angle))
            let r = 1 + Double(turn) * 0.5
            outer.append(direction * (r + 0.3))
            inner.append(direction * r)
        }
        shapes.append(Shape(name: "spiral", ring: outer + inner.reversed()))
        var rng = SeededGenerator(seed: 7)
        shapes.append(Shape(name: "random star", ring: randomStar(count: 500, radii: 0.2...1, using: &rng)))
        return shapes
    }()

    @Test("simple polygons give n - 2 triangles and preserve area", arguments: EarcutTests.simpleShapes)
    func simplePolygon(_ shape: Shape) {
        for ring in [shape.ring, shape.ring.reversed()] {
            let indices = Earcut.triangulate(outer: ring)
            #expect(indices.count == 3 * (ring.count - 2))
            Self.expectClose(Self.checkedArea(ring, indices), abs(Self.signedArea(ring)))
        }
    }

    @Test func matchesReferenceIndices() {
        // earcut's own "indices-2d" test case.
        let ring = [Vec2(10, 0), Vec2(0, 50), Vec2(60, 60), Vec2(70, 10)]
        #expect(Earcut.triangulate(outer: ring) == [1, 0, 3, 1, 3, 2])
    }

    // MARK: Holes

    @Test func oneHole() {
        let rings = [Self.rectangle(0, 0, 4, 4), Self.rectangle(1, 1, 3, 3)]
        Self.verify(rings, expectedTriangles: 8) // n + 2h - 2
    }

    @Test func severalHoles() {
        // Holes in general position: a bridge collinear with an edge would be
        // filtered away, giving fewer than n + 2h - 2 triangles.
        let holes = [
            [Vec2(1, 1), Vec2(2, 1.2), Vec2(2.2, 2.9), Vec2(1.1, 2.5)],
            Self.regularPolygon(7, radius: 1, center: Vec2(4.5, 2)),
            [Vec2(7, 1), Vec2(9, 1.3), Vec2(8.8, 2.1), Vec2(7.2, 1.9)],
            [Vec2(7.1, 2.5), Vec2(9, 2.6), Vec2(8, 3.5)],
        ]
        let rings = [Self.rectangle(0, 0, 10, 4)] + holes
        let n = rings.reduce(0) { $0 + $1.count }
        Self.verify(rings, expectedTriangles: n + 2 * holes.count - 2)

        // Axis-aligned holes whose bridges run along hole edges still
        // preserve the area.
        Self.verify([Self.rectangle(0, 0, 10, 4), Self.rectangle(1, 1, 2, 3), Self.rectangle(7, 1, 9, 2)])
    }

    @Test func eitherWindingGivesTheSameResult() {
        let outer = Self.regularPolygon(9, radius: 5)
        let holes = [Self.rectangle(-1, -1, 1, 1), Self.regularPolygon(5, radius: 0.8, center: Vec2(2.5, 0))]
        let expectedArea = abs(Self.signedArea(outer)) - holes.reduce(0) { $0 + abs(Self.signedArea($1)) }
        let n = 9 + 4 + 5
        for outerRing in [outer, outer.reversed()] {
            for flip in [false, true] {
                let holeRings = holes.map { flip ? $0.reversed() : $0 }
                let indices = Earcut.triangulate(outer: outerRing, holes: holeRings)
                let vertices = outerRing + holeRings.flatMap { $0 }
                #expect(indices.count == 3 * (n + 2 * 2 - 2))
                Self.expectClose(Self.checkedArea(vertices, indices), expectedArea)
            }
        }
    }

    @Test func holesTouchingTheOuterRing() {
        let outer = Self.rectangle(0, 0, 4, 4)
        // A hole whose leftmost vertex lies on the outer ring's left edge.
        Self.verify([outer, [Vec2(0, 2), Vec2(1, 1), Vec2(2, 2), Vec2(1, 3)]])
        // A hole sharing a vertex with the outer ring.
        Self.verify([outer, [Vec2(0, 0), Vec2(1, 2), Vec2(2, 1)]])
        // Two holes touching each other at a vertex.
        Self.verify([outer, [Vec2(1, 1), Vec2(2, 2), Vec2(1, 3)], [Vec2(2, 2), Vec2(3, 1), Vec2(3, 3)]])
    }

    @Test func singlePointHoleBecomesSteinerPoint() {
        let (vertices, indices) = Earcut.triangulate(rings: [Self.rectangle(0, 0, 2, 2), [Vec2(1, 1)]])
        #expect(indices.contains(4))
        Self.expectClose(Self.checkedArea(vertices, indices), 4)
    }

    @Test func emptyHolesAreIgnored() {
        let outer = Self.rectangle(0, 0, 1, 1)
        #expect(Earcut.triangulate(outer: outer, holes: [[], []]) == Earcut.triangulate(outer: outer))
        #expect(Earcut.triangulate(rings: []).indices.isEmpty)
    }

    // MARK: Degenerate input

    @Test func tooFewOrCollinearPoints() {
        #expect(Earcut.triangulate(outer: []).isEmpty)
        #expect(Earcut.triangulate(outer: [Vec2(1, 1)]).isEmpty)
        #expect(Earcut.triangulate(outer: [Vec2(0, 0), Vec2(1, 1)]).isEmpty)
        #expect(Earcut.triangulate(outer: [Vec2(0, 0), Vec2(1, 1), Vec2(2, 2)]).isEmpty)
        #expect(Earcut.triangulate(outer: [Vec2(0, 0), Vec2(1, 1), Vec2(3, 3), Vec2(2, 2), Vec2(-1, -1)]).isEmpty)
        #expect(Earcut.triangulate(outer: Array(repeating: Vec2(3, 4), count: 5)).isEmpty)
        // On the line y = 2x, where the shoelace sum suffers roundoff.
        #expect(Earcut.triangulate(outer: [Vec2(0.1, 0.2), Vec2(1.3, 2.6), Vec2(2.5, 5.0), Vec2(3.7, 7.4)]).isEmpty)
    }

    @Test func nonFiniteCoordinatesGiveNoTriangles() {
        #expect(Earcut.triangulate(outer: [Vec2(0, 0), Vec2(1, 0), Vec2(.nan, 1), Vec2(0, 1)]).isEmpty)
        #expect(Earcut.triangulate(outer: [Vec2(0, 0), Vec2(.infinity, 0), Vec2(0, 1)]).isEmpty)
    }

    @Test func repeatedAndCollinearPoints() {
        let ring = [
            Vec2(0, 0), Vec2(0, 0), Vec2(0.5, 0), Vec2(1, 0), Vec2(1, 0), Vec2(1, 0.25),
            Vec2(1, 1), Vec2(0, 1), Vec2(0, 1), Vec2(0, 0.5), Vec2(0, 0), // closing point repeated
        ]
        Self.expectClose(Self.checkedArea(ring, Earcut.triangulate(outer: ring)), 1)
    }

    @Test func zeroWidthBridgeFromClipping() {
        // A "U" clipped to y >= 2 by Sutherland–Hodgman: the two arm tops are
        // joined along y = 2 by coincident edges running both ways.
        let clipped = [Vec2(0, 2), Vec2(3, 2), Vec2(3, 3), Vec2(2, 3),
                       Vec2(2, 2), Vec2(1, 2), Vec2(1, 3), Vec2(0, 3)]
        for ring in [clipped, clipped.reversed()] {
            let indices = Earcut.triangulate(outer: ring)
            Self.expectClose(Self.checkedArea(ring, indices), 2)
        }

        // The comb clipped across its teeth: ten pieces, nine bridges.
        let comb = Self.simpleShapes.first { $0.name == "comb" }!.ring
        let teeth = Self.clip(comb, to: Self.rectangle(-5, 2, 25, 4))
        Self.expectClose(Self.checkedArea(teeth, Earcut.triangulate(outer: teeth)), 20)
    }

    /// A spiky star clipped to a square window away from its centre, as
    /// polygons are clipped to polyhedron faces: spikes reaching into the
    /// window become separate pieces, which Sutherland–Hodgman joins by
    /// zero-width bridges along the window edges. Bridge vertices come from
    /// interpolation, so they lie off the clip lines by rounding error.
    static func clippedSpikyStar(seed: Int, rotatedWindow: Bool) -> [Vec2] {
        var rng = SeededGenerator(seed: UInt64(seed))
        let star = randomStar(count: 60, radii: 0.2...1.6, using: &rng)
        let direction = Double.random(in: 0..<(2 * Double.pi), using: &rng)
        let center = Vec2(cos(direction), sin(direction)) * 1.1
        guard rotatedWindow else {
            return clip(star, to: rectangle(center.x - 0.5, center.y - 0.5, center.x + 0.5, center.y + 0.5))
        }
        let rotation = Double.random(in: 0..<(Double.pi / 2), using: &rng)
        let window = (0..<4).map { k in
            let angle = rotation + Double(k) * Double.pi / 2
            return center + Vec2(cos(angle), sin(angle)) * 0.6
        }
        return clip(star, to: window)
    }

    @Test func clippedPolygonsWithBridgesPreserveArea() {
        // Axis-parallel clip lines: bridge vertices are off the line by an ulp
        // or so, which the tolerance in the ear test absorbs. (With earcut's
        // exact test about 5% of these cases cover part of a gap.)
        for seed in 0..<300 {
            let ring = Self.clippedSpikyStar(seed: seed, rotatedWindow: false)
            guard ring.count >= 3 else { continue }
            let area = Self.checkedArea(ring, Earcut.triangulate(outer: ring))
            let expected = abs(Self.signedArea(ring))
            #expect(abs(area - expected) < 1e-12, "seed \(seed): area \(area) expected \(expected)")
        }
    }

    @Test func clippedPolygonsWithBridgesOnGeneralLines() {
        // On general clip lines, rounding can make bridge edges cross by
        // ~1e-16. Earcut, which requires simple input, then occasionally
        // covers part of a gap between pieces (about 1.5% of these cases,
        // against about 28% without the ear-test tolerance). Clipping into
        // separate rings instead of Sutherland–Hodgman bridges avoids this.
        var failures = 0
        for seed in 0..<300 {
            let ring = Self.clippedSpikyStar(seed: seed, rotatedWindow: true)
            guard ring.count >= 3 else { continue }
            let indices = Earcut.triangulate(outer: ring)
            let area = Self.checkedArea(ring, indices, strictlyCounterClockwise: false)
            if abs(area - abs(Self.signedArea(ring))) > 1e-12 { failures += 1 }
        }
        withKnownIssue("Earcut needs exactly coincident bridge edges", isIntermittent: true) {
            #expect(failures == 0)
        }
        #expect(failures <= 15)
    }

    @Test func terminatesOnPathologicalInput() {
        // earcut's "infinite-loop" regression case.
        let flat: [Double] = [1, 2, 2, 2, 1, 2, 1, 1, 1, 2, 4, 1, 5, 1, 3, 2, 4, 2, 4, 1]
        let points = stride(from: 0, to: flat.count, by: 2).map { Vec2(flat[$0], flat[$0 + 1]) }
        let indices = Earcut.triangulate(vertices: points, holeIndices: [5])
        Self.checkedArea(points, indices, strictlyCounterClockwise: false)

        // A self-intersecting bow tie.
        let bowTie = [Vec2(0, 0), Vec2(2, 2), Vec2(2, 0), Vec2(0, 2)]
        Self.checkedArea(bowTie, Earcut.triangulate(outer: bowTie), strictlyCounterClockwise: false)
    }

    // MARK: Large input

    @Test func largeStarWithHoles() {
        var rng = SeededGenerator(seed: 2024)
        let outer = Self.randomStar(count: 2000, radii: 0.7...1, using: &rng)
        let holes = (0..<20).map { h in
            let angle = 2 * Double.pi * Double(h) / 20
            return Self.randomStar(count: 30, center: Vec2(cos(angle), sin(angle)) * 0.4,
                                   radii: 0.03...0.05, using: &rng).reversed() as [Vec2]
        }
        let rings = [outer] + holes

        var indices: [Int] = []
        var best = Duration.seconds(1000)
        for _ in 0..<3 {
            let elapsed = ContinuousClock().measure { indices = Earcut.triangulate(outer: outer, holes: holes) }
            best = min(best, elapsed)
        }
        print("Earcut: 2000-vertex star with 20 holes (2600 vertices) in \(best)")
        #expect(best < .milliseconds(100))

        let vertices = rings.flatMap { $0 }
        #expect(indices.count / 3 == vertices.count + 2 * holes.count - 2)
        let expected = abs(Self.signedArea(outer)) - holes.reduce(0) { $0 + abs(Self.signedArea($1)) }
        Self.expectClose(Self.checkedArea(vertices, indices), expected)
    }
}
