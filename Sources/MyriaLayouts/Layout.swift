import Foundation
import MyriaCore
import MyriaData

/// Where a layout appears in the gallery.
public enum LayoutCategory: String, Sendable, CaseIterable, Hashable {
    case planet, people, climate, worlds, homage

    public var title: String {
        switch self {
        case .worlds: "Shores and Craters"
        case .planet: "The Planet"
        case .people: "People"
        case .climate: "Sky and Climate"
        case .homage: "Van Wijk, 2008"
        }
    }
}

/// A knob of a layout, described so that interfaces can build controls for
/// it without knowing the layout.
public struct LayoutParameter: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// A number in a range; `unit` is shown after the value ("°", "%").
        case slider(range: ClosedRange<Double>, step: Double, unit: String)
        case toggle
        /// One of several named options; the value is the option's index.
        case choice([String])
    }

    public let id: String
    public let title: String
    public let help: String
    public let kind: Kind
    public let defaultValue: Double

    public init(id: String, title: String, help: String = "", kind: Kind, defaultValue: Double) {
        self.id = id
        self.title = title
        self.help = help
        self.kind = kind
        self.defaultValue = defaultValue
    }

    public static func slider(_ id: String, _ title: String, _ range: ClosedRange<Double>, step: Double = 1,
                              unit: String = "", default value: Double, help: String = "") -> LayoutParameter {
        LayoutParameter(id: id, title: title, help: help, kind: .slider(range: range, step: step, unit: unit), defaultValue: value)
    }

    public static func toggle(_ id: String, _ title: String, default value: Bool, help: String = "") -> LayoutParameter {
        LayoutParameter(id: id, title: title, help: help, kind: .toggle, defaultValue: value ? 1 : 0)
    }

    public static func choice(_ id: String, _ title: String, _ options: [String], default value: Int = 0,
                              help: String = "") -> LayoutParameter {
        LayoutParameter(id: id, title: title, help: help, kind: .choice(options), defaultValue: Double(value))
    }
}

/// Values for a layout's parameters, plus the moment the map shows.
public struct LayoutParameters: Sendable, Hashable {
    public var values: [String: Double]
    /// The date for time-dependent layouts (day and night, UTC offsets).
    public var date: Date

    public init(values: [String: Double] = [:], date: Date = Date()) {
        self.values = values
        self.date = date
    }

    public subscript(_ id: String) -> Double? {
        get { values[id] }
        set { values[id] = newValue }
    }

    public func value(_ id: String, default fallback: Double) -> Double { values[id] ?? fallback }
    public func flag(_ id: String, default fallback: Bool = false) -> Bool { (values[id] ?? (fallback ? 1 : 0)) != 0 }
    public func index(_ id: String, default fallback: Int = 0) -> Int { Int(values[id] ?? Double(fallback)) }
}

/// How a layout would like the map to look; the user may override it.
public struct LayoutAppearance: Sendable, Hashable {
    /// What fills the faces.
    public enum Coloring: Sendable, Hashable {
        /// Land and sea.
        case landSea
        /// Shaded relief with hypsometric tints.
        case relief
        /// A scalar field through a colour scale.
        case field(FieldKey)
        /// One colour per region of a dataset (countries, plates, timezones).
        case regions(DatasetID)
        /// One colour per piece of the cut (the layout's face groups).
        case groups
    }

    public var coloring: Coloring
    /// Line layers drawn on top, besides coastlines.
    public var lines: [DatasetID]
    public var showGraticule: Bool
    public var showCities: Bool
    public var showFlights: Bool
    public var showNight: Bool
    public var showWind: Bool

    public init(coloring: Coloring = .landSea, lines: [DatasetID] = [], showGraticule: Bool = true,
                showCities: Bool = false, showFlights: Bool = false, showNight: Bool = false, showWind: Bool = false) {
        self.coloring = coloring
        self.lines = lines
        self.showGraticule = showGraticule
        self.showCities = showCities
        self.showFlights = showFlights
        self.showNight = showNight
        self.showWind = showWind
    }
}

/// The static description of a layout.
public struct LayoutDescriptor: Sendable, Identifiable, Hashable {
    public let id: String
    public let title: String
    /// One line for the gallery.
    public let summary: String
    /// A paragraph on what the cuts mean and how they are found.
    public let story: String
    /// An SF Symbol name.
    public let symbol: String
    public let category: LayoutCategory
    public let parameters: [LayoutParameter]
    /// The mesh the layout looks best on.
    public let preferredMesh: MeshKind
    /// Datasets the layout needs; it is offered only for bodies that have them.
    public let requires: [DatasetID]
    /// Re-cut when the clock moves.
    public let isTimeDependent: Bool
    /// The layout picks its own myriahedron (Platonic solids); the mesh
    /// choice is not offered.
    public let fixesMesh: Bool
    /// Fields (by id) the layout needs, besides datasets.
    public let requiresFields: [String]
    /// Bodies the layout is meant for; nil means any body with the data.
    public let bodies: [String]?

