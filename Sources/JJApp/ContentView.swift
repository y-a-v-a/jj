import MyriaCore
import MyriaData
import MyriaLayouts
import MyriaRender
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            GalleryView(model: model)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 340)
        } detail: {
            MapArea(model: model)
                .navigationTitle(model.descriptor.title)
                .navigationSubtitle(model.status)
                .inspector(isPresented: $showInspector) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 260, ideal: 290, max: 380)
                }
                .toolbar { toolbar }
                .searchable(text: $model.searchText, placement: .toolbar, prompt: "Find a place")
                .searchSuggestions {
                    ForEach(model.searchResults) { place in
                        Button {
                            model.reveal(place)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(place.title)
                                Text(place.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onSubmit(of: .search) {
                    if let first = model.searchResults.first { model.reveal(first) }
                }
        }
        .onAppear {
            model.isDark = colorScheme == .dark
            model.start()
            // For demos and checks: -showSettings YES, -showAbout YES.
            if UserDefaults.standard.bool(forKey: "showSettings") { openSettings() }
            if UserDefaults.standard.bool(forKey: "showAbout") { openWindow(id: "about") }
        }
        .onChange(of: colorScheme) {
            model.isDark = colorScheme == .dark
            model.refreshThumbnails()
        }
        .onChange(of: model.paletteID) { model.refreshThumbnails() }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if model.descriptor.isTimeDependent || model.layers.contains(.night) || model.layoutID == "timezones" {
                TimeScrubber(model: model)
            }
            Button {
                model.toggleFold()
            } label: {
                Label(model.unfold >= 1 ? "Fold into a Globe" : "Unfold", systemImage: model.unfold >= 1 ? "globe" : "map")
            }
            .help(model.unfold >= 1 ? "Fold the map back into the globe (⌘G)" : "Unfold the globe into the map (⌘G)")
            .disabled(model.state == nil || model.transition != nil)
            Button {
                model.toggleTour()
            } label: {
                Label(model.isTouring ? "Stop the Tour" : "Tour", systemImage: model.isTouring ? "stop.circle" : "play.circle")
            }
            .help(model.isTouring ? "Stop touring the layouts" : "Tour every layout, folding and unfolding between them")
            ExportMenu(model: model)
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help("Show or hide the inspector")
        }
    }
}

// MARK: - The map with its overlays

struct MapArea: View {
    @Bindable var model: AppModel
    /// Frames of the cards floating over the map, which labels keep clear of.
    @State private var cards: [String: CGRect] = [:]

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                MapView(model: model)
                LabelLayer(model: model, size: geometry.size, occluded: Array(cards.values))
                    .allowsHitTesting(false)
                if let hover = model.hover {
                    HoverCard(info: hover)
                        .offset(x: min(hover.viewPoint.x + 18, geometry.size.width - 300),
                                y: min(hover.viewPoint.y + 18, geometry.size.height - 40 - CGFloat(hover.lines.count) * 18))
                        .allowsHitTesting(false)
                }
                if model.state == nil {
                    ProgressView(model.status)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay(alignment: .topLeading) {
                StoryCard(model: model).reportFrame("story", into: $cards).padding(14)
            }
            .overlay(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 10) {
                    FoldControl(model: model).reportFrame("fold", into: $cards)
                    Legend(model: model).reportFrame("legend", into: $cards)
                }
                .padding(14)
            }
            .overlay(alignment: .bottomTrailing) {
                ZoomControls(model: model, size: geometry.size).reportFrame("zoom", into: $cards).padding(14)
            }
            .overlay(alignment: .topTrailing) {
                if model.isBuilding {
                    ProgressView().controlSize(.small).padding(16)
                }
            }
        }
        .coordinateSpace(.named(MapArea.space))
        .background(Color(rgba: model.style.background))
        .onGeometryChange(for: Double.self) { $0.safeAreaInsets.top } action: { top in
            // The map runs under the translucent toolbar but is fitted below it.
            model.viewInsets = (top: top, bottom: 52)
        }
    }
}

extension MapArea {
    static let space = "mapArea"
}

private extension View {
    /// Keeps `frames[key]` up to date with this view's frame in the map area
    /// (or removes it while the view is empty).
    func reportFrame(_ key: String, into frames: Binding<[String: CGRect]>) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(MapArea.space)) } action: { frame in
            frames.wrappedValue[key] = frame.isEmpty ? nil : frame
        }
    }
}

/// "− = +": zoom out, show everything, zoom in.
struct ZoomControls: View {
    let model: AppModel
    let size: CGSize

