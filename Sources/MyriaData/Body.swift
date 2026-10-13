import Foundation
import MyriaCore

/// Names a dataset of a body ("land", "rivers", "precipitation", …).
public struct DatasetID: Hashable, Sendable, Codable, RawRepresentable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public var description: String { rawValue }
}

extension DatasetID {
    public static let land: DatasetID = "land"
    public static let lakes: DatasetID = "lakes"
    public static let timeZones: DatasetID = "timezones"
    public static let countries: DatasetID = "countries"
    public static let countryBorders: DatasetID = "country-borders"
    public static let plates: DatasetID = "plates"
    public static let plateBoundaries: DatasetID = "plate-boundaries"
    public static let rivers: DatasetID = "rivers"
    public static let places: DatasetID = "places"
    public static let flights: DatasetID = "flights"
    public static let precipitation: DatasetID = "precipitation"
    public static let wind: DatasetID = "wind"
    public static let elevation: DatasetID = "elevation"
}

/// How a dataset is stored and what it loads as.
public enum DatasetKind: String, Sendable, Hashable {
    /// Land polygons → `LandMask`.
    case land
    /// Named polygons partitioning the surface → `RegionSet`.
    case regions
    /// Timezone polygons → `TimeZoneAtlas`.
    case timeZones
    /// Polylines with an attribute → `LineSet`.
    case lines
    /// Populated places → `PlaceSet`.
    case places
    /// Airports and routes → `FlightNetwork`.
    case flights
    /// Rasters → `GridFile`.
    case grid
}

public struct DatasetDescriptor: Sendable, Hashable {
    public let id: DatasetID
    public let kind: DatasetKind
    /// File name inside the body's resource folder.
    public let file: String
    public let title: String
    public let attribution: String

    public init(id: DatasetID, kind: DatasetKind, file: String, title: String, attribution: String) {
        self.id = id
        self.kind = kind
        self.file = file
        self.title = title
        self.attribution = attribution
    }
}

/// Names a scalar field of a body, with a variant (a month, a smoothing radius).
public struct FieldKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public var id: String
    public var variant: String

    public init(_ id: String, _ variant: String = "") {
        self.id = id
        self.variant = variant
    }

    public var description: String { variant.isEmpty ? id : "\(id):\(variant)" }
}

/// How a field's values should be read by colour scales.
public enum FieldScale: String, Sendable, Hashable {
    /// Plain values, e.g. 0…1 or mm/day.
    case linear
    /// Values that are already log₁₀ of a density.
    case logarithmic
    /// Values around zero with meaning on both sides (elevation, signed distance).
    case diverging
}

/// The colour scale a field is best shown with; palettes supply the colours.
public enum ColormapHint: String, Sendable, Hashable, CaseIterable {
    case terrain, rain, heat, density, wind, landness, distance, sequential
}

public struct FieldVariant: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String

    public init(_ id: String, _ title: String) {
        self.id = id
        self.title = title
    }
}

/// A scalar field a body offers, with how to build it.
public struct FieldDescriptor: Sendable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    public let units: String
    public let variants: [FieldVariant]
    public let defaultVariant: String
    public let scale: FieldScale
    public let colormap: ColormapHint
    public let requires: [DatasetID]
    let build: @Sendable (BodyData, String) throws -> GridField

    public init(id: String, title: String, summary: String, units: String, variants: [FieldVariant] = [],
                defaultVariant: String = "", scale: FieldScale = .linear, colormap: ColormapHint = .sequential,
                requires: [DatasetID], build: @escaping @Sendable (BodyData, String) throws -> GridField) {
        self.id = id
        self.title = title
        self.summary = summary
        self.units = units
        self.variants = variants
        self.defaultVariant = defaultVariant
        self.scale = scale
        self.colormap = colormap
        self.requires = requires
        self.build = build
    }

    public var defaultKey: FieldKey { FieldKey(id, defaultVariant) }
}

/// A celestial body: its size, its datasets and the fields derived from them.
/// Earth is the one JJ ships with; the Moon or Mars would be another `Body`
/// with their own resource folder and catalogue.
public struct Body: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    /// Mean radius in kilometres.
    public let radius: Double
    /// Folder holding the body's data files.
    public let resourceFolder: String
    public let datasets: [DatasetDescriptor]
    public let fields: [FieldDescriptor]

    public init(id: String, name: String, radius: Double, resourceFolder: String, datasets: [DatasetDescriptor],
                fields: [FieldDescriptor]) {
        self.id = id
        self.name = name
        self.radius = radius
        self.resourceFolder = resourceFolder
        self.datasets = datasets
        self.fields = fields
    }

    public static func == (a: Body, b: Body) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    public func has(_ dataset: DatasetID) -> Bool { datasets.contains { $0.id == dataset } }
    public func descriptor(_ dataset: DatasetID) -> DatasetDescriptor? { datasets.first { $0.id == dataset } }
    public func field(_ id: String) -> FieldDescriptor? { fields.first { $0.id == id } }
    /// Fields whose datasets this body has.
    public var availableFields: [FieldDescriptor] { fields.filter { $0.requires.allSatisfy(has) } }
}

public enum BodyDataError: Error, CustomStringConvertible {
    case missingDataset(DatasetID)
    case missingResource(String)
    case unknownField(String)
    case wrongKind(DatasetID, DatasetKind)

    public var description: String {
        switch self {
        case .missingDataset(let id): "this body has no dataset \(id)"
        case .missingResource(let name): "data file \(name) not found"
        case .unknownField(let id): "unknown field \(id)"
        case .wrongKind(let id, let kind): "dataset \(id) is not of kind \(kind)"
        }
    }
}

