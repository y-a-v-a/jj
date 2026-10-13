import Foundation

/// The five regular polyhedra, the starting points of van Wijk's recursively
/// subdivided myriahedra (2008, figures 5 and 8).
public enum PlatonicSolid: String, CaseIterable, Hashable, Sendable, Codable {
    case tetrahedron, cube, octahedron, dodecahedron, icosahedron

    public var title: String {
        switch self {
        case .tetrahedron: "Tetrahedron"
        case .cube: "Cube"
        case .octahedron: "Octahedron"
        case .dodecahedron: "Dodecahedron"
        case .icosahedron: "Icosahedron"
        }
    }

    public var faceCount: Int {
        switch self {
        case .tetrahedron: 4
        case .cube: 6
        case .octahedron: 8
        case .dodecahedron: 12
        case .icosahedron: 20
        }
    }

    /// The solid inscribed in the unit sphere, faces counter-clockwise from outside.
    public func polyhedron() -> Polyhedron {
        let phi = (1 + 5.0.squareRoot()) / 2
        switch self {
        case .tetrahedron:
            let v = [Vec3(1, 1, 1), Vec3(1, -1, -1), Vec3(-1, 1, -1), Vec3(-1, -1, 1)]
            return Polyhedron.convexHull(vertices: v, faceNormals: v.map { -$0 })
        case .cube:
            var v: [Vec3] = []
            for x in [-1.0, 1] { for y in [-1.0, 1] { for z in [-1.0, 1] { v.append(Vec3(x, y, z)) } } }
            let normals = [Vec3.unitX, -Vec3.unitX, .unitY, -Vec3.unitY, .unitZ, -Vec3.unitZ]
            return Polyhedron.convexHull(vertices: v, faceNormals: normals)
        case .octahedron:
            let v = [Vec3.unitX, -Vec3.unitX, .unitY, -Vec3.unitY, .unitZ, -Vec3.unitZ]
            var normals: [Vec3] = []
            for x in [-1.0, 1] { for y in [-1.0, 1] { for z in [-1.0, 1] { normals.append(Vec3(x, y, z)) } } }
            return Polyhedron.convexHull(vertices: v, faceNormals: normals)
        case .dodecahedron:
            var v: [Vec3] = []
            for x in [-1.0, 1] { for y in [-1.0, 1] { for z in [-1.0, 1] { v.append(Vec3(x, y, z)) } } }
            for a in [-1.0, 1] {
                for b in [-1.0, 1] {
                    v.append(Vec3(0, a / phi, b * phi))
                    v.append(Vec3(a / phi, b * phi, 0))
                    v.append(Vec3(a * phi, 0, b / phi))
                }
            }
            // Face normals point at the vertices of the dual icosahedron.
            var normals: [Vec3] = []
            for a in [-1.0, 1] {
                for b in [-1.0, 1] {
                    normals.append(Vec3(0, a * phi, b))
                    normals.append(Vec3(a * phi, b, 0))
                    normals.append(Vec3(a, 0, b * phi))
                }
            }
            return Polyhedron.convexHull(vertices: v, faceNormals: normals)
        case .icosahedron:
            return Polyhedron.icosahedron()
        }
    }
}

extension Polyhedron {
    /// A convex polyhedron from its vertices and the directions of its face
    /// normals: each face holds the vertices furthest along its normal,
    /// ordered counter-clockwise around it.
    public static func convexHull(vertices: [Vec3], faceNormals: [Vec3]) -> Polyhedron {
        let unit = vertices.map(\.normalized)
        let faces: [[Int]] = faceNormals.map { normal in
            let n = normal.normalized
            let top = unit.map { $0.dot(n) }.max()!
            let members = unit.indices.filter { unit[$0].dot(n) > top - 1e-9 }
            let (east, north) = Spherical.tangentFrame(at: n)
            return members.sorted { a, b in
                atan2(unit[a].dot(north), unit[a].dot(east)) < atan2(unit[b].dot(north), unit[b].dot(east))
            }
        }
        return Polyhedron(vertices: unit, faces: faces)
    }

    /// The polyhedron with every vertex rotated by `rotation`.
    public func rotated(by rotation: Mat3) -> Polyhedron {
        var copy = self
        copy.vertices = vertices.map { rotation.apply($0) }
        return copy
    }
}
