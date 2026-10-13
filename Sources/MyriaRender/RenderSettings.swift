import Foundation
import MyriaCore
import MyriaData
import MyriaLayouts

/// The layers a map can show.
public enum LayerID: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
    case land, lakes, coastlines, rivers, countryBorders, timeZoneBorders, plateBoundaries, graticule
    case cities, flights, night, wind, cuts, mesh, tissot, labels

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .land: "Land"
        case .lakes: "Lakes"
        case .coastlines: "Coastlines"
        case .rivers: "Rivers"
        case .countryBorders: "Country borders"
        case .timeZoneBorders: "Timezone borders"
        case .plateBoundaries: "Plate boundaries"
        case .graticule: "Graticule"
        case .cities: "Cities"
        case .flights: "Air routes"
        case .night: "Day and night"
        case .wind: "Wind"
        case .cuts: "Cut edges"
        case .mesh: "Faces"
        case .tissot: "Tissot's indicatrices"
        case .labels: "Labels"
        }
    }

    /// The dataset a layer needs, if any.
    public var dataset: DatasetID? {
        switch self {
        case .land, .coastlines: .land
        case .lakes: .lakes
        case .rivers: .rivers
        case .countryBorders: .countryBorders
        case .timeZoneBorders: .timeZones
        case .plateBoundaries: .plateBoundaries
        case .cities: .places
        case .flights: .flights
        case .wind: .wind
        default: nil
        }
    }

    /// The layers a layout's appearance switches on.
    public static func defaults(for appearance: LayoutAppearance, body: Body = .earth) -> Set<LayerID> {
        var layers: Set<LayerID> = [.coastlines, .labels]
        switch appearance.coloring {
        case .field(let key):
            // Densities are laid over land and sea; other fields cover them.
            if body.field(key.id)?.scale == .logarithmic { layers.formUnion([.land, .lakes]) }
        case .landSea, .relief, .regions, .groups: layers.formUnion([.land, .lakes])
        }
        if case .regions(.timeZones) = appearance.coloring { layers.insert(.timeZoneBorders) }
        if appearance.lines.contains(.rivers) { layers.insert(.rivers) }
        if appearance.lines.contains(.countryBorders) { layers.insert(.countryBorders) }
        if appearance.lines.contains(.plateBoundaries) { layers.insert(.plateBoundaries) }
        if appearance.lines.contains(.timeZones) { layers.insert(.timeZoneBorders) }
        if appearance.showGraticule { layers.insert(.graticule) }
        if appearance.showCities { layers.insert(.cities) }
        if appearance.showFlights { layers.insert(.flights) }
        if appearance.showNight { layers.insert(.night) }
        if appearance.showWind { layers.insert(.wind) }
        return layers
    }
}

/// A line drawn in map coordinates (wind particle trails, measurements).
public struct MapLine: Sendable {
    public var a: Vec2
    public var b: Vec2
    public var alpha: Float

    public init(a: Vec2, b: Vec2, alpha: Float) {
        self.a = a
        self.b = b
        self.alpha = alpha
    }
}

/// Everything that decides how one frame looks.
public struct FrameSettings: Sendable {
    public var style: PaletteStyle
    public var coloring: LayoutAppearance.Coloring
    public var layers: Set<LayerID>
    /// The moment shown: night, clocks.
    public var date: Date
    /// 0 is the closed globe, 1 the flat map.
    public var unfold: Double
    /// Rotation of the globe while folded.
    public var globe: Mat3
    /// The camera; its size is in points.
    public var viewport: Viewport
    /// Pixels per point of the target.
    public var pixelScale: Double
    /// Line widths are multiplied by this (thicker lines for big exports).
    public var lineScale: Double
    public var graticuleStep: Double
    /// Groups (of the cut's face groups) to outline.
    public var highlightGroups: [Int]
    /// Extra lines in map coordinates, drawn in the wind colour.
    public var mapLines: [MapLine]
    /// Close slits narrower than about a pixel.
    public var sealSlits: Bool
    /// A soft glow around the globe while folded.
    public var atmosphere = true
    /// How far the flat map's gaps are closed (van Wijk's figure 13): 0 the
    /// myriahedral map, 1 the map without interrupts. Triangle meshes only.
    public var closing = 0.0
    /// Points to mark in map coordinates, each with a pulse phase 0…1.
    public var markers: [(point: Vec2, phase: Double)] = []

    public init(style: PaletteStyle, coloring: LayoutAppearance.Coloring, layers: Set<LayerID>, date: Date = Date(),
                unfold: Double = 1, globe: Mat3 = .identity, viewport: Viewport, pixelScale: Double = 1,
                lineScale: Double = 1, graticuleStep: Double = 15, highlightGroups: [Int] = [], mapLines: [MapLine] = [],
                sealSlits: Bool = true) {
        self.style = style
        self.coloring = coloring
        self.layers = layers
        self.date = date
        self.unfold = unfold
        self.globe = globe
        self.viewport = viewport
        self.pixelScale = pixelScale
        self.lineScale = lineScale
        self.graticuleStep = graticuleStep
        self.highlightGroups = highlightGroups
        self.mapLines = mapLines
        self.sealSlits = sealSlits
    }
}