    var body: some View {
        HStack(spacing: 2) {
            button("minus", help: "Zoom out (⌘− or ⌘-scroll)") { zoom(1 / 1.6) }
            Divider().frame(height: 16)
            button("equal", help: "Show the whole map (⌘0)") {
                withAnimation(.easeInOut(duration: 0.25)) { model.camera = MapCamera() }
            }
            Divider().frame(height: 16)
            button("plus", help: "Zoom in (⌘+ or ⌘-scroll)") { zoom(1.6) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .glassBackground(Capsule())
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func zoom(_ factor: Double) {
        guard var v = MapGeometry.mapViewport(model, size: size) else { return }
        v.zoom(by: factor, around: Vec2(size.width / 2, size.height / 2))
        model.camera = MapCamera(zoom: v.zoom, center: v.center)
    }
}

/// Folds the map back into the globe it came from.
struct FoldControl: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                model.toggleFold()
            } label: {
                Image(systemName: model.unfold >= 1 ? "globe.europe.africa" : "map")
                    .frame(width: 20)
            }
            .buttonStyle(.borderless)
            .help(model.unfold >= 1 ? "Fold the map into a globe" : "Unfold the globe into the map")
            .disabled(model.transition != nil)
            Slider(value: $model.unfold, in: 0...1)
                .frame(width: 130)
                .disabled(model.transition != nil)
                .help("Fold: the globe on the left, the flat map on the right")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassBackground(Capsule())
    }
}

/// The layout's name, summary and, on request, its story.
struct StoryCard: View {
    @Bindable var model: AppModel

    var body: some View {
        let d = model.descriptor
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: d.symbol).foregroundStyle(.secondary)
                Text(d.title).font(.headline)
                Spacer(minLength: 8)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { model.showStory.toggle() }
                } label: {
                    Image(systemName: model.showStory ? "chevron.up" : "info.circle")
                }
                .buttonStyle(.borderless)
                .help(model.showStory ? "Hide the story" : "How this map is cut")
            }
            Text(d.summary).font(.subheadline).foregroundStyle(.secondary)
            if model.showStory {
                Text(d.story)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                ForEach(model.state?.cut.notes ?? [], id: \.self) { note in
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 330, alignment: .leading)
        .glassBackground(RoundedRectangle(cornerRadius: 12))
    }
}

/// The colour scale of a field, or the kinds of plate boundary.
struct Legend: View {
    let model: AppModel

