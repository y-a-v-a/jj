import Foundation
import Testing
@testable import MyriaCore

/// Meshes and counts from van Wijk, "Unfolding the Earth: Myriahedral
/// Projections" (The Cartographic Journal 45(1), 2008).
@Suite("Meshes from the paper")
struct PaperMeshTests {
    func assertSphereMesh(_ mesh: MyriahedralMesh, sourceLocation: SourceLocation = #_sourceLocation) {
        let p = mesh.polyhedron
        #expect(p.vertexCount - mesh.edgeCount + p.faceCount == 2, "Euler characteristic", sourceLocation: sourceLocation)
        for f in 0..<p.faceCount {
            let frame = mesh.frames[f]
            #expect(frame.area > 0, sourceLocation: sourceLocation)
            for v in p.faceVertices(f) {
                #expect(abs(frame.normal.dot(v) - frame.planeDistance) < 1e-9, "planar faces", sourceLocation: sourceLocation)
            }
            #expect(frame.normal.dot(p.faceCenter(f)) > 0, "counter-clockwise from outside", sourceLocation: sourceLocation)
        }
    }

    @Test(arguments: PlatonicSolid.allCases)
    func platonicSolids(solid: PlatonicSolid) throws {
        let p = solid.polyhedron()
        let expected: (v: Int, e: Int, f: Int) = switch solid {
        case .tetrahedron: (4, 6, 4)
        case .cube: (8, 12, 6)
        case .octahedron: (6, 12, 8)
        case .dodecahedron: (20, 30, 12)
        case .icosahedron: (12, 30, 20)
        }
        let mesh = try MyriahedralMesh(p)
        #expect(p.vertexCount == expected.v)
        #expect(mesh.edgeCount == expected.e)
        #expect(p.faceCount == expected.f)
        assertSphereMesh(mesh)
        // Regular: all edges of one length.
        let lengths = mesh.topology.edges.map { (p.vertices[$0.a] - p.vertices[$0.b]).length }
        #expect(lengths.max()! - lengths.min()! < 1e-9)
    }

    /// Figure 5: "Recursive subdivision of Platonic solids, using five levels
    /// of subdivision, 4096–20 480 polygons".
    @Test(arguments: [(PlatonicSolid.tetrahedron, 4096), (.cube, 6144), (.octahedron, 8192), (.icosahedron, 20480)])
    func fiveLevelsOfSubdivision(solid: PlatonicSolid, polygons: Int) throws {
        let kind = MeshKind.platonic(solid, levels: 5)
        #expect(kind.cellCount == polygons)
        let mesh = try MyriahedralMesh(kind.build())
        #expect(mesh.cellCount == polygons)
        assertSphereMesh(mesh)
    }

    @Test func subdividedDodecahedronIsClosed() throws {
        let mesh = try MyriahedralMesh(MeshKind.platonic(.dodecahedron, levels: 2).build())
        #expect(mesh.cellCount == 12 * 5 * 4)
        assertSphereMesh(mesh)
    }

    /// Figure 3 uses a 5° graticule with 2592 polygons, figure 4 a 1°
    /// graticule with 64 800, figure 14 a subdivided icosahedron with 81 920.
    @Test func polygonCountsOfTheFigures() {
        #expect(MeshKind.graticule(step: 5).build().polyhedron.faceCount == 2592)
        #expect(MeshKind.graticule(step: 1).cellCount == 64_800)
        #expect(MeshKind.geodesic(frequency: 64).cellCount == 81_920)
        #expect(MeshKind.platonic(.icosahedron, levels: 6).cellCount == 81_920)
    }

    /// Weights interpolate along original edges: highest (→ 1) near their
    /// centres, lowest (→ 0) at the original vertices; edges created at
    /// level i weigh at least i.
    @Test func subdivisionWeightsFollowThePaper() throws {
        let levels = 3
        let base = PlatonicSolid.octahedron.polyhedron()
        let build = RecursiveSubdivision.build(base, levels: levels)
        let mesh = try MyriahedralMesh(build)
        let weights = try #require(mesh.intrinsicWeights)
        let originalVertices = Set(base.vertices.indices)
        for (e, edge) in mesh.topology.edges.enumerated() {
            let a = build.polyhedron.vertices[edge.a], b = build.polyhedron.vertices[edge.b]
            // Is this edge part of an original octahedron edge? Then both
            // ends lie on a coordinate plane pair shared with an axis.
            let onOriginal = base.faces.contains { face in
                (0..<3).contains { k in
                    let p = base.vertices[face[k]], q = base.vertices[face[(k + 1) % 3]]
                    let n = p.cross(q).normalized
                    return abs(n.dot(a)) < 1e-12 && abs(n.dot(b)) < 1e-12
                        && a.dot(p) > -1e-12 && a.dot(q) > -1e-12 && b.dot(p) > -1e-12 && b.dot(q) > -1e-12
                }
            }
            if onOriginal {
                #expect(weights[e] > 0 && weights[e] < 1)
                // Touching an original vertex: the smallest weight, 1/2^levels.
                if originalVertices.contains(edge.a) || originalVertices.contains(edge.b) {
                    #expect(abs(weights[e] - 1.0 / 8) < 1e-12)
                }
            } else {
                #expect(weights[e] >= 1)
            }
        }
        // The two halves meeting at an original edge's midpoint weigh 7/8 at level 3.
        #expect(abs(weights.filter { $0 < 1 }.max()! - 7.0 / 8) < 1e-12)
    }

