import Foundation
import MyriaCore

extension Body {
    /// The Earth and its bundled data.
    public static let earth = Body(
        id: "earth", name: "Earth", radius: 6371.0088, resourceFolder: "Earth",
        datasets: [
            DatasetDescriptor(id: .land, kind: .land, file: "land.geojson", title: "Land",
                              attribution: "Natural Earth 1:50m land (public domain)"),
            DatasetDescriptor(id: .lakes, kind: .regions, file: "lakes.geojson", title: "Lakes",
                              attribution: "Natural Earth 1:50m lakes (public domain)"),
            DatasetDescriptor(id: .timeZones, kind: .timeZones, file: "timezones.geojson", title: "Timezones",
                              attribution: "timezone-boundary-builder 2026e (ODbL, © OpenStreetMap contributors)"),
            DatasetDescriptor(id: .countries, kind: .regions, file: "countries.geojson", title: "Countries",
                              attribution: "Natural Earth 1:50m admin-0 countries (public domain)"),
            DatasetDescriptor(id: .countryBorders, kind: .lines, file: "country-borders.geojson", title: "Country borders",
                              attribution: "Natural Earth 1:50m land boundaries (public domain)"),
            DatasetDescriptor(id: .plates, kind: .regions, file: "plates.geojson", title: "Tectonic plates",
                              attribution: "Bird (2003) PB2002, via fraxen/tectonicplates (ODC-BY)"),
            DatasetDescriptor(id: .plateBoundaries, kind: .lines, file: "plate-boundaries.geojson", title: "Plate boundaries",
                              attribution: "Bird (2003) PB2002, via fraxen/tectonicplates (ODC-BY)"),
            DatasetDescriptor(id: .rivers, kind: .lines, file: "rivers.geojson", title: "Rivers",
                              attribution: "Natural Earth 1:50m rivers and lake centrelines (public domain)"),
            DatasetDescriptor(id: .places, kind: .places, file: "places.json", title: "Cities",
                              attribution: "Natural Earth populated places (public domain)"),
            DatasetDescriptor(id: .flights, kind: .flights, file: "flights.json", title: "Air routes",
                              attribution: "OpenFlights airports and routes (ODbL)"),
            DatasetDescriptor(id: .precipitation, kind: .grid, file: "precipitation.grid", title: "Precipitation",
                              attribution: "GPCP v2.3 monthly climatology 1991–2020 (NOAA PSL)"),
            DatasetDescriptor(id: .wind, kind: .grid, file: "wind.grid", title: "Surface winds",
                              attribution: "NCEP/NCAR Reanalysis 1, σ = 0.995 climatology 1991–2020 (NOAA PSL)"),
            DatasetDescriptor(id: .elevation, kind: .grid, file: "elevation.grid", title: "Elevation",
                              attribution: "ETOPO1 (NOAA NCEI), 5′ subsample via ERDDAP"),
        ],
        fields: EarthFields.all)
}

/// The scalar fields JJ derives from Earth's data.
enum EarthFields {
    static let months: [FieldVariant] = [FieldVariant("annual", "Annual mean")]
        + Calendar(identifier: .gregorian).monthSymbols.enumerated().map { FieldVariant(String(format: "%02d", $0 + 1), $1) }

    static let all: [FieldDescriptor] = [landDensity, elevation, precipitation, windSpeed, population, flights, coastDistance]

    /// Van Wijk's F: the amount of land in the neighbourhood, a 256 × 128
    /// land raster convolved with a spherical Gaussian (figure 9).
    static let landDensity = FieldDescriptor(
        id: "landDensity", title: "Land nearby", summary: "Van Wijk's f: land in the neighbourhood, smoothed on the sphere",
        units: "", variants: [5, 10, 15, 20].map { FieldVariant("\($0)", "σ = \($0)°") }, defaultVariant: "10",
        scale: .linear, colormap: .landness, requires: [.land]
    ) { data, variant in
        let sigma = Double(variant) ?? 10
        let raster = try data.cached("field:landRaster:256") {
            GridField.coverage(rings: try data.land().rings, width: 256, height: 128, supersample: 8)
        }
        return raster.sphericalGaussian(sigma: sigma, halfRows: max(32, Int((3 * sigma / raster.dlat).rounded(.up))))
    }

    static let elevation = FieldDescriptor(
        id: "elevation", title: "Elevation", summary: "Height of the land and depth of the sea floor",
        units: "m", scale: .diverging, colormap: .terrain, requires: [.elevation]
    ) { data, _ in
        GridField(grid: try data.grid(.elevation), layer: 0)
    }

