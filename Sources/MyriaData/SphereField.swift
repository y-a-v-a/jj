import Accelerate
import CoreGraphics
import Foundation
import MyriaCore

/// A scalar function on the unit sphere.
public protocol SphereField: Sendable {
    func value(at p: Vec3) -> Double
}

extension SphereField {
    public func value(at p: GeoPoint) -> Double { value(at: p.unitVector) }
}

/// A field given by a closure (analytic fields such as the Sun's elevation).
public struct FunctionField: SphereField {
    let function: @Sendable (Vec3) -> Double

    public init(_ function: @escaping @Sendable (Vec3) -> Double) {
        self.function = function
    }

    public func value(at p: Vec3) -> Double { function(p) }
}

/// An equirectangular raster on the sphere, sampled bilinearly.
///
/// Cell (i, j) is centred at longitude `lon0 + i·dlon`, latitude
/// `lat0 + j·dlat`; values are stored row by row from `j = 0`. Longitudes
/// wrap around; latitudes clamp at the first and last rows.
public struct GridField: SphereField {
    public let width: Int
    public let height: Int
    public let lon0: Double
    public let lat0: Double
    public let dlon: Double
    public let dlat: Double
    public let values: [Float]

    public init(width: Int, height: Int, lon0: Double, lat0: Double, dlon: Double, dlat: Double, values: [Float]) {
        precondition(values.count == width * height, "width × height values")
        self.width = width
        self.height = height
        self.lon0 = lon0
        self.lat0 = lat0
        self.dlon = dlon
        self.dlat = dlat
        self.values = values
    }

    /// A global grid of `width × height` cells, west to east from −180° and
    /// south to north from −90°.
    public init(width: Int, height: Int, values: [Float]) {
        self.init(width: width, height: height, lon0: -180 + 180 / Double(width), lat0: -90 + 90 / Double(height),
                  dlon: 360 / Double(width), dlat: 180 / Double(height), values: values)
    }

    public init(grid: GridFile, layer: Int) {
        let h = grid.header
        self.init(width: h.width, height: h.height, lon0: h.lon0, lat0: h.lat0, dlon: h.dlon, dlat: h.dlat,
                  values: grid.layers[layer])
    }

    /// Samples `f` at every cell centre of a global grid (in parallel).
    public static func sampling(width: Int, height: Int, _ f: @Sendable (GeoPoint) -> Double) -> GridField {
        let template = GridField(width: width, height: height, values: [Float](repeating: 0, count: width * height))
        let rows = parallelMap(height) { j in
            (0..<width).map { i in Float(f(template.cellCenter(i, j))) }
        }
        return GridField(width: width, height: height, values: rows.flatMap { $0 })
    }

    public func cellCenter(_ i: Int, _ j: Int) -> GeoPoint {
        GeoPoint(latitude: lat0 + Double(j) * dlat, longitude: Spherical.normalizeLongitude(lon0 + Double(i) * dlon))
    }

    public subscript(i: Int, j: Int) -> Float { values[j * width + i] }

    public func value(at p: Vec3) -> Double {
        let g = GeoPoint(p)
        return value(latitude: g.latitude, longitude: g.longitude)
    }

    /// Bilinear interpolation; NaN cells are left out of the average.
    public func value(latitude: Double, longitude: Double) -> Double {
        var x = (longitude - lon0) / dlon
        x -= (x / Double(width)).rounded(.down) * Double(width)
        let y = min(max((latitude - lat0) / dlat, 0), Double(height - 1))
        let i0 = Int(x) % width, i1 = (i0 + 1) % width
        let j0 = Int(y), j1 = min(j0 + 1, height - 1)
        let fx = x - x.rounded(.down), fy = y - Double(j0)
        var sum = 0.0, weight = 0.0
        for (i, j, w) in [(i0, j0, (1 - fx) * (1 - fy)), (i1, j0, fx * (1 - fy)), (i0, j1, (1 - fx) * fy), (i1, j1, fx * fy)] {
            let v = values[j * width + i]
            if !v.isNaN, w > 0 {
                sum += Double(v) * w
                weight += w
            }
        }
        return weight > 0 ? sum / weight : .nan
    }

    /// Smallest and largest finite value.
    public var range: ClosedRange<Double> {
        var lo = Float.infinity, hi = -Float.infinity
        for v in values where v.isFinite {
            lo = min(lo, v)
            hi = max(hi, v)
        }
        return lo <= hi ? Double(lo)...Double(hi) : 0...0
    }

