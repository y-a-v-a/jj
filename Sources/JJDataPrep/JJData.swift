import ArgumentParser
import Foundation

/// `jj-data`: downloads open datasets into `data/raw/` (cached) and writes
/// JJ's compact resources into `Sources/MyriaData/Resources/<Body>/` (Earth,
/// Moon, Mars).
@main
struct JJData: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jj-data",
        abstract: "Download open datasets and write JJ's compact Earth, Moon and Mars resources.",
        subcommands: [
            Rivers.self, Lakes.self, Countries.self, Plates.self, Places.self, Flights.self,
            Precipitation.self, Wind.self, Elevation.self, MoonData.self, MarsData.self, All.self, Verify.self,
        ]
    )
}

struct CommonOptions: ParsableArguments {
    @Option(help: "Package root (the directory containing Package.swift). Defaults to the nearest enclosing package of the current directory.")
    var root: String?

    func workspace() throws -> Workspace { try Workspace(root: root) }
}

/// Runs one named step, printing a header and the elapsed time.
func step(_ name: String, _ body: () throws -> Void) throws {
    print("== \(name)")
    let start = Date()
    try body()
    print(String(format: "   (%.1f s)", Date().timeIntervalSince(start)))
}

struct Rivers: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Natural Earth 1:50m rivers and lake centre lines → rivers.geojson")
    @OptionGroup var options: CommonOptions
    func run() throws { let ws = try options.workspace(); try step("rivers") { try VectorLayers.rivers(ws) } }
}

struct Lakes: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Natural Earth 1:50m lakes → lakes.geojson")
    @OptionGroup var options: CommonOptions
    func run() throws { let ws = try options.workspace(); try step("lakes") { try VectorLayers.lakes(ws) } }
}

struct Countries: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Natural Earth 1:50m countries and land borders → countries.geojson, country-borders.geojson")
    @OptionGroup var options: CommonOptions
    func run() throws {
        let ws = try options.workspace()
        try step("countries") { try VectorLayers.countries(ws) }
        try step("country borders") { try VectorLayers.countryBorders(ws) }
    }
}

struct Plates: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "PB2002 tectonic plates and boundaries → plates.geojson, plate-boundaries.geojson")
    @OptionGroup var options: CommonOptions
    func run() throws { let ws = try options.workspace(); try step("plates") { try TectonicPlates.run(ws) } }
}

struct Places: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Natural Earth 1:10m populated places → places.json")
    @OptionGroup var options: CommonOptions
    func run() throws { let ws = try options.workspace(); try step("places") { try PointLayers.places(ws) } }
}

struct Flights: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "OpenFlights airports and routes → flights.json")
    @OptionGroup var options: CommonOptions
    func run() throws { let ws = try options.workspace(); try step("flights") { try PointLayers.flights(ws) } }
}

struct Precipitation: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "GPCP v2.3 monthly precipitation climatology → precipitation.grid")
    @OptionGroup var options: CommonOptions
    func run() throws { let ws = try options.workspace(); try step("precipitation") { try ClimateGrids.precipitation(ws) } }
}

struct Wind: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "NCEP/NCAR Reanalysis 1 near-surface wind climatology → wind.grid")
    @OptionGroup var options: CommonOptions
    func run() throws { let ws = try options.workspace(); try step("wind") { try ClimateGrids.wind(ws) } }
}

struct Elevation: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "ETOPO1 ice-surface elevation via ERDDAP → elevation.grid")
    @OptionGroup var options: CommonOptions
    @Option(help: "Subsampling stride in arc-minutes (5 → 4320 × 2161, 6 → 3600 × 1801).")
    var stride: Int = 5
    func run() throws {
        let ws = try options.workspace()
        try step("elevation") { try ElevationGrid.run(ws, stride: stride) }
    }
}

struct MoonData: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "moon",
        abstract: "LRO LOLA LDEM_4 topography and IAU named features → Moon/elevation.grid, Moon/features.json")
    @OptionGroup var options: CommonOptions
    func run() throws {
        let ws = try options.workspace()
        try step("moon elevation") { try PlanetaryData.elevation(ws, PlanetaryData.moon) }
        try step("moon features") { try PlanetaryData.features(ws, PlanetaryData.moon) }
    }
}

struct MarsData: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mars",
        abstract: "MGS MOLA MEGDR 4 px/deg topography and IAU named features → Mars/elevation.grid, Mars/features.json")
    @OptionGroup var options: CommonOptions
    func run() throws {
        let ws = try options.workspace()
        try step("mars elevation") { try PlanetaryData.elevation(ws, PlanetaryData.mars) }
        try step("mars features") { try PlanetaryData.features(ws, PlanetaryData.mars) }
    }
}

struct All: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Build every resource, then verify them.")
    @OptionGroup var options: CommonOptions
    func run() throws {
        let ws = try options.workspace()
        try step("rivers") { try VectorLayers.rivers(ws) }
        try step("lakes") { try VectorLayers.lakes(ws) }
        try step("countries") { try VectorLayers.countries(ws) }
        try step("country borders") { try VectorLayers.countryBorders(ws) }
        try step("plates") { try TectonicPlates.run(ws) }
        try step("places") { try PointLayers.places(ws) }
        try step("flights") { try PointLayers.flights(ws) }
        try step("precipitation") { try ClimateGrids.precipitation(ws) }
        try step("wind") { try ClimateGrids.wind(ws) }
        try step("elevation") { try ElevationGrid.run(ws, stride: 5) }
        try step("moon elevation") { try PlanetaryData.elevation(ws, PlanetaryData.moon) }
        try step("moon features") { try PlanetaryData.features(ws, PlanetaryData.moon) }
        try step("mars elevation") { try PlanetaryData.elevation(ws, PlanetaryData.mars) }
        try step("mars features") { try PlanetaryData.features(ws, PlanetaryData.mars) }
        try step("verify") { try Verification.run(ws) }
    }
}

struct Verify: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Load every resource, print sizes and ranges, and run sanity checks.")
    @OptionGroup var options: CommonOptions
    func run() throws { let ws = try options.workspace(); try step("verify") { try Verification.run(ws) } }
}