    static let precipitation = FieldDescriptor(
        id: "precipitation", title: "Rainfall", summary: "Mean precipitation, 1991–2020",
        units: "mm/day", variants: months, defaultVariant: "annual", scale: .linear, colormap: .rain,
        requires: [.precipitation]
    ) { data, variant in
        let grid = try data.grid(.precipitation)
        return GridField(grid: grid, layer: grid.header.layers.firstIndex(of: variant) ?? grid.header.layers.count - 1)
    }

    static let windSpeed = FieldDescriptor(
        id: "windSpeed", title: "Wind speed", summary: "Mean near-surface wind speed, 1991–2020",
        units: "m/s", variants: months, defaultVariant: "annual", scale: .linear, colormap: .wind, requires: [.wind]
    ) { data, variant in
        let wind = try data.wind(variant)
        return GridField(width: wind.u.width, height: wind.u.height, lon0: wind.u.lon0, lat0: wind.u.lat0,
                         dlon: wind.u.dlon, dlat: wind.u.dlat,
                         values: zip(wind.u.values, wind.v.values).map { ($0 * $0 + $1 * $1).squareRoot() })
    }

    /// Population density estimated from city populations: a Gaussian per
    /// city on the sphere, as log₁₀(1 + people per km²).
    static let population = FieldDescriptor(
        id: "population", title: "Population", summary: "People per km², estimated from 7,000 cities (log scale)",
        units: "log₁₀ people/km²", variants: [FieldVariant("0.5", "Sharp (σ = 0.5°)"), FieldVariant("1", "σ = 1°"),
                                              FieldVariant("2", "Broad (σ = 2°)")],
        defaultVariant: "1", scale: .logarithmic, colormap: .density, requires: [.places]
    ) { data, variant in
        let sigma = Double(variant) ?? 1
        let points = try data.places().places.map { ($0.location, Double($0.pop)) }
        return GridField.density(points: points, width: 1440, height: 720, sigma: sigma, radius: data.body.radius)
            .mapValues { log10(1 + $0) }
    }

    /// How busy the sky is: airline routes as great circles, as log₁₀(1 +
    /// route-kilometres per 1000 km²).
    static let flights = FieldDescriptor(
        id: "flights", title: "Air traffic", summary: "Density of airline routes flown along great circles (log scale)",
        units: "log₁₀ route-km per 1000 km²", scale: .logarithmic, colormap: .heat, requires: [.flights]
    ) { data, _ in
        let network = try data.flights()
        let step = 0.01  // radians, about 64 km
        var points: [(GeoPoint, Double)] = []
        for route in network.routes {
            let arc = network.arc(route, step: step)
            let length = arc.count > 1 ? arc[0].angle(to: arc[1]) * data.body.radius : 0
            for p in arc { points.append((GeoPoint(p), Double(route.count) * length * 1000)) }
        }
        return GridField.density(points: points, width: 720, height: 360, sigma: 1.2, radius: data.body.radius)
            .mapValues { log10(1 + $0) }
    }

    /// Signed great-circle distance to the nearest coastline: positive on
    /// land, negative at sea. Its ridges at sea are the exact middles of the
    /// oceans.
    static let coastDistance = FieldDescriptor(
        id: "coastDistance", title: "Distance to the coast", summary: "Kilometres to the nearest coastline (land +, sea −)",
        units: "km", scale: .diverging, colormap: .distance, requires: [.land]
    ) { data, _ in
        let land = try data.land()
        let index = try data.cached("index:coast") { CoastIndex(land: land) }
        let width = 720, height = 360
        let landRaster = GridField.coverage(rings: land.rings, width: width, height: height, supersample: 4)
        let radius = data.body.radius
        return GridField.sampling(width: width, height: height) { p in
            let d = (index.distance(to: p.unitVector) ?? 0) * radius
            return landRaster.value(latitude: p.latitude, longitude: p.longitude) >= 0.5 ? d : -d
        }
    }
}

/// Points along every coastline, for exact distances to the coast.
public struct CoastIndex: Sendable {
    let index: PointIndex

    public init(land: LandMask, step: Double = 0.0025) {
        var points: [Vec3] = []
        for s in land.coastlines.segments {
            let n = max(1, Int((s.a.angle(to: s.b) / step).rounded(.up)))
            for k in 0..<n { points.append(Spherical.slerp(s.a, s.b, Double(k) / Double(n))) }
        }
        index = PointIndex(points)
    }

    /// Distance along the unit sphere (radians) to the nearest coast point.
    public func distance(to p: Vec3) -> Double? { index.nearest(to: p)?.distance }
}
