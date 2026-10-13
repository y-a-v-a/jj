import Foundation
import Testing
@testable import MyriaCore

/// Van Wijk's figure 13: the myriahedral map with its interrupts removed.
@Suite("Closed gaps")
struct ClosedGapsTests {
    /// A layout-like unfolding: folds prefer to run east–west near the
    /// equator, as in the graticular maps, so the map has long gaps to close.
    static func projection(_ polyhedron: Polyhedron) throws -> MyriahedralProjection {
        let mesh = try MyriahedralMesh(polyhedron)
        let p = mesh.polyhedron
        let weights = mesh.topology.edges.map { e -> Double in
            let mid = (p.vertices[e.a] + p.vertices[e.b]).normalized
            return -abs(mid.z) + 0.01 * UnfoldingTests.pseudoRandomWeights(1, seed: UInt64(e.a * 7919 + e.b))[0]
        }
        return mesh.unfold(weights: weights, root: 0)
    }

    @Test func gapsCloseIntoOneSheet() throws {
        let projection = try Self.projection(.geodesic(frequency: 12))
        let gaps = try #require(ClosedGaps(projection: projection))
        let cuts = projection.cutEdges.count
        // Most seams zip shut; what stays open is the outline.
        #expect(Double(gaps.openSeams.count) < 0.2 * Double(cuts), "\(gaps.openSeams.count) of \(cuts) seams open")
        #expect(gaps.rounds > 1)
        // No face turned over, and faces keep about their size: the sheet
        // stretches a little everywhere rather than much anywhere.
        let frames = projection.mesh.frames
        var flipped = 0
        var ratios: [Double] = []
        for f in frames.indices {
            let area = Planar.signedArea(gaps.closed[f])
            if area <= 0 { flipped += 1 }
            ratios.append(area / Planar.signedArea(frames[f].localVertices))
        }
        ratios.sort()
        #expect(flipped == 0)
        let median = ratios[ratios.count / 2], low = ratios[ratios.count / 20], high = ratios[ratios.count * 19 / 20]
        #expect(abs(median - 1) < 0.15 && low > 0.5 && high < 2, "area ratios: 5 % \(low), median \(median), 95 % \(high)")
    }

    @Test func openIsTheMyriahedralMap() throws {
        let projection = try Self.projection(.geodesic(frequency: 6))
        let gaps = try #require(ClosedGaps(projection: projection))
        let frames = projection.mesh.frames
        for f in frames.indices {
            // At 0 every face sits where the unfolding put it…
            let (a, b, t) = gaps.affine(face: f, local: frames[f].localVertices, amount: 0)
            for (k, v) in frames[f].localVertices.enumerated() {
                #expect((a * v.x + b * v.y + t - projection.mapPolygons[f][k]).length < 1e-9)
            }
            // …and at any amount the point under a face's centre is found again.
            for amount in [0.0, 0.5, 1.0] {
                let centre = Planar.centroid(gaps.corners(of: f, amount: amount))
                let hit = try #require(gaps.face(at: centre, amount: amount, frames: frames))
                let (a, b, t) = gaps.affine(face: hit.face, local: frames[hit.face].localVertices, amount: amount)
                #expect((a * hit.local.x + b * hit.local.y + t - centre).length < 1e-9)
            }
        }
    }

    @Test func onlyTrianglesBend() throws {
        let mesh = try MyriahedralMesh(.graticule(latitudeStep: 15, longitudeStep: 15))
        let projection = mesh.unfold(weights: UnfoldingTests.pseudoRandomWeights(mesh.topology.edgeCount), root: 0)
        #expect(ClosedGaps(projection: projection) == nil)
    }
}
