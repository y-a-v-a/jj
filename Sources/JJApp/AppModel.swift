import AppKit
import MyriaCore
import MyriaData
import MyriaLayouts
import MyriaRender
import Observation
import SwiftUI

/// Light, dark or following the system.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Pan and zoom chosen by the user; the view supplies its size.
struct MapCamera: Equatable {
    var zoom: Double = 1
    /// Map point at the centre of the view; nil centres the map.
    var center: Vec2?
}

/// What the pointer is over.
struct HoverInfo: Equatable {
    var location: GeoPoint
    var viewPoint: CGPoint
    var face: Int
    var lines: [HoverLine]
}

struct HoverLine: Equatable, Identifiable {
    var id: String { label }
    var label: String
    var value: String
}

/// A label drawn over the map.
struct MapLabel: Identifiable, Sendable {
    enum Kind: Sendable { case region, clock, city, ocean }

    let id: Int
    let kind: Kind
    let position: Vec2
    let text: String
    /// Room around the label in map units; small labels hide when zoomed out.
    let room: Double
    /// For clocks: the zone whose time to show.
    let timeZone: TimeZone?
}

/// A fold → swap → unfold transition between two maps.
struct Transition {
    enum Phase { case folding, waiting, unfolding }
    var phase: Phase
    var start: CFTimeInterval
    var from: Double
    var duration: CFTimeInterval
}

@MainActor @Observable
final class AppModel {
    private var engines: [String: MapEngine] = [:]

    /// The engine of the current body (each body keeps its own meshes).
    var engine: MapEngine {
        if let e = engines[bodyID] { return e }
        let e = MapEngine(data: BodyData.of(body), capacity: 8)
        engines[bodyID] = e
        return e
    }

    var catalog: [any MapLayout] { LayoutCatalog.available(for: body) }

    // MARK: Choices

    var bodyID: String = UserDefaults.standard.string(forKey: "body") ?? "earth" {
        didSet {
            guard bodyID != oldValue else { return }
            UserDefaults.standard.set(bodyID, forKey: "body")
            arriveAsGlobe = true
            if !catalog.contains(where: { $0.descriptor.id == layoutID }) {
                switchingBody = true
                layoutID = catalog.first?.descriptor.id ?? layoutID
                switchingBody = false
            }
            coloringOverride = nil
            layerOverrides = [:]
            selectedGroup = nil
            rebuild()
            refreshThumbnails()
        }
    }

    var body: CelestialBody { CelestialBody.all.first { $0.id == bodyID } ?? .earth }
    private var switchingBody = false
    /// The next map arrives as a globe and unfolds (launch, new body).
    private var arriveAsGlobe = true

    var layoutID: String = UserDefaults.standard.string(forKey: "layout") ?? "coastline" {
        didSet {
            guard layoutID != oldValue else { return }
            UserDefaults.standard.set(layoutID, forKey: "layout")
            coloringOverride = nil
            layerOverrides = [:]
            selectedGroup = nil
            if !switchingBody { rebuild(transition: true) }
        }
    }

    /// Parameter values per body and layout ("mars/waterline").
    var parameterValues: [String: [String: Double]] = [:]
    /// The user's mesh per body and layout; nil uses the layout's own.
    var meshChoices: [String: MeshKind] = [:]
    /// Key for per-layout choices.
    var choiceKey: String { "\(bodyID)/\(layoutID)" }

    var paletteID: String = UserDefaults.standard.string(forKey: "palette") ?? Palette.vanWijk.id {
        didSet { UserDefaults.standard.set(paletteID, forKey: "palette") }
    }

