import Foundation
import MyriaCore

extension DatasetID {
    /// Named surface features: craters, maria, mountains (IAU nomenclature).
    public static let features: DatasetID = "features"
}

/// A named feature on a body's surface.
public struct SurfaceFeature: Sendable, Hashable, Codable {
    public let name: String
    public let type: String
    public let lat: Double
    public let lon: Double
    /// Diameter in kilometres.
    public let diameter: Double

    public var location: GeoPoint { GeoPoint(latitude: lat, longitude: lon) }
}

public struct FeatureSet: Sendable {
    /// Largest first.
    public let features: [SurfaceFeature]
    let index: PointIndex

    public init(features: [SurfaceFeature]) {
        self.features = features.sorted { $0.diameter > $1.diameter }
        index = PointIndex(self.features.map(\.location.unitVector))
    }

    public init(contentsOf url: URL) throws {
        self.init(features: try JSONDecoder().decode([SurfaceFeature].self, from: Data(contentsOf: url)))
    }

    /// The feature whose centre is nearest to `p`, with the distance in radians.
    public func nearest(to p: Vec3) -> (feature: SurfaceFeature, distance: Double)? {
        index.nearest(to: p).map { (features[$0.index], $0.distance) }
    }
}

extension BodyData {
    public func features() throws -> FeatureSet {
        try cached("dataset:features") { try FeatureSet(contentsOf: url(of: .features)) }
    }
}

/// Colours for a body's relief, low to high, as "#rrggbb" stops; used
/// instead of a palette's land and sea tints for bodies without seas.
public struct ReliefTint: Sendable, Hashable {
    public let stops: [String]
    public init(_ stops: [String]) { self.stops = stops }
}

extension Body {
    /// The Moon: LRO LOLA topography and the IAU's named features.
    public static let moon = Body(
        id: "moon", name: "Moon", radius: 1737.4, resourceFolder: "Moon",
        datasets: [
            DatasetDescriptor(id: .elevation, kind: .grid, file: "elevation.grid", title: "Elevation",
                              attribution: "LRO LOLA gridded topography (NASA PDS, public domain)"),
            DatasetDescriptor(id: .features, kind: .places, file: "features.json", title: "Named features",
                              attribution: "Gazetteer of Planetary Nomenclature (IAU WGPSN, USGS Astrogeology)"),
        ],
        fields: [CommonFields.elevation, CommonFields.highlands, CommonFields.craters],
        relief: ReliefTint(["#2b2b2e", "#4a4a4f", "#77777c", "#a3a3a6", "#cfcfcf", "#f1f1ee"]),
        hasSeas: false, hasSunlight: true)

    /// Mars: MGS MOLA topography and the IAU's named features.
    public static let mars = Body(
        id: "mars", name: "Mars", radius: 3389.5, resourceFolder: "Mars",
        datasets: [
            DatasetDescriptor(id: .elevation, kind: .grid, file: "elevation.grid", title: "Elevation",
                              attribution: "MGS MOLA MEGDR topography (NASA PDS, public domain)"),
            DatasetDescriptor(id: .features, kind: .places, file: "features.json", title: "Named features",
                              attribution: "Gazetteer of Planetary Nomenclature (IAU WGPSN, USGS Astrogeology)"),
        ],
        fields: [CommonFields.elevation, CommonFields.highlands, CommonFields.craters],
        relief: ReliefTint(["#3b1d14", "#6b2f1d", "#9a4a2a", "#c2703f", "#d99a63", "#ecc79a", "#f6e7d0"]),
        hasSeas: false, hasSunlight: true)

    /// Every body JJ knows, Earth first.
    /// Venus: Magellan radar altimetry and the IAU's named features.
    public static let venus = Body(
        id: "venus", name: "Venus", radius: 6051.8, resourceFolder: "Venus",
        datasets: [
            DatasetDescriptor(id: .elevation, kind: .grid, file: "elevation.grid", title: "Elevation",
                              attribution: "Magellan Global Topography 4641 m (USGS Astrogeology, from the Magellan GTDR, NASA PDS)"),
            DatasetDescriptor(id: .features, kind: .places, file: "features.json", title: "Named features",
                              attribution: "Gazetteer of Planetary Nomenclature (IAU WGPSN, USGS Astrogeology)"),
        ],
        fields: [CommonFields.elevation, CommonFields.highlands, CommonFields.craters],
        relief: ReliefTint(["#2b130a", "#5c2a12", "#8f4a1c", "#c07a2d", "#e3ad4c", "#f5d98b", "#fff3cf"]),
        hasSeas: false, hasSunlight: true)