    @Test func internalEdgesStayHinged() throws {
        let mesh = try MyriahedralMesh(MeshKind.platonic(.cube, levels: 2).build())
        #expect(mesh.isInternalEdge.contains(true))
        // Even when internal edges weigh least, they are kept.
        let weights = mesh.isInternalEdge.map { $0 ? -100.0 : 1.0 }
        let hinges = mesh.hinges(weights: weights)
        for e in hinges.indices where mesh.isInternalEdge[e] { #expect(hinges[e]) }
    }

    /// The paper: Hf (folds) is a spanning tree of the dual graph H, and the
    /// cuts Gc a spanning tree of the mesh graph G, so cuts = V − 1.
    @Test(arguments: [MeshKind.graticule(step: 10), .geodesic(frequency: 5), .platonic(.cube, levels: 2),
                      .platonic(.dodecahedron, levels: 1), .platonic(.tetrahedron, levels: 0)])
    func cutsSpanTheMeshGraph(kind: MeshKind) throws {
        let mesh = try MyriahedralMesh(kind.build())
        let weights = UnfoldingTests.pseudoRandomWeights(mesh.edgeCount)
        let hinges = mesh.hinges(weights: weights)
        #expect(hinges.filter { $0 }.count == mesh.faceCount - 1)
        #expect(hinges.filter { !$0 }.count == mesh.polyhedron.vertexCount - 1)
        var sets = UnionFind(count: mesh.polyhedron.vertexCount)
        for (e, edge) in mesh.topology.edges.enumerated() where !hinges[e] {
            let joined = sets.union(edge.a, edge.b)
            #expect(joined, "cuts are acyclic")
        }
        #expect(sets.componentCount == 1, "cuts reach every vertex")
    }

    @Test func primAgreesWithKruskal() throws {
        let mesh = try MyriahedralMesh(Polyhedron.geodesic(frequency: 8))
        let weights = UnfoldingTests.pseudoRandomWeights(mesh.edgeCount, seed: 7)
        var incidence = Array(repeating: [Int](), count: mesh.faceCount)
        for (e, edge) in mesh.topology.edges.enumerated() {
            incidence[edge.leftFace].append(e)
            incidence[edge.rightFace].append(e)
        }
        let kruskal = SpanningTree.maximum(nodeCount: mesh.faceCount, edges: mesh.dualEdges, weights: weights)
        for root in [0, 17, mesh.faceCount - 1] {
            let prim = SpanningTree.prim(nodeCount: mesh.faceCount, edges: mesh.dualEdges, incidence: incidence,
                                         weights: weights, root: root)
            #expect(prim == kruskal)
        }
    }

    @Test func meshKindArguments() {
        for kind in [MeshKind.graticule(step: 2.5), .geodesic(frequency: 40), .platonic(.icosahedron, levels: 4)] {
            #expect(MeshKind(argument: kind.argument) == kind)
        }
        #expect(MeshKind(argument: "platonic:cube") == .platonic(.cube, levels: 0))
        #expect(MeshKind(argument: "bogus:1") == nil)
    }

    @Test func orientationRotatesTheMesh() throws {
        let spec = MeshSpec(.platonic(.icosahedron, levels: 0), orientation: MeshOrientation(alpha: 10, beta: 20, gamma: 30))
        let rotated = spec.build().polyhedron
        let plain = MeshKind.platonic(.icosahedron, levels: 0).build().polyhedron
        let m = spec.orientation.matrix
        for (a, b) in zip(rotated.vertices, plain.vertices) {
            #expect((a - m.apply(b)).length < 1e-12)
        }
        // Rotation keeps lengths.
        #expect(abs(m.apply(Vec3(1, 2, 3)).length - Vec3(1, 2, 3).length) < 1e-12)
    }
}

@Suite("Hexagonal myriahedra")
struct HexagonTests {
    @Test(arguments: [1, 4, 9])
    func hexagonsCloseTheSphere(frequency n: Int) throws {
        let kind = MeshKind.hexagonal(frequency: n)
        let mesh = try MyriahedralMesh(kind.build())
        // One cell per geodesic vertex: twelve pentagons, the rest hexagons.
        #expect(mesh.cellCount == kind.cellCount)
        #expect(mesh.polyhedron.vertexCount - mesh.edgeCount + mesh.faceCount == 2)
        var sizes = [Int: Int]()
        for c in mesh.cells { sizes[c, default: 0] += 1 }
        // Pentagons in 3 triangles, hexagons in 4.
        #expect(sizes.values.filter { $0 == 3 }.count == 12)
        #expect(sizes.values.allSatisfy { $0 == 3 || $0 == 4 })
        for f in 0..<mesh.faceCount { #expect(mesh.frames[f].area > 0) }
        // Cells stay whole whatever the weights.
        let hinges = mesh.hinges(weights: UnfoldingTests.pseudoRandomWeights(mesh.edgeCount))
        for e in hinges.indices where mesh.isInternalEdge[e] { #expect(hinges[e]) }
        #expect(hinges.filter { !$0 }.count == mesh.polyhedron.vertexCount - 1)
        #expect(MeshKind(argument: kind.argument) == kind)
    }
}