    /// The value at quantile `q` (0...1) of the finite values, area-weighted
    /// by the cosine of latitude.
    public func quantile(_ q: Double) -> Double {
        var pairs: [(Float, Double)] = []
        pairs.reserveCapacity(values.count)
        for j in 0..<height {
            let w = cos((lat0 + Double(j) * dlat) * .pi / 180)
            for i in 0..<width where values[j * width + i].isFinite {
                pairs.append((values[j * width + i], max(w, 0)))
            }
        }
        guard !pairs.isEmpty else { return 0 }
        pairs.sort { $0.0 < $1.0 }
        let total = pairs.reduce(0) { $0 + $1.1 }
        var acc = 0.0
        for (v, w) in pairs {
            acc += w
            if acc >= q * total { return Double(v) }
        }
        return Double(pairs.last!.0)
    }

    /// Several quantiles at once, sorting once: of the finite values that
    /// `include` keeps, area-weighted by the cosine of latitude.
    public func quantiles(_ qs: [Double], where include: (Float) -> Bool = { _ in true }) -> [Double] {
        var pairs: [(Float, Double)] = []
        pairs.reserveCapacity(values.count)
        for j in 0..<height {
            let w = max(cos((lat0 + Double(j) * dlat) * .pi / 180), 0)
            for i in 0..<width where values[j * width + i].isFinite && include(values[j * width + i]) {
                pairs.append((values[j * width + i], w))
            }
        }
        guard !pairs.isEmpty else { return qs.map { _ in 0 } }
        pairs.sort { $0.0 < $1.0 }
        let total = pairs.reduce(0) { $0 + $1.1 }
        var out = [Double](repeating: Double(pairs.last!.0), count: qs.count)
        let order = qs.indices.sorted { qs[$0] < qs[$1] }
        var acc = 0.0, k = 0
        for (v, w) in pairs {
            acc += w
            while k < order.count, acc >= qs[order[k]] * total {
                out[order[k]] = Double(v)
                k += 1
            }
            if k == order.count { break }
        }
        return out
    }

    public func mapValues(_ transform: (Float) -> Float) -> GridField {
        GridField(width: width, height: height, lon0: lon0, lat0: lat0, dlon: dlon, dlat: dlat, values: values.map(transform))
    }

    /// Resamples another field onto this grid's cell centres.
    public static func resampling(_ field: some SphereField, width: Int, height: Int) -> GridField {
        sampling(width: width, height: height) { field.value(at: $0.unitVector) }
    }
}

// MARK: - Rasterisation

extension GridField {
    /// Fraction of every cell covered by polygons given as (longitude,
    /// latitude) rings, filled even–odd, rasterised with Core Graphics
    /// antialiasing at `supersample`× resolution.
    public static func coverage(rings: [[Vec2]], width: Int, height: Int, supersample: Int = 4) -> GridField {
        let w = width * supersample, h = height * supersample
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            ctx.setShouldAntialias(true)
            ctx.setFillColor(gray: 1, alpha: 1)
            let path = CGMutablePath()
            for ring in rings where ring.count >= 3 {
                path.addLines(between: ring.map { CGPoint(x: ($0.x + 180) / 360 * Double(w), y: ($0.y + 90) / 180 * Double(h)) })
                path.closeSubpath()
            }
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
        }
        // Core Graphics rows run top to bottom in memory: row 0 is the north.
        var values = [Float](repeating: 0, count: width * height)
        let norm = Float(255 * supersample * supersample)
        for j in 0..<height {
            for i in 0..<width {
                var sum = 0
                for sy in 0..<supersample {
                    let row = h - 1 - (j * supersample + sy)
                    for sx in 0..<supersample { sum += Int(pixels[row * w + i * supersample + sx]) }
                }
                values[j * width + i] = Float(sum) / norm
            }
        }
        return GridField(width: width, height: height, values: values)
    }
}

// MARK: - Smoothing and densities

