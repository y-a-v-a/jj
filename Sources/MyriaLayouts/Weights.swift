import Foundation
import MyriaCore

/// Building blocks for edge weights. A maximum spanning tree keeps heavy
/// edges as hinges, so cuts fall where weights are low. Van Wijk: "edges
/// aligned with contours of w typically turn into folds, whereas edges
/// aligned with gradients of w turn into cuts."
public enum Weights {
    /// Van Wijk's graticular weight (2008, section "Graticules"):
    ///
    ///     w(φ, λ) = −(W_φ |φ − φ₀| + W_λ min_k |λ − λ₀ + 2πk|)
    ///
    /// evaluated at each edge's midpoint, angles in radians. A high W_φ cuts
    /// along meridians (φ₀ = 0° cylindrical, 25° conical, 90° azimuthal; a
    /// negative W_φ two hemispheres); a high W_λ cuts along parallels
    /// (polyconic).
    public static func graticule(_ edges: [EdgeInfo], phi0: Double, lambda0: Double, wPhi: Double, wLambda: Double) -> [Double] {
        let r = Double.pi / 180
        return edges.map { e in
            let g = GeoPoint(e.midpoint)
            let dPhi = abs(g.latitude - phi0) * r
            let dLambda = abs(Spherical.longitudeDelta(lambda0, g.longitude)) * r
            return -(wPhi * dPhi + wLambda * dLambda)
        }
    }

    /// Great-circle distance (radians) from `center` to each edge midpoint.
    public static func distance(from center: Vec3, _ edges: [EdgeInfo]) -> [Double] {
        edges.map { center.angle(to: $0.midpoint) }
    }

    /// Deterministic noise in [0, 1) per edge.
    public static func noise(count: Int, seed: UInt64) -> [Double] {
        (0..<count).map { i in
            var z = UInt64(i) &+ seed &* 0x9E3779B97F4A7C15
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
    }

    /// `a + s·b`, elementwise.
    public static func add(_ a: [Double], _ b: [Double], scale s: Double = 1) -> [Double] {
        zip(a, b).map { $0 + s * $1 }
    }

    /// Rescales finite values to 0…1 (constant input becomes 0).
    public static func normalized(_ w: [Double]) -> [Double] {
        let finite = w.filter(\.isFinite)
        guard let lo = finite.min(), let hi = finite.max(), hi > lo else { return w.map { _ in 0 } }
        return w.map { $0.isFinite ? ($0 - lo) / (hi - lo) : 0 }
    }

    /// The root face for a layout centred on a location.
    public static func root(_ context: LayoutContext, latitude: Double = 0, longitude: Double) -> Int {
        context.face(at: GeoPoint(latitude: latitude, longitude: longitude))
    }
}
