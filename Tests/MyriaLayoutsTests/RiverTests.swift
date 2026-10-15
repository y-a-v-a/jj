import Foundation
import Testing
import MyriaCore
import MyriaData
@testable import MyriaLayouts

/// How a cut treats the rivers. Along every river a point is set on each
/// bank, a little over half a face away; the river is cut there when the
/// straight way from bank to bank crosses a cut, and open by as much as the
/// two points lie further apart on the map than on the globe.
struct RiverSeams {
    /// Bank pairs on land that lie in different faces.
    var samples = 0
    /// Of those, the ones whose banks a cut separates.
    var cut = 0
    /// Gap between the banks on the map, km, per sample.
    var gaps: [Double] = []
    /// Length (km) of cut edges between land faces whose two sides lie
    /// further apart than `openGap` on the map, along rivers and elsewhere.
    var openAlongRivers = 0.0
    var openElsewhere = 0.0

    static let openGap = 50.0

    var cutShare: Double { Double(cut) / Double(max(samples, 1)) }
    func openShare(over km: Double = openGap) -> Double { Double(gaps.filter { $0 > km }.count) / Double(max(samples, 1)) }
    var medianGap: Double { gaps.sorted()[gaps.count / 2] }
    /// Share of the land's open seams that follow a river.
    var precision: Double { openAlongRivers / max(openAlongRivers + openElsewhere, 1e-9) }

    init(_ context: LayoutContext, _ cut: LayoutCut, rank: Int) throws {
        let mesh = context.mesh
        let projection = MyriahedralProjection(mesh: mesh, hinges: cut.hinges, root: cut.root)
        let radius = context.data.body.radius
        let typical = (4 * Double.pi / Double(mesh.faceCount)).squareRoot()
        let land = try context.landFraction()
        let lines = try context.data.lines(.rivers).lines.filter { $0.attribute <= rank }
        var riverPoints: [Vec3] = []

        for line in lines {
            let v = line.points.map(\.unitVector)
            for i in 0..<(v.count - 1) {
                let a = v[i], b = v[i + 1]
                let n = max(1, Int((a.angle(to: b) / (typical / 4)).rounded(.up)))
                for k in 0..<n {
                    let q = Spherical.slerp(a, b, (Double(k) + 0.5) / Double(n))
                    riverPoints.append(q)
                    guard k % 2 == 0 else { continue }
                    let along = b - a
                    let tangent = (along - q * along.dot(q)).normalized
                    let normal = q.cross(tangent)
                    let left = (q + normal * (0.6 * typical)).normalized
                    let right = (q - normal * (0.6 * typical)).normalized
                    let fl = mesh.face(containing: left), fr = mesh.face(containing: right)
                    guard fl != fr, land[fl] >= 0.5, land[fr] >= 0.5 else { continue }
                    samples += 1
                    var last = fl, separated = false
                    for s in 1...24 {
                        let f = mesh.face(containing: Spherical.slerp(left, right, Double(s) / 24))
                        if f != last, let e = context.edge(between: last, f), !cut.hinges[e] { separated = true }
                        last = f
                    }
                    if separated { self.cut += 1 }
                    if let pl = projection.project(left, through: fl), let pr = projection.project(right, through: fr) {
                        gaps.append(max(0, (pl - pr).length - left.angle(to: right)) * radius)
                    }
                }
            }
        }

        let rivers = PointIndex(riverPoints)
        for e in projection.cutEdges {
            let edge = mesh.topology.edges[e]
            guard land[edge.leftFace] >= 0.5, land[edge.rightFace] >= 0.5 else { continue }
            let sides = projection.mapSegments(ofEdge: e)
            let gap = max((sides[0].0 - sides[1].0).length, (sides[0].1 - sides[1].1).length) * radius
            guard gap > Self.openGap else { continue }
            let length = context.edges[e].length * radius
            let near = rivers.nearest(to: context.edges[e].midpoint).map { $0.distance < 1.5 * typical } ?? false
            if near { openAlongRivers += length } else { openElsewhere += length }
        }
    }

    var summary: String {
        String(format: "%d samples · cut %.0f%% · open >%.0f km %.0f%% (median gap %.0f km) · open land seams along rivers %.0f%% (%.0f of %.0f km)",
               samples, 100 * cutShare, Self.openGap, 100 * openShare(), medianGap, 100 * precision,
               openAlongRivers, openAlongRivers + openElsewhere)
    }
}

