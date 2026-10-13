import Foundation

/// An sRGB colour with alpha, components in 0...1.
public struct RGBA: Hashable, Sendable, Codable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// From "#rrggbb".
    public init(hex: String, alpha: Double = 1) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let v = UInt32(s, radix: 16) ?? 0
        self.init(Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255, alpha)
    }

    public static let black = RGBA(0, 0, 0)
    public static let white = RGBA(1, 1, 1)
    public static let clear = RGBA(0, 0, 0, 0)

    public var hex: String {
        String(format: "#%02x%02x%02x", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    public func withAlpha(_ alpha: Double) -> RGBA { RGBA(r, g, b, alpha) }

    /// Linear blend towards `other` by `t` (0 keeps self).
    public func mixed(with other: RGBA, _ t: Double) -> RGBA {
        RGBA(r + (other.r - r) * t, g + (other.g - g) * t, b + (other.b - b) * t, a + (other.a - a) * t)
    }

    /// `self` painted over an opaque `background`, honouring alpha.
    public func composited(over background: RGBA) -> RGBA {
        RGBA(r * a + background.r * (1 - a), g * a + background.g * (1 - a), b * a + background.b * (1 - a))
    }

    /// WCAG relative luminance (alpha ignored).
    public var relativeLuminance: Double {
        0.2126 * Self.linear(r) + 0.7152 * Self.linear(g) + 0.0722 * Self.linear(b)
    }

    /// WCAG contrast ratio, 1...21.
    public func contrastRatio(with other: RGBA) -> Double {
        let (x, y) = (relativeLuminance, other.relativeLuminance)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    static func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func gamma(_ c: Double) -> Double {
        let v = min(max(c, 0), 1)
        return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    /// OKLab coordinates (L, a, b), alpha ignored.
    public var oklab: (l: Double, a: Double, b: Double) {
        let (lr, lg, lb) = (Self.linear(r), Self.linear(g), Self.linear(b))
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    public init(oklab l: Double, _ a: Double, _ b: Double, alpha: Double = 1) {
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let (l3, m3, s3) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)
        self.init(Self.gamma(4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3),
                  Self.gamma(-1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3),
                  Self.gamma(-0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3), alpha)
    }

    /// Perceptual blend in OKLab.
    public func perceptualMix(with other: RGBA, _ t: Double) -> RGBA {
        let (p, q) = (oklab, other.oklab)
        return RGBA(oklab: p.l + (q.l - p.l) * t, p.a + (q.a - p.a) * t, p.b + (q.b - p.b) * t, alpha: a + (other.a - a) * t)
    }

    /// Perceptual difference: Euclidean OKLab distance ×100 (black to
    /// white is 100; below about 5 neighbours start to look alike).
    public func perceptualDistance(to other: RGBA) -> Double {
        let (p, q) = (oklab, other.oklab)
        return 100 * ((p.l - q.l) * (p.l - q.l) + (p.a - q.a) * (p.a - q.a) + (p.b - q.b) * (p.b - q.b)).squareRoot()
    }
}

/// A colour scale: colours at evenly spaced stops, blended in OKLab.
public struct Colormap: Hashable, Sendable {
    public let stops: [RGBA]

    public init(_ stops: [RGBA]) {
        precondition(stops.count >= 2, "a colormap needs two stops")
        self.stops = stops
    }

    public init(hex: [String]) {
        self.init(hex.map { RGBA(hex: $0) })
    }

    /// The colour at `t` in 0...1.
    public func color(at t: Double) -> RGBA {
        let x = min(max(t.isFinite ? t : 0, 0), 1) * Double(stops.count - 1)
        let i = min(Int(x), stops.count - 2)
        return stops[i].perceptualMix(with: stops[i + 1], x - Double(i))
    }

    /// `count` colours sampled evenly, for lookup tables.
    public func table(_ count: Int = 256) -> [RGBA] {
        (0..<count).map { color(at: Double($0) / Double(count - 1)) }
    }

    public var reversed: Colormap { Colormap(stops.reversed()) }
}
