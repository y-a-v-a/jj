import Foundation
import MyriaData

/// The colours of one appearance (light or dark) of a palette.
public struct PaletteStyle: Hashable, Sendable {
    /// Behind the map.
    public var background: RGBA
    public var ocean: RGBA
    public var land: RGBA
    public var coastline: RGBA
    public var graticule: RGBA
    public var river: RGBA
    public var border: RGBA
    public var cut: RGBA
    public var mesh: RGBA
    public var highlight: RGBA
    /// Label inks and the halo drawn behind them.
    public var ink: RGBA
    public var secondaryInk: RGBA
    public var halo: RGBA
    /// The colour of night; its alpha is the darkness at astronomical night.
    public var night: RGBA
    /// Region fills, in slot order; neighbouring regions get different slots.
    public var categorical: [RGBA]
    public var city: RGBA
    public var route: RGBA
    public var wind: RGBA
    public var tissot: RGBA
    /// Plate boundaries: ridge, subduction, transform, convergent, other.
    public var plateBoundaries: [RGBA]
    /// The inside of the shell, seen through the cuts while folding.
    public var backface: RGBA
    /// Hypsometric tints, sea level to the highest peaks.
    public var reliefLand: Colormap
    /// Bathymetric tints, the deepest trench to sea level.
    public var reliefSea: Colormap
    /// How strongly relief shades land (0…1).
    public var hillshade: Double
    /// Colour scales per kind of field.
    public var colormaps: [ColormapHint: Colormap]

    public func colormap(_ hint: ColormapHint) -> Colormap {
        colormaps[hint] ?? colormaps[.sequential] ?? Palette.viridis
    }

    public func boundary(_ kind: PlateBoundaryKind) -> RGBA {
        plateBoundaries[min(kind.rawValue, plateBoundaries.count - 1)]
    }
}