extension RiverSeams {
    /// Gap (km) between the banks a fraction of the way from a river's
    /// source to its mouth, for the longest line of that name.
    static func gap(_ context: LayoutContext, _ cut: LayoutCut, river name: String, at fraction: Double) throws -> Double {
        let mesh = context.mesh
        let projection = MyriahedralProjection(mesh: mesh, hinges: cut.hinges, root: cut.root)
        let typical = (4 * Double.pi / Double(mesh.faceCount)).squareRoot()
        let coast = try RiverLayout().coastIndex(context.data)
        let line = try #require(try context.data.lines(.rivers).lines.filter { $0.name == name }.max { $0.points.count < $1.points.count })
        var v = line.points.map(\.unitVector)
        if coast.distance(to: v[0])! < coast.distance(to: v[v.count - 1])! { v.reverse() }
        // The widest gap over a stretch of a twentieth of the river.
        var widest = 0.0
        let range = max(0, Int((fraction - 0.05) * Double(v.count - 1)))...min(v.count - 2, Int((fraction + 0.05) * Double(v.count - 1)))
        for i in range {
            let q = Spherical.slerp(v[i], v[i + 1], 0.5)
            let along = v[i + 1] - v[i]
            let normal = q.cross((along - q * along.dot(q)).normalized)
            let left = (q + normal * typical).normalized, right = (q - normal * typical).normalized
            guard let pl = projection.project(left, through: mesh.face(containing: left)),
                  let pr = projection.project(right, through: mesh.face(containing: right)) else { continue }
            widest = max(widest, ((pl - pr).length - left.angle(to: right)) * context.data.body.radius)
        }
        return widest
    }
}

@Suite("Rivers become seams")
struct RiverTests {
    /// The rivers are cut, and nearly every seam that opens on land is a river.
    @Test(arguments: [MeshKind.graticule(step: 1), .geodesic(frequency: 64)])
    func riversAreTheSeams(mesh: MeshKind) throws {
        let (context, cut) = try Shared.cut("rivers", mesh: mesh)
        let seams = try RiverSeams(context, cut, rank: 4)
        #expect(seams.cutShare > 0.9, "\(seams.summary)")
        #expect(seams.precision > 0.85, "\(seams.summary)")
    }

    /// Each river hangs from its own mouth, so it opens by the curvature of
    /// its whole basin: shut near its source, widest at the sea.
    @Test(arguments: ["Amazonas", "Congo", "Mississippi"])
    func greatRiversOpenTowardTheSea(river: String) throws {
        let (context, cut) = try Shared.cut("rivers", mesh: .graticule(step: 1))
        let upstream = try RiverSeams.gap(context, cut, river: river, at: 0.2)
        let mouth = try RiverSeams.gap(context, cut, river: river, at: 0.9)
        #expect(mouth > 80, "\(river) opens \(Int(mouth)) km near its mouth")
        #expect(mouth > 2 * upstream + 20, "\(river): \(Int(upstream)) km upstream, \(Int(mouth)) km near the mouth")
    }

    /// At 1° the Mediterranean and the Black Sea are closed off. Unless they
    /// reach the ocean across their straits, all the land hanging from their
    /// shores tears Europe open along the Danube.
    @Test func europeHoldsTogether() throws {
        let (context, cut) = try Shared.cut("rivers", mesh: .graticule(step: 1))
        let crossings = RiverLayout().straits(context, land: try landAndSeaLabels(context, minimum: 6).isLand)
        let gibraltar = GeoPoint(latitude: 36, longitude: -5.5).unitVector
        #expect(crossings.indices.contains { crossings[$0] && context.edges[$0].midpoint.angle(to: gibraltar) < 0.03 })
        for fraction in [0.2, 0.5] {
            let gap = try RiverSeams.gap(context, cut, river: "Danube", at: fraction)
            #expect(gap < 50, "the Danube opens \(Int(gap)) km")
        }
    }

    @Test func littleOverlap() throws {
        let (context, cut) = try Shared.cut("rivers", mesh: .graticule(step: 1))
        let projection = MyriahedralProjection(mesh: context.mesh, hinges: cut.hinges, root: cut.root)
        #expect(projection.overlapFraction() < 0.01)
    }
}
