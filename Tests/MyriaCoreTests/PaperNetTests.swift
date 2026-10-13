import Foundation
import Testing
@testable import MyriaCore

@Suite("Paper globes")
struct PaperNetTests {
    static func net(_ polyhedron: Polyhedron, sheet: Vec2 = PaperNet.Paper.a4.size, diameter: Double = 120,
                    seed: UInt64 = 42) throws -> (MyriahedralProjection, PaperNet) {
        let mesh = try MyriahedralMesh(polyhedron)
        let weights = UnfoldingTests.pseudoRandomWeights(mesh.topology.edgeCount, seed: seed)
        let projection = mesh.unfold(weights: weights, root: 0)
        let net = try PaperNet(projection: projection, options: PaperNet.Options(sheet: sheet, diameter: diameter))
        return (projection, net)
    }

    static let cases: [(String, Polyhedron, Double)] = [
        ("geodesic 4 at 12 cm", .geodesic(frequency: 4), 120),
        ("geodesic 6 at 20 cm", .geodesic(frequency: 6), 200),
        ("graticule 15° at 15 cm", .graticule(latitudeStep: 15, longitudeStep: 15), 150),
    ]

    /// Everything that makes the paper fold back into the polyhedron.
    @Test(arguments: cases.indices)
    func piecesFoldBackIntoTheGlobe(index: Int) throws {
        let (name, polyhedron, diameter) = Self.cases[index]
        let (projection, net) = try Self.net(polyhedron, diameter: diameter)
        let mesh = projection.mesh, o = net.options
        // Every face in exactly one piece.
        #expect(net.pieces.flatMap(\.faces).sorted() == Array(0..<mesh.faceCount), "\(name)")
        // Each piece is a tree of folds: faces − pieces folds in all, and
        // every cut of the layout is a seam.
        #expect(net.folds.count == mesh.faceCount - net.pieces.count, "\(name)")
        #expect(net.folds.count + net.seams.count == mesh.topology.edgeCount)
        for e in projection.cutEdges { #expect(net.seamOf[e] >= 0) }
        // Both sides of a seam are equally long, on paper too.
        for seam in net.seams {
            let edge = mesh.topology.edges[seam.edge]
            let (a, b) = net.segment(of: seam.edge, in: edge.leftFace, mesh: mesh)
            let (c, d) = net.segment(of: seam.edge, in: edge.rightFace, mesh: mesh)
            #expect(abs((b - a).length - (d - c).length) < 1e-9)
        }
        // Everything lies on its sheet, inside the margins and below the title.
        for piece in net.pieces {
            let p = piece.placement
            let top = o.sheet.y - o.margin - (p.sheet == 0 ? o.header : 0)
            for f in piece.faces {
                for q in net.polygons[f].map(p.apply) {
                    #expect(q.x >= o.margin - 1e-6 && q.x <= o.sheet.x - o.margin + 1e-6 && q.y >= o.margin - 1e-6 && q.y <= top + 1e-6,
                            "\(name): face \(f) leaves its sheet at \(q)")
                }
            }
            #expect(p.sheet < net.sheetCount)
        }
        // Pieces on a sheet keep apart; faces in a piece do not overlap.
        for sheet in 0..<net.sheetCount {
            let placed = net.pieces(onSheet: sheet).flatMap { p in net.pieces[p].faces.map { (p, net.polygons[$0].map(net.pieces[p].placement.apply)) } }
            for i in placed.indices {
                for j in placed.indices where j > i {
                    #expect(!PaperNet.overlaps(placed[i].1, placed[j].1, tolerance: 1e-6), "\(name): faces overlap on sheet \(sheet)")
                }
            }
        }
        // Tabs stay off the faces of their own piece.
        for seam in net.seams {
            guard let f = seam.tabFace else { continue }
            for g in net.pieces[net.pieceOf[f]].faces {
                #expect(!PaperNet.overlaps(seam.tab, net.polygons[g], tolerance: 1e-9), "\(name): tab on face \(f) covers face \(g)")
            }
        }
        // Numbers pair tabs with edges, each used once.
        let numbers = net.seams.filter(\.isNumbered).map(\.number).sorted()
        #expect(numbers == Array(1...max(numbers.count, 1)).prefix(numbers.count).map { $0 })
        #expect(net.looseSeams == 0, "\(name): seams with neither a tab nor a partner across a slit")
    }

    @Test func smallSheetsSplitTheNet() throws {
        let (_, big) = try Self.net(.geodesic(frequency: 4), sheet: PaperNet.Paper.a3.size, diameter: 100)
        let (_, small) = try Self.net(.geodesic(frequency: 4), sheet: Vec2(120, 120), diameter: 100)
        #expect(small.pieces.count > big.pieces.count)
        #expect(small.seams.contains { $0.isPaperCut })
        #expect(small.sheetCount > big.sheetCount)
    }

    @Test func foldOversAreSplitApart() throws {
        // Random weights on a fine mesh unfold with fold-overs (van Wijk); on
        // paper, overlapping faces go to different pieces.
        let (projection, net) = try Self.net(.geodesic(frequency: 10), diameter: 300, seed: 7)
        try #require(!projection.overlappingFaces().isEmpty, "this net needs a fold-over to test")
        for piece in net.pieces { #expect(PaperNet.firstOverlap(piece.faces, net.polygons) == nil) }
    }

    @Test func refusesFacesLargerThanTheSheet() {
        #expect(throws: PaperNet.Failure.self) {
            _ = try Self.net(.geodesic(frequency: 1), sheet: Vec2(100, 100), diameter: 600)
        }
    }
}