/// Loads a body's datasets and fields on demand and keeps them. Safe to use
/// from any thread; each item is loaded once.
public final class BodyData: Sendable {
    public let body: Body
    private let store = OnceCache()

    public init(body: Body) {
        self.body = body
    }

    /// Earth's data, shared by the whole process.
    public static let earth = BodyData(body: .earth)

    /// The value for `key`, loading it once.
    public func cached<T: Sendable>(_ key: String, _ load: () throws -> T) throws -> T {
        try store.value(key, load)
    }

    /// Whether `key` has been loaded already.
    public func isLoaded(_ key: String) -> Bool { store.contains(key) }

    // MARK: Files

    public func url(of dataset: DatasetID) throws -> URL {
        guard let d = body.descriptor(dataset) else { throw BodyDataError.missingDataset(dataset) }
        return try ResourceLocator.url(folder: body.resourceFolder, file: d.file)
    }

    private func features(_ dataset: DatasetID) throws -> [GeoFeature] {
        try GeoJSON.features(from: Data(contentsOf: url(of: dataset)))
    }

    // MARK: Datasets

    public func land() throws -> LandMask {
        try cached("dataset:land") { LandMask(features: try features(.land)) }
    }

    public func timeZones() throws -> TimeZoneAtlas {
        try cached("dataset:timezones") { TimeZoneAtlas(features: try features(.timeZones)) }
    }

    /// Countries, plates, lakes: any polygon dataset as named regions.
    public func regions(_ dataset: DatasetID) throws -> RegionSet {
        try cached("dataset:\(dataset)") {
            let f = try features(dataset)
            return switch dataset {
            case .countries: RegionSet(features: f, nameKey: "name", codeKey: "iso", labelKeys: ("labelLon", "labelLat"))
            default: RegionSet(features: f, nameKey: "name", codeKey: "code")
            }
        }
    }

    public func lines(_ dataset: DatasetID) throws -> LineSet {
        try cached("dataset:\(dataset)") {
            let f = try features(dataset)
            return switch dataset {
            case .rivers: LineSet(features: f) { $0.int("rank") ?? 10 }
            case .plateBoundaries: LineSet(features: f, nameKey: "plates") { PlateBoundaryKind(code: $0.string("kind")).rawValue }
            default: LineSet(features: f)
            }
        }
    }

    public func places() throws -> PlaceSet {
        try cached("dataset:places") { try PlaceSet(contentsOf: url(of: .places)) }
    }

    public func flights() throws -> FlightNetwork {
        try cached("dataset:flights") { try FlightNetwork(contentsOf: url(of: .flights)) }
    }

    public func grid(_ dataset: DatasetID) throws -> GridFile {
        try cached("dataset:\(dataset)") { try GridFile(contentsOf: url(of: dataset)) }
    }

    // MARK: Fields

    public func field(_ key: FieldKey) throws -> GridField {
        guard let descriptor = body.field(key.id) else { throw BodyDataError.unknownField(key.id) }
        let variant = key.variant.isEmpty ? descriptor.defaultVariant : key.variant
        return try cached("field:\(key.id):\(variant)") { try descriptor.build(self, variant) }
    }

    /// Wind as a tangent vector field (m/s) for a month ("01"…"12") or the
    /// annual mean ("annual").
    public func wind(_ variant: String = "annual") throws -> WindField {
        try cached("wind:\(variant)") {
            let grid = try grid(.wind)
            let suffix = variant == "annual" ? "" : variant
            let u = grid.header.layers.firstIndex(of: "u" + suffix) ?? 0
            let v = grid.header.layers.firstIndex(of: "v" + suffix) ?? 0
            return WindField(u: GridField(grid: grid, layer: u), v: GridField(grid: grid, layer: v))
        }
    }
}

/// Kinds of tectonic plate boundary (after Bird 2003).
public enum PlateBoundaryKind: Int, Sendable, CaseIterable {
    case ridge, subduction, transform, convergent, other

    public init(code: String?) {
        self = switch code {
        case "ridge": .ridge
        case "subduction": .subduction
        case "transform": .transform
        case "convergent": .convergent
        default: .other
        }
    }

    public var title: String {
        switch self {
        case .ridge: "Spreading ridge"
        case .subduction: "Subduction zone"
        case .transform: "Transform fault"
        case .convergent: "Convergent boundary"
        case .other: "Plate boundary"
        }
    }
}

/// Horizontal wind on the sphere from eastward (u) and northward (v) grids.
public struct WindField: Sendable {
    public let u: GridField
    public let v: GridField

    /// The wind at `p` as a tangent vector in m/s.
    public func vector(at p: Vec3) -> Vec3 {
        let (east, north) = Spherical.tangentFrame(at: p)
        let g = GeoPoint(p)
        let ue = u.value(latitude: g.latitude, longitude: g.longitude)
        let vn = v.value(latitude: g.latitude, longitude: g.longitude)
        guard ue.isFinite, vn.isFinite else { return .zero }
        return east * ue + north * vn
    }
}

/// Finds data files: in the app bundle's resources first (assembled .app),
/// then in the SwiftPM resource bundle.
public enum ResourceLocator {
    public static func url(folder: String, file: String) throws -> URL {
        if let base = Bundle.main.resourceURL {
            let candidate = base.appendingPathComponent(folder).appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        if let base = Bundle.module.resourceURL {
            let candidate = base.appendingPathComponent(folder).appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        throw BodyDataError.missingResource("\(folder)/\(file)")
    }
}