/// A named colour scheme with a light and a dark variant. Add palettes by
/// appending to `Palette.all`.
public struct Palette: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let light: PaletteStyle
    public let dark: PaletteStyle

    public func style(dark isDark: Bool) -> PaletteStyle { isDark ? dark : light }

    public static func named(_ id: String) -> Palette? { all.first { $0.id == id } }

    public static let all: [Palette] = [vanWijk, atlas, blueprint, midnight, ink, terra]

    // MARK: Shared scales

    static let viridis = Colormap(hex: ["#440154", "#472d7b", "#3b528b", "#2c728e", "#21918c", "#28ae80", "#5ec962", "#addc30", "#fde725"])
    static let magma = Colormap(hex: ["#000004", "#1c1044", "#4f127b", "#812581", "#b5367a", "#e55964", "#fb8761", "#fec287", "#fcfdbf"])
    static let terrainLand = Colormap(hex: ["#5d9b5a", "#8db36a", "#c8c27a", "#d4a86a", "#a8805e", "#8c7b70", "#e8e6e3"])
    static let terrainSea = Colormap(hex: ["#0b2346", "#123a6b", "#1d5590", "#3b7db8", "#73a9d6", "#b6d6ee"])
    static let rain = Colormap(hex: ["#dcc489", "#c9c27e", "#9fc26a", "#58ae74", "#2a90a6", "#2c5fa6", "#3b2d83"])
    static let wind = Colormap(hex: ["#283a6e", "#29688e", "#2f9a98", "#7cc679", "#e0e25b", "#fbf5c8"])
    static let landness = Colormap(hex: ["#295b8a", "#7fa9d4", "#cfdde1", "#f2d27f", "#c98b39"])
    static let distance = Colormap(hex: ["#0d2b52", "#2d68a1", "#93c1e4", "#f4f1e6", "#d8c08a", "#a67a45", "#5b3c1f"])

    static func scales(density: Colormap, heat: Colormap, rain: Colormap = Palette.rain, wind: Colormap = Palette.wind,
                       landness: Colormap = Palette.landness, distance: Colormap = Palette.distance,
                       terrain: Colormap = Palette.terrainLand, sequential: Colormap = Palette.viridis) -> [ColormapHint: Colormap] {
        [.terrain: terrain, .rain: rain, .heat: heat, .density: density, .wind: wind, .landness: landness,
         .distance: distance, .sequential: sequential]
    }

    // MARK: Van Wijk, 2008

    /// The yellow land and blue sea of the figures in the paper.
    public static let vanWijk = Palette(
        id: "vanwijk", name: "Van Wijk 2008",
        summary: "Yellow land on a blue sea, as in the figures of the paper",
        light: PaletteStyle(
            background: RGBA(hex: "#fbf6dc"), ocean: RGBA(hex: "#8fb4dc"), land: RGBA(hex: "#f3d27d"),
            coastline: RGBA(hex: "#6b6247", alpha: 0.55), graticule: RGBA(hex: "#3a4c63", alpha: 0.32),
            river: RGBA(hex: "#3d79bb"), border: RGBA(hex: "#7a6440", alpha: 0.6), cut: RGBA(hex: "#c8473a"),
            mesh: RGBA(hex: "#2b2b2b", alpha: 0.12), highlight: RGBA(hex: "#1f1f1f", alpha: 0.9),
            ink: RGBA(hex: "#1d1d1b"), secondaryInk: RGBA(hex: "#4b4a44"), halo: RGBA(hex: "#fbf6dc", alpha: 0.85),
            night: RGBA(hex: "#0b1a3d", alpha: 0.42),
            categorical: ["#f3d27d", "#a6c98f", "#eaa17c", "#c4a9da", "#8fcac1", "#e5bf6b", "#f0b8b8"].map { RGBA(hex: $0) },
            city: RGBA(hex: "#8a2a1b"), route: RGBA(hex: "#b5421c", alpha: 0.28), wind: RGBA(hex: "#ffffff", alpha: 0.85),
            tissot: RGBA(hex: "#c0392b", alpha: 0.8),
            plateBoundaries: ["#d1495b", "#2e4057", "#00798c", "#d6942c", "#66635c"].map { RGBA(hex: $0) },
            backface: RGBA(hex: "#5b6b7d"),
            reliefLand: Colormap(hex: ["#f3d27d", "#e9c46f", "#d8a95f", "#b98a58", "#9c7a62", "#efe9dc"]),
            reliefSea: Colormap(hex: ["#3d6a9c", "#5d88b9", "#7ea3cf", "#8fb4dc", "#a9c6e6"]), hillshade: 0.45,
            colormaps: scales(density: Colormap(hex: ["#fbf6dc", "#f3d27d", "#e9965a", "#c94c3c", "#7e2443"]),
                              heat: Colormap(hex: ["#fbf6dc", "#f3d27d", "#e9965a", "#c4413a", "#6d1f3d"]))),
        dark: PaletteStyle(
            background: RGBA(hex: "#0e1521"), ocean: RGBA(hex: "#1d3b61"), land: RGBA(hex: "#c9a24f"),
            coastline: RGBA(hex: "#f2e3b3", alpha: 0.45), graticule: RGBA(hex: "#d7e1ee", alpha: 0.2),
            river: RGBA(hex: "#78b6ff"), border: RGBA(hex: "#efdcae", alpha: 0.45), cut: RGBA(hex: "#ff7b69"),
            mesh: RGBA(hex: "#ffffff", alpha: 0.1), highlight: RGBA(hex: "#ffffff", alpha: 0.9),
            ink: RGBA(hex: "#f6f0e1"), secondaryInk: RGBA(hex: "#cbc4b3"), halo: RGBA(hex: "#0e1521", alpha: 0.8),
            night: RGBA(hex: "#000000", alpha: 0.5),
            categorical: ["#c9a24f", "#6f9b5f", "#b86a4b", "#8b74a8", "#4e8f86", "#b38e3c", "#b77b85"].map { RGBA(hex: $0) },
            city: RGBA(hex: "#ffd68a"), route: RGBA(hex: "#ffb36b", alpha: 0.3), wind: RGBA(hex: "#ffffff", alpha: 0.8),
            tissot: RGBA(hex: "#ff8a7a", alpha: 0.85),
            plateBoundaries: ["#ff6b7f", "#7fb0ff", "#3fd0c9", "#ffc061", "#a8a49b"].map { RGBA(hex: $0) },
            backface: RGBA(hex: "#28313d"),
            reliefLand: Colormap(hex: ["#c9a24f", "#bb9446", "#a8814a", "#8f6f4f", "#7a6a60", "#d6d0c4"]),
            reliefSea: Colormap(hex: ["#0b1d36", "#132c4f", "#1a3a63", "#1d3b61", "#2a4f7a"]), hillshade: 0.5,
            colormaps: scales(density: Palette.magma, heat: Colormap(hex: ["#0e1521", "#3a1435", "#8c2240", "#d9542f", "#f9a740", "#fff3c9"]))))

    // MARK: Atlas

    public static let atlas = Palette(
        id: "atlas", name: "Atlas",
        summary: "Muted inks on paper, like a printed atlas",
        light: PaletteStyle(
            background: RGBA(hex: "#f1ebdc"), ocean: RGBA(hex: "#d6e2e0"), land: RGBA(hex: "#efe2c6"),
            coastline: RGBA(hex: "#5b4a35", alpha: 0.7), graticule: RGBA(hex: "#5b4a35", alpha: 0.2),
            river: RGBA(hex: "#4f7fa6"), border: RGBA(hex: "#7d5f45", alpha: 0.6), cut: RGBA(hex: "#a8443a"),
            mesh: RGBA(hex: "#1f1a15", alpha: 0.1), highlight: RGBA(hex: "#1f1a15", alpha: 0.85),
            ink: RGBA(hex: "#1f1a15"), secondaryInk: RGBA(hex: "#48433d"), halo: RGBA(hex: "#f7f2e6", alpha: 0.85),
            night: RGBA(hex: "#1d2b4a", alpha: 0.32),
            categorical: ["#8fb07c", "#d98c63", "#dcb65a", "#7f9fc6", "#bd8fb6", "#9cc1b5", "#d6a38b"].map { RGBA(hex: $0) },
            city: RGBA(hex: "#7a2e1d"), route: RGBA(hex: "#8c3b2a", alpha: 0.25), wind: RGBA(hex: "#3b3027", alpha: 0.6),
            tissot: RGBA(hex: "#a8443a", alpha: 0.8),
            plateBoundaries: ["#b5523b", "#3f5873", "#3f8a7e", "#c08b3c", "#6d6458"].map { RGBA(hex: $0) },
            backface: RGBA(hex: "#a39a88"),
            reliefLand: Colormap(hex: ["#d9dcb8", "#e7dfb4", "#e3c99a", "#cfae86", "#b3977e", "#f4f0e8"]),
            reliefSea: Colormap(hex: ["#8fb0bd", "#a7c3cb", "#bed4d7", "#d6e2e0", "#e3ebe8"]), hillshade: 0.4,
            colormaps: scales(density: Colormap(hex: ["#f1ebdc", "#e6c99a", "#d08a5c", "#a54e3e", "#5e2b3a"]),
                              heat: Colormap(hex: ["#f1ebdc", "#e3c08e", "#c97c52", "#9a3f37", "#4f2232"]),
                              rain: Colormap(hex: ["#efe2c6", "#d7cf9a", "#a8bf86", "#6fa28a", "#4f7fa6", "#4b5d8c"]))),
        dark: PaletteStyle(
            background: RGBA(hex: "#14110d"), ocean: RGBA(hex: "#1a2422"), land: RGBA(hex: "#3a3125"),
            coastline: RGBA(hex: "#f6efe0", alpha: 0.4), graticule: RGBA(hex: "#f6efe0", alpha: 0.12),
            river: RGBA(hex: "#7fa9c9"), border: RGBA(hex: "#e2cfb1", alpha: 0.4), cut: RGBA(hex: "#d9735f"),
            mesh: RGBA(hex: "#f6efe0", alpha: 0.08), highlight: RGBA(hex: "#f6efe0", alpha: 0.85),
            ink: RGBA(hex: "#f6efe0"), secondaryInk: RGBA(hex: "#d0c8b9"), halo: RGBA(hex: "#14110d", alpha: 0.8),
            night: RGBA(hex: "#000000", alpha: 0.45),
            categorical: ["#6a8c5b", "#b06744", "#a8853a", "#5a7ba3", "#8f6288", "#5f8f84", "#a77c6a"].map { RGBA(hex: $0) },
            city: RGBA(hex: "#f2cf8f"), route: RGBA(hex: "#e0a170", alpha: 0.28), wind: RGBA(hex: "#f6efe0", alpha: 0.7),
            tissot: RGBA(hex: "#e08a73", alpha: 0.85),
            plateBoundaries: ["#e07a5f", "#81a4cd", "#6fbfa9", "#e0b46a", "#a39b8d"].map { RGBA(hex: $0) },
            backface: RGBA(hex: "#3a332a"),
            reliefLand: Colormap(hex: ["#3b3a28", "#4a432c", "#584a33", "#5f4f3e", "#5a5048", "#bdb6a9"]),
            reliefSea: Colormap(hex: ["#0d1413", "#131c1b", "#18211f", "#1c2422", "#25302d"]), hillshade: 0.55,
            colormaps: scales(density: Palette.magma, heat: Colormap(hex: ["#14110d", "#3d2216", "#7a3a22", "#c0682f", "#efb35c", "#fbecc7"]))))

    // MARK: Blueprint

    public static let blueprint = Palette(
        id: "blueprint", name: "Blueprint",
        summary: "Shades of blue with pale linework, like a technical drawing",
        light: PaletteStyle(
            background: RGBA(hex: "#edf3f9"), ocean: RGBA(hex: "#d8e5f2"), land: RGBA(hex: "#f7fafd"),
            coastline: RGBA(hex: "#0a2540", alpha: 0.65), graticule: RGBA(hex: "#0a2540", alpha: 0.16),
            river: RGBA(hex: "#1a73c9"), border: RGBA(hex: "#0a2540", alpha: 0.45), cut: RGBA(hex: "#d6336c"),
            mesh: RGBA(hex: "#0a2540", alpha: 0.1), highlight: RGBA(hex: "#0a2540", alpha: 0.85),
            ink: RGBA(hex: "#0a2540"), secondaryInk: RGBA(hex: "#2b435a"), halo: RGBA(hex: "#f5f9fc", alpha: 0.85),
            night: RGBA(hex: "#0a2540", alpha: 0.28),
            categorical: ["#9bb5f4", "#8fc0c9", "#b9b8ea", "#92def2", "#7ab9e3", "#c3d4f6", "#a5c7d9"].map { RGBA(hex: $0) },
            city: RGBA(hex: "#0a2540"), route: RGBA(hex: "#1a5fb4", alpha: 0.22), wind: RGBA(hex: "#0a2540", alpha: 0.55),
            tissot: RGBA(hex: "#d6336c", alpha: 0.8),
            plateBoundaries: ["#d6336c", "#0a2540", "#1a8fd4", "#6b5bd6", "#5d7a99"].map { RGBA(hex: $0) },
            backface: RGBA(hex: "#9fb3c8"),
            reliefLand: Colormap(hex: ["#f7fafd", "#e7eef8", "#d4e0f2", "#bccde9", "#a5bbdf", "#ffffff"]),
            reliefSea: Colormap(hex: ["#8fb0d6", "#a8c2e0", "#bed2ea", "#d8e5f2", "#e6eef7"]), hillshade: 0.35,
            colormaps: scales(density: Colormap(hex: ["#f7fafd", "#bcd3f2", "#6f9be0", "#3159b5", "#0a2540"]),
                              heat: Colormap(hex: ["#f7fafd", "#bcd3f2", "#6f9be0", "#3159b5", "#0a2540"]),
                              rain: Colormap(hex: ["#f7fafd", "#d4e3f5", "#9ec2ea", "#5b93d6", "#2a5db3", "#0a2540"]),
                              wind: Colormap(hex: ["#f7fafd", "#cfe0f4", "#8fb6e6", "#4f86d0", "#1f4f9e"]))),
        dark: PaletteStyle(
            background: RGBA(hex: "#0a2240"), ocean: RGBA(hex: "#0d2a4d"), land: RGBA(hex: "#16406f"),
            coastline: RGBA(hex: "#e6f0ff", alpha: 0.75), graticule: RGBA(hex: "#d6e8ff", alpha: 0.16),
            river: RGBA(hex: "#7fd0ff"), border: RGBA(hex: "#d6e8ff", alpha: 0.5), cut: RGBA(hex: "#ff8fb7"),
            mesh: RGBA(hex: "#e6f0ff", alpha: 0.1), highlight: RGBA(hex: "#ffffff", alpha: 0.9),
            ink: RGBA(hex: "#f2f7ff"), secondaryInk: RGBA(hex: "#bbc6d5"), halo: RGBA(hex: "#0a2240", alpha: 0.8),
            night: RGBA(hex: "#020b18", alpha: 0.45),
            categorical: ["#1f4fa8", "#3b5f86", "#4f4fb8", "#1b7aa8", "#0f6672", "#3a6ec2", "#24447a"].map { RGBA(hex: $0) },
            city: RGBA(hex: "#e6f0ff"), route: RGBA(hex: "#8fc8ff", alpha: 0.28), wind: RGBA(hex: "#e6f0ff", alpha: 0.75),
            tissot: RGBA(hex: "#ff8fb7", alpha: 0.85),
            plateBoundaries: ["#ff8fb7", "#e6f0ff", "#7fd0ff", "#b6a5ff", "#8fb3dc"].map { RGBA(hex: $0) },
            backface: RGBA(hex: "#061a33"),
            reliefLand: Colormap(hex: ["#16406f", "#1b4a80", "#22558f", "#2b62a0", "#3870b0", "#9fc0e8"]),
            reliefSea: Colormap(hex: ["#06182f", "#0a2240", "#0b2647", "#0d2a4d", "#113258"]), hillshade: 0.45,
            colormaps: scales(density: Colormap(hex: ["#0a2240", "#1d4f8f", "#3a86c8", "#8fd0f0", "#f2fbff"]),
                              heat: Colormap(hex: ["#0a2240", "#1d4f8f", "#3a86c8", "#8fd0f0", "#f2fbff"]),
                              rain: Colormap(hex: ["#0a2240", "#123b6b", "#1d5f9a", "#3b8fca", "#8fd0f0", "#f2fbff"]))))

    // MARK: Midnight

    /// Glowing lines on near-black, made for the dark.
    public static let midnight = Palette(
        id: "midnight", name: "Midnight",
        summary: "Neon coastlines and glowing routes on deep black",
        light: PaletteStyle(
            background: RGBA(hex: "#f6f7fb"), ocean: RGBA(hex: "#eef1f8"), land: RGBA(hex: "#ffffff"),
            coastline: RGBA(hex: "#0284c7", alpha: 0.85), graticule: RGBA(hex: "#64748b", alpha: 0.16),
            river: RGBA(hex: "#0891b2"), border: RGBA(hex: "#7c3aed", alpha: 0.5), cut: RGBA(hex: "#db2777"),
            mesh: RGBA(hex: "#0f172a", alpha: 0.08), highlight: RGBA(hex: "#0f172a", alpha: 0.85),
            ink: RGBA(hex: "#0f172a"), secondaryInk: RGBA(hex: "#334155"), halo: RGBA(hex: "#ffffff", alpha: 0.85),
            night: RGBA(hex: "#1e1b4b", alpha: 0.3),
            categorical: ["#bae6fd", "#ddd6fe", "#fbcfe8", "#bbf7d0", "#fde68a", "#fecaca", "#c7d2fe"].map { RGBA(hex: $0) },
            city: RGBA(hex: "#be185d"), route: RGBA(hex: "#db2777", alpha: 0.22), wind: RGBA(hex: "#0f172a", alpha: 0.5),
            tissot: RGBA(hex: "#db2777", alpha: 0.8),
            plateBoundaries: ["#e11d48", "#2563eb", "#0d9488", "#d97706", "#64748b"].map { RGBA(hex: $0) },
            backface: RGBA(hex: "#cbd5e1"),
            reliefLand: Colormap(hex: ["#ffffff", "#f1f5f9", "#e2e8f0", "#cbd5e1", "#94a3b8", "#ffffff"]),
            reliefSea: Colormap(hex: ["#c7d2fe", "#dbe4fb", "#e6ecf9", "#eef1f8", "#f5f7fc"]), hillshade: 0.3,
            colormaps: scales(density: Colormap(hex: ["#ffffff", "#fbcfe8", "#f472b6", "#be185d", "#4a044e"]),
                              heat: Colormap(hex: ["#ffffff", "#fde68a", "#fb923c", "#db2777", "#581c87"]))),
        dark: PaletteStyle(
            background: RGBA(hex: "#03050a"), ocean: RGBA(hex: "#060a13"), land: RGBA(hex: "#18233a"),
            coastline: RGBA(hex: "#38bdf8", alpha: 0.9), graticule: RGBA(hex: "#94a3b8", alpha: 0.12),
            river: RGBA(hex: "#22d3ee", alpha: 0.85), border: RGBA(hex: "#a78bfa", alpha: 0.55), cut: RGBA(hex: "#f472b6"),
            mesh: RGBA(hex: "#e2e8f0", alpha: 0.07), highlight: RGBA(hex: "#f8fafc", alpha: 0.9),
            ink: RGBA(hex: "#f1f5f9"), secondaryInk: RGBA(hex: "#cbd5e1"), halo: RGBA(hex: "#03050a", alpha: 0.85),
            night: RGBA(hex: "#000000", alpha: 0.55),
            categorical: ["#0e3a5c", "#3b1f5c", "#5c1f45", "#123f36", "#4a3a10", "#4a1d1d", "#1e2a5c"].map { RGBA(hex: $0) },
            city: RGBA(hex: "#fde68a"), route: RGBA(hex: "#f59e0b", alpha: 0.32), wind: RGBA(hex: "#e0f2fe", alpha: 0.85),
            tissot: RGBA(hex: "#f472b6", alpha: 0.9),
            plateBoundaries: ["#fb7185", "#60a5fa", "#2dd4bf", "#fbbf24", "#94a3b8"].map { RGBA(hex: $0) },
            backface: RGBA(hex: "#1e293b"),
            reliefLand: Colormap(hex: ["#121a28", "#162033", "#1b273d", "#212f47", "#2a3a55", "#64748b"]),
            reliefSea: Colormap(hex: ["#020408", "#03060c", "#040810", "#060a13", "#0a1220"]), hillshade: 0.6,
            colormaps: scales(density: Colormap(hex: ["#03050a", "#2e1065", "#7e22ce", "#db2777", "#fb923c", "#fde68a"]),
                              heat: Colormap(hex: ["#03050a", "#3b0764", "#9d174d", "#ea580c", "#facc15", "#fefce8"]),
                              rain: Colormap(hex: ["#03050a", "#0c2340", "#0e4a6e", "#0e7490", "#22d3ee", "#a5f3fc"]),
                              wind: Colormap(hex: ["#03050a", "#0c4a6e", "#0e7490", "#14b8a6", "#a3e635", "#fefce8"]),
                              landness: Colormap(hex: ["#03050a", "#0c4a6e", "#38bdf8", "#facc15", "#f97316"]),
                              distance: Colormap(hex: ["#020617", "#0c4a6e", "#0ea5e9", "#e2e8f0", "#f59e0b", "#b45309", "#451a03"]))))

    // MARK: Ink

    public static let ink = Palette(
        id: "ink", name: "Ink",
        summary: "Black ink on white paper, or chalk on slate",
        light: PaletteStyle(
            background: RGBA(hex: "#ffffff"), ocean: RGBA(hex: "#ffffff"), land: RGBA(hex: "#ececec"),
            coastline: RGBA(hex: "#111111", alpha: 0.9), graticule: RGBA(hex: "#111111", alpha: 0.15),
            river: RGBA(hex: "#111111", alpha: 0.6), border: RGBA(hex: "#111111", alpha: 0.5), cut: RGBA(hex: "#111111"),
            mesh: RGBA(hex: "#111111", alpha: 0.1), highlight: RGBA(hex: "#111111"),
            ink: RGBA(hex: "#111111"), secondaryInk: RGBA(hex: "#444444"), halo: RGBA(hex: "#ffffff", alpha: 0.9),
            night: RGBA(hex: "#000000", alpha: 0.18),
            categorical: ["#f7f7f7", "#d9d9d9", "#b9b9b9", "#e8e8e8", "#c9c9c9", "#a6a6a6"].map { RGBA(hex: $0) },
            city: RGBA(hex: "#111111"), route: RGBA(hex: "#111111", alpha: 0.12), wind: RGBA(hex: "#111111", alpha: 0.6),
            tissot: RGBA(hex: "#111111", alpha: 0.8),
            plateBoundaries: ["#111111", "#444444", "#777777", "#222222", "#999999"].map { RGBA(hex: $0) },
            backface: RGBA(hex: "#9a9a9a"),
            reliefLand: Colormap(hex: ["#f2f2f2", "#e2e2e2", "#d2d2d2", "#c2c2c2", "#b2b2b2", "#fafafa"]),
            reliefSea: Colormap(hex: ["#d6d6d6", "#e4e4e4", "#f0f0f0", "#fafafa", "#ffffff"]), hillshade: 0.5,
            colormaps: scales(density: Colormap(hex: ["#ffffff", "#bdbdbd", "#6e6e6e", "#111111"]),
                              heat: Colormap(hex: ["#ffffff", "#bdbdbd", "#6e6e6e", "#111111"]),
                              rain: Colormap(hex: ["#ffffff", "#bdbdbd", "#6e6e6e", "#111111"]),
                              wind: Colormap(hex: ["#ffffff", "#bdbdbd", "#6e6e6e", "#111111"]),
                              landness: Colormap(hex: ["#ffffff", "#bdbdbd", "#6e6e6e", "#111111"]),
                              distance: Colormap(hex: ["#3a3a3a", "#9a9a9a", "#ffffff", "#9a9a9a", "#3a3a3a"]),
                              terrain: Colormap(hex: ["#f2f2f2", "#cfcfcf", "#a0a0a0", "#ffffff"]),
                              sequential: Colormap(hex: ["#ffffff", "#bdbdbd", "#6e6e6e", "#111111"]))),
        dark: PaletteStyle(
            background: RGBA(hex: "#111213"), ocean: RGBA(hex: "#111213"), land: RGBA(hex: "#232426"),
            coastline: RGBA(hex: "#f2f2f2", alpha: 0.85), graticule: RGBA(hex: "#f2f2f2", alpha: 0.12),
            river: RGBA(hex: "#f2f2f2", alpha: 0.5), border: RGBA(hex: "#f2f2f2", alpha: 0.4), cut: RGBA(hex: "#f2f2f2"),
            mesh: RGBA(hex: "#f2f2f2", alpha: 0.08), highlight: RGBA(hex: "#ffffff"),
            ink: RGBA(hex: "#f2f2f2"), secondaryInk: RGBA(hex: "#c4c4c4"), halo: RGBA(hex: "#111213", alpha: 0.9),
            night: RGBA(hex: "#000000", alpha: 0.35),
            categorical: ["#232426", "#3b3c3f", "#54555a", "#2f3033", "#47484c", "#606166"].map { RGBA(hex: $0) },
            city: RGBA(hex: "#f2f2f2"), route: RGBA(hex: "#f2f2f2", alpha: 0.14), wind: RGBA(hex: "#f2f2f2", alpha: 0.7),
            tissot: RGBA(hex: "#f2f2f2", alpha: 0.8),
            plateBoundaries: ["#f2f2f2", "#bdbdbd", "#8a8a8a", "#dedede", "#6e6e6e"].map { RGBA(hex: $0) },
            backface: RGBA(hex: "#3a3a3a"),
            reliefLand: Colormap(hex: ["#232426", "#2e2f31", "#3a3b3d", "#47484a", "#555658", "#9a9a9a"]),
            reliefSea: Colormap(hex: ["#0a0b0c", "#0d0e0f", "#0f1011", "#111213", "#151617"]), hillshade: 0.6,
            colormaps: scales(density: Colormap(hex: ["#111213", "#4a4a4a", "#9a9a9a", "#f2f2f2"]),
                              heat: Colormap(hex: ["#111213", "#4a4a4a", "#9a9a9a", "#f2f2f2"]),
                              rain: Colormap(hex: ["#111213", "#4a4a4a", "#9a9a9a", "#f2f2f2"]),
                              wind: Colormap(hex: ["#111213", "#4a4a4a", "#9a9a9a", "#f2f2f2"]),
                              landness: Colormap(hex: ["#111213", "#4a4a4a", "#9a9a9a", "#f2f2f2"]),
                              distance: Colormap(hex: ["#d0d0d0", "#6e6e6e", "#111213", "#6e6e6e", "#d0d0d0"]),
                              terrain: Colormap(hex: ["#2e2f31", "#4a4b4d", "#77787a", "#e0e0e0"]),
                              sequential: Colormap(hex: ["#111213", "#4a4a4a", "#9a9a9a", "#f2f2f2"]))))

    // MARK: Terra

    /// Natural colours: bathymetry, hypsometric tints and hill shading.
    public static let terra = Palette(
        id: "terra", name: "Terra",
        summary: "Natural colours: green lowlands, brown mountains, deep blue sea",
        light: PaletteStyle(
            background: RGBA(hex: "#eef0ee"), ocean: RGBA(hex: "#a9cbe4"), land: RGBA(hex: "#d9d4a8"),
            coastline: RGBA(hex: "#2f3b2f", alpha: 0.45), graticule: RGBA(hex: "#24313f", alpha: 0.2),
            river: RGBA(hex: "#2f6fb5"), border: RGBA(hex: "#5a4630", alpha: 0.55), cut: RGBA(hex: "#c0392b"),
            mesh: RGBA(hex: "#1b1b1b", alpha: 0.1), highlight: RGBA(hex: "#111111", alpha: 0.85),
            ink: RGBA(hex: "#16201a"), secondaryInk: RGBA(hex: "#3d4a40"), halo: RGBA(hex: "#f4f6f2", alpha: 0.85),
            night: RGBA(hex: "#08142e", alpha: 0.42),
            categorical: ["#a9c98f", "#e2b07a", "#d9cf8a", "#9ab7d6", "#c9a3c6", "#8fc8b6", "#e0a2a2"].map { RGBA(hex: $0) },
            city: RGBA(hex: "#7a1f12"), route: RGBA(hex: "#9a3412", alpha: 0.25), wind: RGBA(hex: "#ffffff", alpha: 0.85),
            tissot: RGBA(hex: "#c0392b", alpha: 0.8),
            plateBoundaries: ["#d1495b", "#253b6e", "#00798c", "#d6942c", "#5c5a54"].map { RGBA(hex: $0) },
            backface: RGBA(hex: "#6d7a73"),
            reliefLand: Palette.terrainLand, reliefSea: Palette.terrainSea, hillshade: 0.55,
            colormaps: scales(density: Colormap(hex: ["#f4f1e8", "#f2cf8f", "#e58f55", "#c4473b", "#6e1f3f"]),
                              heat: Colormap(hex: ["#f4f1e8", "#f2cf8f", "#e58f55", "#c4473b", "#6e1f3f"]))),
        dark: PaletteStyle(
            background: RGBA(hex: "#0b0f12"), ocean: RGBA(hex: "#10263e"), land: RGBA(hex: "#3b4a35"),
            coastline: RGBA(hex: "#e8efe6", alpha: 0.4), graticule: RGBA(hex: "#e8efe6", alpha: 0.14),
            river: RGBA(hex: "#7ab8ff"), border: RGBA(hex: "#e8dcc4", alpha: 0.45), cut: RGBA(hex: "#ff7b69"),
            mesh: RGBA(hex: "#ffffff", alpha: 0.08), highlight: RGBA(hex: "#ffffff", alpha: 0.9),
            ink: RGBA(hex: "#f1f4ee"), secondaryInk: RGBA(hex: "#c8cfc4"), halo: RGBA(hex: "#0b0f12", alpha: 0.8),
            night: RGBA(hex: "#000000", alpha: 0.55),
            categorical: ["#5f7f4a", "#a26a3f", "#9a8f45", "#4f6f96", "#7d5c7a", "#4b8273", "#9a5a5a"].map { RGBA(hex: $0) },
            city: RGBA(hex: "#ffd68a"), route: RGBA(hex: "#ffb36b", alpha: 0.3), wind: RGBA(hex: "#ffffff", alpha: 0.8),
            tissot: RGBA(hex: "#ff8a7a", alpha: 0.85),
            plateBoundaries: ["#ff6b7f", "#7fb0ff", "#3fd0c9", "#ffc061", "#a8a49b"].map { RGBA(hex: $0) },
            backface: RGBA(hex: "#1f2a24"),
            reliefLand: Colormap(hex: ["#2f5a34", "#4f7340", "#7d7f4a", "#7d6146", "#6b5a50", "#cfcac2"]),
            reliefSea: Colormap(hex: ["#050d1a", "#0a1a30", "#0f2742", "#173a5c", "#2a5a80"]), hillshade: 0.6,
            colormaps: scales(density: Palette.magma, heat: Colormap(hex: ["#0b0f12", "#3a1435", "#8c2240", "#d9542f", "#f9a740", "#fff3c9"]))))
}