    var body: some View {
        if let content = content {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassBackground(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var content: AnyView? {
        let style = model.style
        let data = BodyData.of(model.body)
        if case .field(let key) = model.coloring, let d = model.body.field(key.id), data.isFieldLoaded(key),
           let field = try? data.field(key) {
            let range = MapRenderer.range(of: key, field: field, scale: d.scale, data: data)
            let colors = style.colormap(d.colormap).table(24).map { Color(rgba: $0) }
            return AnyView(VStack(alignment: .leading, spacing: 4) {
                Text(d.title + (d.variants.first { $0.id == key.variant }.map { " · " + $0.title } ?? ""))
                    .font(.caption.weight(.semibold))
                LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
                    .frame(width: 200, height: 10)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                HStack {
                    Text(Self.format(range.0, d)).font(.caption2.monospacedDigit())
                    Spacer()
                    Text(d.units.isEmpty ? "" : d.units).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(Self.format(range.1, d)).font(.caption2.monospacedDigit())
                }
                .frame(width: 200)
            })
        }
        if model.layers.contains(.plateBoundaries) {
            return AnyView(VStack(alignment: .leading, spacing: 3) {
                ForEach([PlateBoundaryKind.ridge, .subduction, .transform, .convergent], id: \.rawValue) { kind in
                    HStack(spacing: 6) {
                        Capsule().fill(Color(rgba: style.boundary(kind))).frame(width: 18, height: 3)
                        Text(kind.title).font(.caption)
                    }
                }
            })
        }
        return nil
    }

    static func format(_ v: Double, _ d: FieldDescriptor) -> String {
        switch d.scale {
        case .logarithmic: v <= 0 ? "0" : (pow(10, v) - 1).formatted(.number.notation(.compactName).precision(.significantDigits(2)))
        default: abs(v) >= 100 ? Int(v).formatted() : String(format: "%.1f", v)
        }
    }
}

struct HoverCard: View {
    let info: HoverInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(info.location.description).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            ForEach(info.lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(line.label).font(.caption).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                    Text(line.value).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(width: 280, alignment: .leading)
        .glassBackground(RoundedRectangle(cornerRadius: 10))
    }
}

/// Region names, clocks and cities, drawn over the flat map.
struct LabelLayer: View {
    let model: AppModel
    let size: CGSize
    /// Areas covered by cards.
    var occluded: [CGRect] = []

    var body: some View {
        if model.unfold >= 1, model.transition == nil, model.layers.contains(.labels), let viewport = MapGeometry.mapViewport(model, size: size) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Canvas { context, _ in draw(&context, viewport: viewport) }
            }
        }
    }

    private func draw(_ context: inout GraphicsContext, viewport: Viewport) {
        let style = model.style
        let date = model.date
        var placed = occluded.map { $0.insetBy(dx: -4, dy: -4) }
        let top = model.viewInsets.top
        let bounds = CGRect(x: 0, y: top, width: size.width, height: size.height - top).insetBy(dx: 4, dy: 4)
        for label in model.labels.sorted(by: { $0.room > $1.room }) {
            let roomPx = label.room * viewport.scale
            let q = viewport.toView(label.position)
            guard q.x > -50, q.y > -50, q.x < size.width + 50, q.y < size.height + 50 else { continue }
            var lines: [(String, Font, Color)] = []
            switch label.kind {
            case .clock:
                guard roomPx > 22, let tz = label.timeZone else { continue }
                let size = min(max(roomPx * 0.42, 10), 26)
                lines.append((Self.clock(date, tz), .system(size: size, weight: .semibold).monospacedDigit(), Color(rgba: style.ink)))
                if roomPx > 40 { lines.append((label.text, .system(size: max(size * 0.45, 9)), Color(rgba: style.secondaryInk))) }
            case .region:
                guard roomPx > 26 else { continue }
                lines.append((label.text, .system(size: min(max(roomPx * 0.22, 9), 16), weight: .medium), Color(rgba: style.ink)))
            case .ocean:
                guard roomPx > 40 else { continue }
                lines.append((label.text, .system(size: min(max(roomPx * 0.12, 10), 18), weight: .light).width(.expanded),
                              Color(rgba: style.secondaryInk)))
            case .city:
                guard roomPx > 14 else { continue }
                lines.append((label.text, .system(size: 10, weight: .medium), Color(rgba: style.ink)))
            }
            let resolved = lines.map { context.resolve(Text($0.0).font($0.1).foregroundStyle($0.2)) }
            let sizes = resolved.map { $0.measure(in: CGSize(width: 300, height: 100)) }
            let height = sizes.reduce(0) { $0 + $1.height }
            let width = sizes.map(\.width).max() ?? 0
            let origin = label.kind == .city ? CGPoint(x: q.x + 5, y: q.y - height / 2) : CGPoint(x: q.x - width / 2, y: q.y - height / 2)
            let frame = CGRect(origin: origin, size: CGSize(width: width, height: height)).insetBy(dx: -2, dy: -1)
            // Whole labels only: none cut by the edge of the view.
            guard bounds.contains(frame), !placed.contains(where: { $0.intersects(frame) }) else { continue }
            placed.append(frame)
            var y = origin.y
            for (text, size) in zip(resolved, sizes) {
                let x = label.kind == .city ? origin.x : q.x - size.width / 2
                // A soft halo keeps text readable on any fill.
                var halo = context
                halo.addFilter(.shadow(color: Color(rgba: style.halo), radius: 2))
                halo.draw(text, at: CGPoint(x: x, y: y), anchor: .topLeading)
                y += size.height
            }
        }
    }

    static func clock(_ date: Date, _ tz: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}

/// Moves the shown time up to a day either way.
struct TimeScrubber: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock").foregroundStyle(.secondary)
            Slider(value: Binding(get: { model.timeOffset }, set: { model.timeOffset = ($0 / 600).rounded() * 600 }),
                   in: -86_400...86_400)
                .frame(width: 150)
                .help("Scrub through the day: watch the night and the seams move")
            Text(offsetText).monospacedDigit().frame(width: 58, alignment: .leading)
            Button {
                model.toggleTimeLapse()
            } label: {
                Image(systemName: model.isTimeLapse ? "pause.fill" : "forward.fill")
            }
            .help(model.isTimeLapse ? "Stop the time-lapse" : "Time-lapse: an hour a second; watch the seams and the night sweep round")
            Button("Now") {
                if model.isTimeLapse { model.toggleTimeLapse() }
                model.timeOffset = 0
            }
            .disabled(model.timeOffset == 0)
        }
        .padding(.horizontal, 8)
    }

    private var offsetText: String {
        let minutes = Int(model.timeOffset / 60)
        if minutes == 0 { return "now" }
        return String(format: "%@%dh%02d", minutes > 0 ? "+" : "−", abs(minutes) / 60, abs(minutes) % 60)
    }
}

extension Color {
    init(rgba c: RGBA) { self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }
}

extension View {
    /// Liquid Glass where available, a material elsewhere.
    @ViewBuilder
    func glassBackground<S: Shape>(_ shape: S) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.separator.opacity(0.5)))
        }
    }
}