    public init(id: String, title: String, summary: String, story: String, symbol: String, category: LayoutCategory,
                parameters: [LayoutParameter] = [], preferredMesh: MeshKind, requires: [DatasetID] = [],
                isTimeDependent: Bool = false, fixesMesh: Bool = false, requiresFields: [String] = [],
                bodies: [String]? = nil) {
        self.requiresFields = requiresFields
        self.bodies = bodies
        self.id = id
        self.title = title
        self.summary = summary
        self.story = story
        self.symbol = symbol
        self.category = category
        self.parameters = parameters
        self.preferredMesh = preferredMesh
        self.requires = requires
        self.isTimeDependent = isTimeDependent
        self.fixesMesh = fixesMesh
    }

    public var defaultParameters: LayoutParameters {
        LayoutParameters(values: Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, $0.defaultValue) }))
    }

    public func parameter(_ id: String) -> LayoutParameter? { parameters.first { $0.id == id } }

    /// The same layout under another name (for another world).
    public func renamed(title: String, summary: String) -> LayoutDescriptor {
        LayoutDescriptor(id: id, title: title, summary: summary, story: story, symbol: symbol, category: category,
                         parameters: parameters, preferredMesh: preferredMesh, requires: requires,
                         isTimeDependent: isTimeDependent, fixesMesh: fixesMesh, requiresFields: requiresFields, bodies: bodies)
    }

    /// Whether a body has what this layout needs.
    public func isAvailable(for body: Body) -> Bool {
        (bodies?.contains(body.id) ?? true) && requires.allSatisfy(body.has)
            && requiresFields.allSatisfy { id in body.availableFields.contains { $0.id == id } }
    }
}

/// The result of cutting: which edges stay hinges, the root face, and how
/// faces group into meaningful pieces (regions, land masses).
public struct LayoutCut: Sendable {
    public var hinges: [Bool]
    public var root: Int
    /// Optional label per face (a region, a land mass); -1 for none.
    public var faceGroups: [Int]?
    /// Names for the groups, indexed by group.
    public var groupNames: [String]
    /// A few facts about the cut ("land cut: 1.2 %").
    public var notes: [String]

    public init(hinges: [Bool], root: Int, faceGroups: [Int]? = nil, groupNames: [String] = [], notes: [String] = []) {
        self.hinges = hinges
        self.root = root
        self.faceGroups = faceGroups
        self.groupNames = groupNames
        self.notes = notes
    }
}

/// A way to cut the myriahedron open. Implementations are small: they
/// combine weights or regions from the `LayoutContext` and hand back a
/// spanning tree. New layouts plug in by conforming and registering in
/// `LayoutCatalog`.
public protocol Layout: Sendable {
    var descriptor: LayoutDescriptor { get }

    /// The mesh to cut, given the user's choice. Layouts that need a
    /// particular solid or orientation return their own.
    func mesh(for parameters: LayoutParameters, chosen: MeshSpec, body: BodyData) throws -> MeshSpec

    /// Decides the hinges.
    func cut(_ context: LayoutContext, parameters: LayoutParameters) throws -> LayoutCut

    /// The look that tells this layout's story.
    func appearance(_ parameters: LayoutParameters) -> LayoutAppearance

    /// Parameter values that suit a body better than the descriptor's.
    func defaults(for body: Body) -> [String: Double]

    /// The descriptor as shown for a body (names that fit that world).
    func descriptor(for body: Body) -> LayoutDescriptor
}

extension Layout {
    public var id: String { descriptor.id }

    public func mesh(for parameters: LayoutParameters, chosen: MeshSpec, body: BodyData) throws -> MeshSpec { chosen }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance { LayoutAppearance() }

    public func defaults(for body: Body) -> [String: Double] { [:] }

    public func descriptor(for body: Body) -> LayoutDescriptor { descriptor }

    /// The descriptor's defaults with the body's own on top.
    public func defaultParameters(for body: Body) -> LayoutParameters {
        var p = descriptor.defaultParameters
        for (k, v) in defaults(for: body) { p[k] = v }
        return p
    }
}

public enum LayoutError: Error, CustomStringConvertible {
    case unknownLayout(String)
    case missingData(String)

    public var description: String {
        switch self {
        case .unknownLayout(let id): "no layout named \(id)"
        case .missingData(let what): "missing data: \(what)"
        }
    }
}