extension GridField {
    /// Van Wijk's convolution of a raster R with a Gaussian on the sphere
    /// (Unfolding the Earth, 2008, section "Geography aligned meshes"):
    ///
    ///     F_ij = Σ_k Σ_l m_jkl R_(i+k, j+l)
    ///     s_jkl = a_(j+l) exp(−r_jkl² / 2σ²) / (√(2π) σ),  a_l ∝ cos φ_l
    ///     r_jkl = arccos[p(φ_j, 0) · p(φ_(j+l), λ_k)]
    ///
    /// with the mask normalised to sum to one. The mask spans `halfRows`
    /// rows either way and, per row, ⌈I·L / (2J cos φ_j)⌉ columns, so its
    /// footprint is round on the sphere. Requires a global grid.
    /// - Parameter sigma: standard deviation in degrees of arc.
    public func sphericalGaussian(sigma: Double, halfRows: Int? = nil) -> GridField {
        let I = width, J = height
        let L = halfRows ?? min(J / 2, Int((3 * sigma / dlat).rounded(.up)))
        let s = sigma * .pi / 180
        let lat = (0..<J).map { (lat0 + Double($0) * dlat) * .pi / 180 }
        let lonStep = dlon * .pi / 180
        let source = values.map { $0.isNaN ? 0 : $0 }
        let rows: [[Float]] = parallelMap(J) { j in
            let K = min(I / 2, Int((Double(I * L) / (2 * Double(J) * max(cos(lat[j]), 1e-6))).rounded(.up)))
            let center = GeoPoint(latitude: lat[j] * 180 / .pi, longitude: 0).unitVector
            var out = [Float](repeating: 0, count: I)
            var padded = [Float](repeating: 0, count: I + 2 * K)
            var mask = [Float](repeating: 0, count: 2 * K + 1)
            var term = [Float](repeating: 0, count: I)
            var total = 0.0
            for l in max(-j, -L)...min(J - 1 - j, L) {
                // Mask weights for source row j + l: area × Gaussian of the
                // great-circle distance, symmetric in k.
                let phi = lat[j + l]
                let area = cos(phi)
                var any = false
                for k in -K...K {
                    let lambda = Double(k) * lonStep
                    let p = Vec3(cos(phi) * cos(lambda), cos(phi) * sin(lambda), sin(phi))
                    let r = acos(min(1, max(-1, center.dot(p))))
                    let w = area * exp(-r * r / (2 * s * s))
                    mask[k + K] = Float(w)
                    total += w
                    any = any || w > 1e-9
                }
                guard any else { continue }
                // Circular convolution along the row: pad with wrapped columns.
                let row = (j + l) * I
                source.withUnsafeBufferPointer { src in
                    padded.withUnsafeMutableBufferPointer { pad in
                        for k in 0..<K {
                            pad[k] = src[row + I - K + k]
                            pad[K + I + k] = src[row + k]
                        }
                        for i in 0..<I { pad[K + i] = src[row + i] }
                    }
                }
                vDSP_conv(padded, 1, mask, 1, &term, 1, vDSP_Length(I), vDSP_Length(2 * K + 1))
                vDSP_vadd(out, 1, term, 1, &out, 1, vDSP_Length(I))
            }
            var scale = Float(1 / total)
            vDSP_vsmul(out, 1, &scale, &out, 1, vDSP_Length(I))
            return out
        }
        return GridField(width: width, height: height, lon0: lon0, lat0: lat0, dlon: dlon, dlat: dlat, values: rows.flatMap { $0 })
    }

    /// Kernel density of weighted points on a global grid: the sum of
    /// spherical Gaussians (σ in degrees) per square kilometre on a sphere
    /// of `radius` km.
    public static func density(points: [(GeoPoint, Double)], width: Int, height: Int, sigma: Double,
                               radius: Double = 6371) -> GridField {
        let template = GridField(width: width, height: height, values: [Float](repeating: 0, count: width * height))
        let s = sigma * .pi / 180
        let norm = 1 / (2 * Double.pi * s * s * radius * radius)
        let reach = 3 * sigma
        // Bucket points by row so each row only looks at nearby points.
        var byRow = Array(repeating: [(GeoPoint, Vec3, Double)](), count: height)
        for (p, w) in points {
            let j0 = max(0, Int(((p.latitude - reach) - template.lat0) / template.dlat) - 1)
            let j1 = min(height - 1, Int(((p.latitude + reach) - template.lat0) / template.dlat) + 1)
            guard j0 <= j1 else { continue }
            for j in j0...j1 { byRow[j].append((p, p.unitVector, w)) }
        }
        let cosReach = cos(reach * .pi / 180)
        let bands = byRow
        let rows: [[Float]] = parallelMap(height) { j in
            var out = [Float](repeating: 0, count: width)
            let latitude = template.lat0 + Double(j) * template.dlat
            let rowCenters = (0..<width).map { template.cellCenter($0, j).unitVector }
            for (g, p, w) in bands[j] {
                // Columns within reach of the point along this row.
                let c = max(cos(max(abs(latitude), abs(g.latitude)) * .pi / 180), 1e-6)
                let span = min(Double(width) / 2, (reach / c) / template.dlon + 1)
                let ic = (g.longitude - template.lon0) / template.dlon
                let i0 = Int((ic - span).rounded(.down)), i1 = Int((ic + span).rounded(.up))
                for k in i0...max(i0, min(i1, i0 + width - 1)) {
                    let i = ((k % width) + width) % width
                    let d = rowCenters[i].dot(p)
                    guard d > cosReach else { continue }
                    let r = acos(min(1, d))
                    out[i] += Float(w * exp(-r * r / (2 * s * s)) * norm)
                }
            }
            return out
        }
        return GridField(width: width, height: height, values: rows.flatMap { $0 })
    }
}