    var appearance: AppearanceMode = AppearanceMode(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            NSApplication.shared.appearance = appearance.nsAppearance
        }
    }

    /// Whether the effective appearance is dark (set by the view).
    var isDark = false
    var coloringOverride: LayoutAppearance.Coloring?
    var layerOverrides: [LayerID: Bool] = [:]
    var sealSlits = UserDefaults.standard.object(forKey: "sealSlits") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sealSlits, forKey: "sealSlits") }
    }
    var lineWeight = UserDefaults.standard.object(forKey: "lineWeight") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(lineWeight, forKey: "lineWeight") }
    }
    var graticuleStep = UserDefaults.standard.object(forKey: "graticuleStep") as? Double ?? 15 {
        didSet { UserDefaults.standard.set(graticuleStep, forKey: "graticuleStep") }
    }
    var showStory = UserDefaults.standard.object(forKey: "showStory") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showStory, forKey: "showStory") }
    }

    // MARK: Time

    var now = Date()
    var timeOffset: TimeInterval = 0 {
        didSet { timeChanged() }
    }
    var date: Date { now.addingTimeInterval(timeOffset) }
    private var lastCutMinute = -1

    // MARK: View state

    /// 0 is the globe, 1 the flat map (the value the slider shows).
    var unfold: Double = 1
    /// Rotation of the globe while folded.
    var globe: Mat3 = .identity
    var camera = MapCamera()
    var transition: Transition?
    /// A fold animation that is not a transition.
    var foldAnimation: Transition?
    var hover: HoverInfo?
    var selectedGroup: Int?

    // MARK: Output

    private(set) var state: MapState?
    /// The state being built for a transition.
    private var pending: MapState?
    private(set) var isBuilding = false
    private(set) var status = "Unfolding the Earth…"
    private(set) var labels: [MapLabel] = []
    private(set) var thumbnails: [String: NSImage] = [:]
    private var buildTask: Task<Void, Never>?
    private var buildGeneration = 0
    private var clock: Timer?
    /// Cycling through the gallery, folding and unfolding between layouts.
    private(set) var isTouring = false
    private var tourTimer: Timer?

    init() {
        NSApplication.shared.appearance = appearance.nsAppearance
        if CelestialBody.all.first(where: { $0.id == bodyID }) == nil { bodyID = "earth" }
        if catalog.first(where: { $0.descriptor.id == layoutID }) == nil { layoutID = catalog[0].descriptor.id }
    }

    // MARK: Derived

    var layout: any MapLayout { catalog.first { $0.descriptor.id == layoutID } ?? catalog[0] }
    var descriptor: LayoutDescriptor { layout.descriptor(for: body) }
    var palette: Palette { Palette.named(paletteID) ?? .vanWijk }
    var style: PaletteStyle { palette.style(dark: isDark) }

    var parameters: LayoutParameters {
        var p = layout.defaultParameters(for: body)
        for (k, v) in parameterValues[choiceKey] ?? [:] { p[k] = v }
        p.date = date
        return p
    }

    func parameterBinding(_ id: String) -> Binding<Double> {
        Binding(
            get: { self.parameters[id] ?? 0 },
            set: { value in
                guard self.parameterValues[self.choiceKey]?[id] != value else { return }
                self.parameterValues[self.choiceKey, default: [:]][id] = value
                self.rebuild()
            })
    }

    func setParameter(_ id: String, _ value: Double) {
        parameterValues[choiceKey, default: [:]][id] = value
    }

    var meshKind: MeshKind { meshChoices[choiceKey] ?? descriptor.preferredMesh }

    func setMesh(_ kind: MeshKind?) {
        meshChoices[choiceKey] = kind
        rebuild()
    }

    var coloring: LayoutAppearance.Coloring {
        coloringOverride ?? state?.appearance.coloring ?? layout.appearance(parameters).coloring
    }

    var layers: Set<LayerID> {
        let appearance = state?.appearance ?? layout.appearance(parameters)
        var set = LayerID.defaults(for: appearance)
        for (layer, on) in layerOverrides {
            if on { set.insert(layer) } else { set.remove(layer) }
        }
        return set.filter(isAvailable)
    }

    /// Whether the current body has what a layer shows.
    func isAvailable(_ layer: LayerID) -> Bool {
        if layer == .night { return body.id == "earth" }
        return layer.dataset.map(body.has) ?? true
    }

    func layerBinding(_ layer: LayerID) -> Binding<Bool> {
        Binding(get: { self.layers.contains(layer) }, set: { self.layerOverrides[layer] = $0 })
    }

    // MARK: Building

    func start() {
        guard state == nil, buildTask == nil else { return }
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Launch arguments for demos and checks: -zoom 3 -unfold 0.4 -tour YES
        let defaults = UserDefaults.standard
        launchZoom = defaults.string(forKey: "zoom").flatMap(Double.init)
        launchUnfold = defaults.string(forKey: "unfold").flatMap(Double.init)
        rebuild()
        renderThumbnails()
        if defaults.bool(forKey: "tour") { toggleTour() }
        // Load what hover cards and layers read, so the first use doesn't stall.
        let data = engine.data
        Task.detached(priority: .utility) {
            _ = try? data.regions(.countries)
            _ = try? data.timeZones()
            _ = try? data.regions(.plates)
            _ = try? data.places()
            _ = try? data.field(FieldKey("elevation"))
            _ = try? data.wind()
        }
    }

    private var launchUnfold: Double?
    private var launchZoom: Double?

    /// Starts or stops the tour of all layouts.
    func toggleTour() {
        isTouring.toggle()
        tourTimer?.invalidate()
        tourTimer = nil
        guard isTouring else { return }
        tourTimer = Timer.scheduledTimer(withTimeInterval: 9, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.transition == nil, !self.isBuilding else { return }
                self.selectNext(1)
            }
        }
    }

    private func tick() {
        now = Date()
        timeChanged()
    }

    private func timeChanged() {
        // Time-dependent layouts re-cut once a minute of shown time.
        guard descriptor.isTimeDependent || (descriptor.id == "timezones" && parameters.index("grouping") == 1) else { return }
        let minute = Int(date.timeIntervalSince1970 / 60)
        guard minute != lastCutMinute, !isBuilding else { return }
        lastCutMinute = minute
        rebuild()
    }

    /// Builds the map for the current choices off the main thread.
    /// - Parameter transition: fold the old map into a globe first and
    ///   unfold the new one from it.
    func rebuild(transition: Bool = false) {
        buildTask?.cancel()
        buildGeneration += 1
        let generation = buildGeneration
        let layout = self.layout, parameters = self.parameters, mesh = MeshSpec(meshKind), engine = self.engine
        isBuilding = true
        status = "Cutting \(descriptor.title.lowercased())…"
        lastCutMinute = Int(date.timeIntervalSince1970 / 60)
        let animate = transition && state != nil && state?.data.body == body
        if animate { beginTransition() }
        let layers = defaultLayers(for: layout, parameters: parameters)
        let coloring = coloringOverride
        buildTask = Task {
            let result: Result<MapState, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let state = try engine.build(layout, parameters: parameters, mesh: mesh)
                    Self.prewarm(state, layers: layers, coloring: coloring ?? state.appearance.coloring)
                    return .success(state)
                } catch {
                    return .failure(error)
                }
            }.value
            guard generation == buildGeneration, !Task.isCancelled else { return }
            isBuilding = false
            switch result {
            case .success(let new):
                if animate {
                    pending = new
                    if self.transition?.phase == .waiting { swapInPending() }
                } else {
                    install(new, resetCamera: self.state?.context.spec != new.context.spec || self.state?.layout.id != new.layout.id
                        || self.state?.data.body != new.data.body)
                }
            case .failure(let error):
                status = "Could not build the map: \(error)"
                self.transition = nil
            }
        }
    }

    private func defaultLayers(for layout: any MapLayout, parameters: LayoutParameters) -> Set<LayerID> {
        var set = LayerID.defaults(for: layout.appearance(parameters))
        for (layer, on) in layerOverrides {
            if on { set.insert(layer) } else { set.remove(layer) }
        }
        return set
    }

    /// Computes overlays and fields the first frame will need, so that the
    /// main thread only uploads them.
    nonisolated static func prewarm(_ state: MapState, layers: Set<LayerID>, coloring: LayoutAppearance.Coloring) {
        let o = state.overlays, data = state.data
        if layers.contains(.land) { _ = try? o.fills(.land) }
        if layers.contains(.lakes) { _ = try? o.fills(.lakes); _ = try? o.lines(.lakes) }
        if layers.contains(.coastlines) { _ = try? o.coastlines() }
        if layers.contains(.rivers) { _ = try? o.lines(.rivers) }
        if layers.contains(.countryBorders) { _ = try? o.lines(.countryBorders) }
        if layers.contains(.timeZoneBorders) { _ = try? o.lines(.timeZones) }
        if layers.contains(.plateBoundaries) { _ = try? o.lines(.plateBoundaries) }
        if layers.contains(.flights) { _ = try? o.flightArcs(limit: 2500); _ = try? o.flightArcs(limit: 1200) }
        if layers.contains(.cities) { _ = try? o.cities() }
        switch coloring {
        case .regions(let dataset): _ = try? o.fills(dataset); _ = try? state.context.faceRegions(dataset)
        case .field(let key): _ = try? data.field(key)
        default: break
        }
        _ = try? data.field(FieldKey("elevation"))
    }

    private func install(_ new: MapState, resetCamera: Bool) {
        let first = state == nil
        state = new
        if resetCamera {
            camera = MapCamera()
            globe = Self.facingRoot(new)
        }
        // The first map arrives as a globe and unfolds: unfolding the Earth.
        if (first || arriveAsGlobe) && launchUnfold == nil {
            arriveAsGlobe = false
            globe = Self.facingRoot(new)
            unfold = 0
            foldAnimation = Transition(phase: .unfolding, start: CACurrentMediaTime() + 0.35, from: 0, duration: 2.6)
        }
        hover = nil
        status = Self.describe(new)
        computeLabels()
        if let u = launchUnfold {
            launchUnfold = nil
            unfold = u
        }
        if let z = launchZoom {
            launchZoom = nil
            camera.zoom = z
        }
    }

    static func describe(_ s: MapState) -> String {
        let cuts = s.projection.cutEdges.count
        let total = s.timings.reduce(0) { $0 + $1.1 }
        return "\(s.mesh.cellCount.formatted()) polygons · \(cuts.formatted()) cuts · built in \(String(format: "%.2f", total)) s"
    }

    /// The globe turned so the map's root face looks at the viewer, north up.
    static func facingRoot(_ state: MapState) -> Mat3 {
        let f = state.mesh.frames[state.projection.unfolding.root]
        // Rows of the root frame: globe → root-local.
        return Mat3(Vec3(f.xAxis.x, f.yAxis.x, f.normal.x), Vec3(f.xAxis.y, f.yAxis.y, f.normal.y),
                    Vec3(f.xAxis.z, f.yAxis.z, f.normal.z))
    }

    // MARK: Transitions and folding

    static let foldDuration: CFTimeInterval = 1.0
    static let unfoldDuration: CFTimeInterval = 1.5

    private func beginTransition() {
        foldAnimation = nil
        transition = Transition(phase: .folding, start: CACurrentMediaTime(), from: unfold,
                                duration: Self.foldDuration * max(unfold, 0.25))
        hover = nil
    }

    /// Advances animations; returns the unfold value to draw. Called by the
    /// map view every frame while something moves.
    func animationStep(at time: CFTimeInterval) -> Double {
        if var t = transition {
            let p = min(1, (time - t.start) / max(t.duration, 1e-3))
            switch t.phase {
            case .folding:
                unfold = t.from * (1 - Self.ease(p))
                if p >= 1 {
                    unfold = 0
                    t.phase = .waiting
                    transition = t
                    if pending != nil { swapInPending() }
                }
            case .waiting:
                unfold = 0
            case .unfolding:
                unfold = Self.ease(p)
                if p >= 1 {
                    unfold = 1
                    transition = nil
                    if let state { globe = Self.facingRoot(state) }
                }
            }
        } else if let a = foldAnimation {
            let p = max(0, min(1, (time - a.start) / max(a.duration, 1e-3)))
            let target: Double = a.from >= 0.5 ? 0 : 1
            unfold = a.from + (target - a.from) * Self.ease(p)
            if p >= 1 { foldAnimation = nil }
        }
        return unfold
    }

    var isAnimating: Bool { transition != nil || foldAnimation != nil }

    private func swapInPending() {
        guard let new = pending else { return }
        pending = nil
        // Same globe orientation: the closed maps coincide, so the swap is invisible.
        state = new
        camera = MapCamera()
        status = Self.describe(new)
        computeLabels()
        transition = Transition(phase: .unfolding, start: CACurrentMediaTime(), from: 0, duration: Self.unfoldDuration)
    }

    /// Van Wijk's animation, α′ = α(1 + cos(πt/T))/2, is this ease.
    static func ease(_ t: Double) -> Double { (1 - cos(.pi * min(max(t, 0), 1))) / 2 }

    /// Folds the map into a globe, or unfolds it.
    func toggleFold() {
        guard transition == nil else { return }
        if unfold >= 1, let state { globe = Self.facingRoot(state) }
        foldAnimation = Transition(phase: .folding, start: CACurrentMediaTime(), from: unfold,
                                   duration: Self.unfoldDuration * (unfold >= 0.5 ? unfold : 1 - unfold))
    }

    func rotateGlobe(by delta: CGSize) {
        let k = 0.006
        let yaw = Mat3.rotation(axis: .unitY, angle: Double(delta.width) * k)
        let pitch = Mat3.rotation(axis: .unitX, angle: Double(delta.height) * k)
        globe = yaw * pitch * globe
    }

    // MARK: Navigation

    func selectNext(_ step: Int) {
        guard let i = catalog.firstIndex(where: { $0.descriptor.id == layoutID }) else { return }
        layoutID = catalog[(i + step + catalog.count) % catalog.count].descriptor.id
    }

    // MARK: Hover

    /// - Parameter slack: map units of gap still counted as the face beside it.
    func hover(at q: Vec2, viewPoint: CGPoint, slack: Double = 0) {
        guard let state, unfold >= 1, let (face, location) = state.location(atMapPoint: q, slack: slack) else {
            hover = nil
            return
        }
        hover = HoverInfo(location: location, viewPoint: viewPoint, face: face, lines: describe(location, state: state))
    }

    func hoverGlobe(at p: Vec3, viewPoint: CGPoint) {
        guard let state else { return }
        let location = GeoPoint(p)
        hover = HoverInfo(location: location, viewPoint: viewPoint, face: state.mesh.face(containing: p),
                          lines: describe(location, state: state))
    }

    private func describe(_ p: GeoPoint, state: MapState) -> [HoverLine] {
        let data = state.data
        var lines: [HoverLine] = []
        func add(_ label: String, _ value: String?) { if let value, !value.isEmpty { lines.append(HoverLine(label: label, value: value)) } }
        let layers = self.layers
        let id = state.layout.id
        if data.body.has(.land), let land = try? data.land() {
            add("Surface", land.isLand(p) ? "Land" : OceanBasin(p).title)
        }
        if data.body.has(.countries), let c = try? data.regions(.countries).region(at: p) { add("Country", c.name) }
        if data.body.has(.features), let near = try? data.features().nearest(to: p.unitVector) {
            let km = near.distance * data.body.radius
            add(near.feature.type.isEmpty ? "Feature" : near.feature.type,
                km < near.feature.diameter / 2 ? near.feature.name : "\(near.feature.name), \(Int(km).formatted()) km away")
        }
        if data.body.has(.timeZones), id == "timezones" || layers.contains(.timeZoneBorders), let zone = try? data.timeZones().zone(at: p) {
            add("Time", "\(zone.clockTime(at: date)) · \(zone.placeName) · \(zone.offsetLabel(at: date))")
        }
        if data.body.has(.plates), id == "tectonic" || layers.contains(.plateBoundaries), let plate = try? data.regions(.plates).region(at: p) {
            add("Plate", plate.name)
        }
        if let e = try? data.field(FieldKey("elevation")) {
            let h = e.value(at: p)
            add(h >= 0 ? "Elevation" : "Depth", "\(Int(abs(h)).formatted()) m")
        }
        switch coloring {
        case .field(let key):
            if let field = try? data.field(key), let d = data.body.field(key.id) {
                let v = field.value(at: p)
                let text: String = switch key.id {
                case "population": "\(Int(pow(10, v) - 1).formatted()) per km²"
                case "flights": String(format: "%.1f", v) + " (log)"
                case "coastDistance": "\(Int(abs(v)).formatted()) km \(v >= 0 ? "inland" : "offshore")"
                case "landDensity": String(format: "%.2f", v)
                default: String(format: "%.1f %@", v, d.units)
                }
                add(d.title, text)
            }
        default: break
        }
        if id == "winds", let wind = try? data.wind(monthVariant(parameters)) {
            let w = wind.vector(at: p.unitVector)
            let (east, north) = Spherical.tangentFrame(at: p.unitVector)
            let speed = w.length
            let toward = atan2(w.dot(east), w.dot(north)) * 180 / .pi
            let from = (toward + 180).truncatingRemainder(dividingBy: 360)
            add("Wind", String(format: "%.1f m/s from %@", speed, Self.compass((from + 360).truncatingRemainder(dividingBy: 360))))
        }
        if data.body.id == "earth", id == "day-night" || layers.contains(.night) {
            add("Sun", String(format: "%.1f° %@", abs(SolarPosition.elevation(at: p, date: date)),
                              SolarPosition.elevation(at: p, date: date) >= 0 ? "above the horizon" : "below the horizon"))
        }
        if data.body.has(.places), let place = try? data.places().nearest(to: p.unitVector), place.distance * data.body.radius < 300 {
            add("Near", "\(place.place.name), \(place.place.country)")
        }
        return lines
    }

    private func monthVariant(_ p: LayoutParameters) -> String {
        let m = p.index("month", default: 0)
        return m == 0 ? "annual" : String(format: "%02d", m)
    }

    static func compass(_ degrees: Double) -> String {
        let names = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        return names[Int((degrees / 22.5).rounded()) % 16]
    }

    // MARK: Labels

    private func computeLabels() {
        guard let state else { return }
        let coloring = self.coloring
        let layers = self.layers
        Task {
            let result = await Task.detached(priority: .utility) {
                LabelPlacer.labels(for: state, coloring: coloring, layers: layers)
            }.value
            if self.state === state { labels = result }
        }
    }

    func refreshLabels() { computeLabels() }

    // MARK: Thumbnails

    private var thumbnailTask: Task<Void, Never>?

    private func renderThumbnails() {
        thumbnailTask?.cancel()
        let catalog = self.catalog, body = self.body
        let palette = self.palette, dark = isDark
        thumbnailTask = Task {
            for layout in catalog {
                let id = layout.descriptor.id
                let image = await Task.detached(priority: .background) { () -> CGImage? in
                    Thumbnails.render(layout, body: body, palette: palette, dark: dark)
                }.value
                guard !Task.isCancelled, body == self.body else { return }
                if let image { thumbnails[id] = NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2)) }
            }
        }
    }

    func refreshThumbnails() {
        thumbnails = [:]
        renderThumbnails()
    }
}
