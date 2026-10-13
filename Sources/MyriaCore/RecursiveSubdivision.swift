import Foundation

/// Recursive subdivision of a polyhedron with van Wijk's edge weights
/// (Unfolding the Earth, 2008, section "Recursive subdivision").
///
/// At each level every edge is split at its great-circle midpoint and the
/// midpoints are connected: a triangle becomes four triangles, a quad four
/// quads (through its centre) and a pentagon five quads. Every edge carries
/// three numbers: w0 and w1 at its ends and wc at its centre. New edges at
/// level i get w0 = w1 = i and wc = i + 1; an edge split into e′ and e″
/// interpolates linearly:
///
///     e′: w0 ← w0, w1 ← wc, wc ← (w0 + wc) / 2
///     e″: w0 ← wc, w1 ← w1, wc ← (wc + w1) / 2
///
/// The final edges are weighted by wc, so weights are highest near the
/// centres of the original edges and cuts radiate from the original vertices.
public enum RecursiveSubdivision {
    struct EdgeWeights {
        /// Weight at the lower-indexed vertex, at the higher one, and at the centre.
        var lo: Double
        var hi: Double
        var center: Double
    }

    public static func build(_ base: Polyhedron, levels: Int) -> MeshBuild {
        var vertices = base.vertices
        var faces = base.faces
        var weights: [UInt64: EdgeWeights] = [:]
        for face in faces {
            for i in face.indices {
                weights[EdgeKey.make(face[i], face[(i + 1) % face.count])] = EdgeWeights(lo: 0, hi: 0, center: 1)
            }
        }

        for level in 1...max(levels, 1) where levels > 0 {
            var midpoints: [UInt64: Int] = [:]
            var next: [UInt64: EdgeWeights] = [:]
            func midpoint(_ a: Int, _ b: Int) -> Int {
                let key = EdgeKey.make(a, b)
                if let m = midpoints[key] { return m }
                vertices.append((vertices[a] + vertices[b]).normalized)
                let m = vertices.count - 1
                midpoints[key] = m
                let w = weights[key] ?? EdgeWeights(lo: Double(level - 1), hi: Double(level - 1), center: Double(level))
                let (lo, hi) = (min(a, b), max(a, b))
                // The midpoint has the highest index, so in both halves the
                // old vertex is the lower end: lo–m gets (w_lo, w_c), hi–m (w_hi, w_c).
                next[EdgeKey.make(lo, m)] = EdgeWeights(lo: w.lo, hi: w.center, center: (w.lo + w.center) / 2)
                next[EdgeKey.make(hi, m)] = EdgeWeights(lo: w.hi, hi: w.center, center: (w.center + w.hi) / 2)
                return m
            }
            func newEdge(_ a: Int, _ b: Int) {
                next[EdgeKey.make(a, b)] = EdgeWeights(lo: Double(level), hi: Double(level), center: Double(level + 1))
            }
            var subdivided: [[Int]] = []
            subdivided.reserveCapacity(faces.count * 4)
            for face in faces {
                let n = face.count
                let mids = (0..<n).map { midpoint(face[$0], face[($0 + 1) % n]) }
                if n == 3 {
                    let (a, b, c) = (face[0], face[1], face[2])
                    let (ab, bc, ca) = (mids[0], mids[1], mids[2])
                    subdivided += [[a, ab, ca], [ab, b, bc], [ca, bc, c], [ab, bc, ca]]
                    newEdge(ab, bc); newEdge(bc, ca); newEdge(ca, ab)
                } else {
                    // Quads and pentagons: one quad per corner, through the centre.
                    vertices.append(face.reduce(Vec3.zero) { $0 + vertices[$1] }.normalized)
                    let center = vertices.count - 1
                    for k in 0..<n {
                        subdivided.append([face[k], mids[k], center, mids[(k + n - 1) % n]])
                        newEdge(mids[k], center)
                    }
                }
            }
            faces = subdivided
            weights = next
        }

        // Faces that are not planar become triangle fans of one cell.
        var finalFaces: [[Int]] = []
        var cells: [Int] = []
        for (cell, face) in faces.enumerated() {
            if face.count == 3 || isPlanar(face.map { vertices[$0] }) {
                finalFaces.append(face)
                cells.append(cell)
            } else {
                for k in 1..<(face.count - 1) {
                    finalFaces.append([face[0], face[k], face[k + 1]])
                    cells.append(cell)
                }
            }
        }
        return MeshBuild(polyhedron: Polyhedron(vertices: vertices, faces: finalFaces), cells: cells,
                         edgeWeights: weights.mapValues(\.center))
    }

    static func isPlanar(_ pts: [Vec3]) -> Bool {
        let n = Polyhedron.newellNormal(pts).normalized
        let d = pts.reduce(0) { $0 + n.dot($1) } / Double(pts.count)
        let scale = (pts[0] - pts[1]).length
        return pts.allSatisfy { abs(n.dot($0) - d) < 1e-9 * max(scale, 1e-12) }
    }
}