    public static let all: [Body] = [.earth, .moon, .mars, .venus]
}

/// Fields any body with elevation (and features) has.
public enum CommonFields {
    public static let elevation = FieldDescriptor(
        id: "elevation", title: "Elevation", summary: "Height above the reference surface",
        units: "m", scale: .diverging, colormap: .terrain, requires: [.elevation]
    ) { data, _ in
        GridField(grid: try data.grid(.elevation), layer: 0)
    }

    /// Van Wijk's f with high ground for land: the share of ground above
    /// the median height nearby, smoothed on the sphere. On the Moon it
    /// sets the highlands against the maria, on Mars the southern uplands
    /// against the northern plains.
    public static let highlands = FieldDescriptor(
        id: "landDensity", title: "Highlands nearby", summary: "High ground in the neighbourhood, smoothed on the sphere",
        units: "", variants: [5, 10, 15, 20].map { FieldVariant("\($0)", "σ = \($0)°") }, defaultVariant: "10",
        scale: .linear, colormap: .landness, requires: [.elevation]
    ) { data, variant in
        let sigma = Double(variant) ?? 10
        let raster = try data.cached("field:highRaster:256") { () -> GridField in
            let elevation = GridField(grid: try data.grid(.elevation), layer: 0)
            let median = elevation.quantile(0.5)
            return GridField.sampling(width: 256, height: 128) { p in
                // Supersample each cell 4 × 4.
                var high = 0
                for i in 0..<4 {
                    for j in 0..<4 {
                        let lat = p.latitude + (Double(j) - 1.5) * 180 / 128 / 4
                        let lon = p.longitude + (Double(i) - 1.5) * 360 / 256 / 4
                        if elevation.value(latitude: lat, longitude: lon) > median { high += 1 }
                    }
                }
                return Double(high) / 16
            }
        }
        return raster.sphericalGaussian(sigma: sigma, halfRows: max(32, Int((3 * sigma / raster.dlat).rounded(.up))))
    }

    /// Where the craters are: each named crater spread over its own size.
    public static let craters = FieldDescriptor(
        id: "craters", title: "Craters", summary: "Density of named craters, each spread over its own disc",
        units: "craters per 10⁶ km²", scale: .linear, colormap: .density, requires: [.features]
    ) { data, _ in
        // Lettered satellite craters ("Hertzsprung D") are craters too.
        let craters = try data.features().features.filter {
            let type = $0.type.lowercased()
            return type.contains("crater") || type.contains("satellite")
        }
        let width = 720, height = 360
        var values = [Float](repeating: 0, count: width * height)
        let template = GridField(width: width, height: height, values: values)
        let radius = data.body.radius
        for crater in craters {
            // A disc of the crater's radius (at least one cell).
            let r = max(crater.diameter / 2 / radius, 0.6 * .pi / 180)
            let c = crater.location.unitVector
            let rDeg = r * 180 / .pi
            let j0 = max(0, Int((crater.lat - rDeg - template.lat0) / template.dlat))
            let j1 = min(height - 1, Int((crater.lat + rDeg - template.lat0) / template.dlat) + 1)
            guard j0 <= j1 else { continue }
            let weight = Float(1e6 / (.pi * pow(r * radius, 2)))
            for j in j0...j1 {
                let lat = template.lat0 + Double(j) * template.dlat
                let span = min(180, rDeg / max(cos(lat * .pi / 180), 0.01)) + template.dlon
                let i0 = Int(((crater.lon - span) - template.lon0) / template.dlon), i1 = Int(((crater.lon + span) - template.lon0) / template.dlon) + 1
                for k in i0...max(i0, min(i1, i0 + width - 1)) {
                    let i = ((k % width) + width) % width
                    if template.cellCenter(i, j).unitVector.angle(to: c) <= r { values[j * width + i] += weight }
                }
            }
        }
        return GridField(width: width, height: height, values: values).sphericalGaussian(sigma: 2, halfRows: 8)
    }
}
