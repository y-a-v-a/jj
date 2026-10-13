import AppKit
import MyriaCore
import MyriaData
import MyriaLayouts
import MyriaRender
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Gallery

/// Every layout, grouped, with a live thumbnail of its unfolding.
struct GalleryView: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: Binding(get: { model.layoutID }, set: { if let id = $0 { model.layoutID = id } })) {
            Picker("World", selection: $model.bodyID) {
                ForEach(CelestialBody.all) { world in
                    Text(world.name).tag(world.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.vertical, 4)
            .help("The world to unfold")
            ForEach(LayoutCategory.allCases, id: \.self) { category in
                let layouts = model.catalog.filter { $0.descriptor.category == category }
                if !layouts.isEmpty {
                    Section(category.title) {
                        ForEach(layouts, id: \.descriptor.id) { layout in
                            GalleryRow(descriptor: layout.descriptor(for: model.body), thumbnail: model.thumbnails[layout.descriptor.id],
                                       background: model.style.background)
                                .tag(layout.descriptor.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct GalleryRow: View {
    let descriptor: LayoutDescriptor
    let thumbnail: NSImage?
    let background: RGBA

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Color(rgba: background))
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit().padding(2)
                        .transition(.opacity)
                } else {
                    Image(systemName: descriptor.symbol).font(.title2).foregroundStyle(.tertiary)
                }
            }
            .frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator.opacity(0.6)))
            HStack(spacing: 6) {
                Image(systemName: descriptor.symbol).foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(descriptor.title).font(.body.weight(.medium))
                    Text(descriptor.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
        .animation(.easeIn(duration: 0.3), value: thumbnail != nil)
    }
}

// MARK: - Inspector

struct InspectorView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            let d = model.descriptor
            if !d.parameters.isEmpty {
                Section("Layout") {
                    ForEach(d.parameters) { p in ParameterControl(parameter: p, value: model.parameterBinding(p.id)) }
                    Button("Reset to Defaults") {
                        model.parameterValues[model.choiceKey] = nil
                        model.rebuild()
                    }
                    .disabled(model.parameterValues[model.choiceKey]?.isEmpty ?? true)
                }
            }
            Section("Myriahedron") {
                MeshPicker(model: model)
                Toggle(isOn: Binding(get: { model.gapsClosed }, set: { model.setGapsClosed($0) })) {
                    HStack(spacing: 6) {
                        Text("Close the Gaps")
                        if model.isComputingGaps { ProgressView().controlSize(.mini) }
                    }
                }
                .disabled(!model.canCloseGaps || model.unfold < 1)
                .help("Van Wijk's figure 13: the map without its interrupts")
                Text(model.canCloseGaps
                     ? "Figure 13: the seams zip shut from their narrow ends while the map relaxes like an elastic sheet; what cannot close becomes the outline."
                     : "Closing the gaps needs a mesh of triangles: Geodesic or Hexagons.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Colouring") {
                ColoringPicker(model: model)
                Picker("Palette", selection: $model.paletteID) {
                    ForEach(Palette.all) { Text($0.name).tag($0.id) }
                }
                Picker("Appearance", selection: $model.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Layers") {
                ForEach(LayerID.allCases.filter(model.isAvailable)) { layer in
                    Toggle(layer.title, isOn: model.layerBinding(layer))
                }
                if model.layerOverrides.isEmpty == false {
                    Button("Use the Layout's Layers") { model.layerOverrides = [:] }
                }
            }
            if let state = model.state {
                Section("This Map") {
                    LabeledContent("Polygons", value: state.mesh.cellCount.formatted())
                    LabeledContent("Faces", value: state.mesh.faceCount.formatted())
                    LabeledContent("Hinges", value: (state.mesh.faceCount - 1).formatted())
                    LabeledContent("Cuts", value: state.projection.cutEdges.count.formatted())
                    LabeledContent("Map size", value: String(format: "%.2f × %.2f", state.projection.bounds.width,
                                                              state.projection.bounds.height))
                    ForEach(state.timings, id: \.0) { name, t in
                        LabeledContent(name.capitalized, value: String(format: "%.0f ms", t * 1000))
                    }
                }
            }
            Section {
                Text("The cuts of a myriahedral map form a spanning tree of the mesh: V − 1 edges, and every face hangs from the root by exactly one path of hinges.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.coloringOverride) { model.refreshLabels() }
        .onChange(of: model.layerOverrides) { model.refreshLabels() }
    }
}

/// A control generated from a layout's parameter description.
struct ParameterControl: View {
    let parameter: LayoutParameter
    @Binding var value: Double
    @State private var draft: Double?

    var body: some View {
        switch parameter.kind {
        case .slider(let range, let step, let unit):
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(parameter.title)
                    Spacer()
                    Text(Self.format(draft ?? value, step: step) + unit).monospacedDigit().foregroundStyle(.secondary)
                }
                // Values commit when the slider is released; cutting is fast,
                // but uploading a new map every tick is not useful.
                Slider(value: Binding(get: { draft ?? value }, set: { draft = ($0 / step).rounded() * step }), in: range) { editing in
                    if !editing, let d = draft {
                        value = d
                        draft = nil
                    }
                }
            }
            .help(parameter.help)
        case .toggle:
            Toggle(parameter.title, isOn: Binding(get: { value != 0 }, set: { value = $0 ? 1 : 0 }))
                .help(parameter.help)
        case .choice(let options):
            Picker(parameter.title, selection: Binding(get: { Int(value) }, set: { value = Double($0) })) {
                ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
            }
            .help(parameter.help)
        }
    }

    static func format(_ v: Double, step: Double) -> String {
        step >= 1 ? String(Int(v.rounded())) : String(format: step >= 0.1 ? "%.1f" : "%.2f", v)
    }
}

struct MeshPicker: View {
    @Bindable var model: AppModel

    static let graticuleSteps: [Double] = [10, 5, 3, 2, 1.875, 1.5, 1, 0.75, 0.5]
    static let frequencies: [Int] = [8, 16, 24, 32, 40, 48, 64, 96, 128]

    var body: some View {
        let d = model.descriptor
        if d.fixesMesh {
            LabeledContent("Mesh", value: model.state?.context.spec.kind.title ?? d.preferredMesh.title)
            Text("This layout chooses its own solid and orientation.").font(.caption).foregroundStyle(.secondary)
        } else {
            Picker("Kind", selection: Binding(get: { kindIndex }, set: { setKind($0) })) {
                Text("Graticule").tag(0)
                Text("Geodesic").tag(1)
                Text("Hexagons").tag(2)
            }
            .pickerStyle(.segmented)
            switch model.meshKind {
            case .graticule(let step):
                Picker("Cell size", selection: Binding(get: { step }, set: { model.setMesh(.graticule(step: $0)) })) {
                    ForEach(Self.graticuleSteps, id: \.self) { s in
                        Text("\(s.formatted())° · \(MeshKind.graticule(step: s).cellCount.formatted())").tag(s)
                    }
                }
            case .geodesic(let n):
                Picker("Frequency", selection: Binding(get: { n }, set: { model.setMesh(.geodesic(frequency: $0)) })) {
                    ForEach(Self.frequencies, id: \.self) { f in
                        Text("\(f) · \(MeshKind.geodesic(frequency: f).cellCount.formatted())").tag(f)
                    }
                }
            case .hexagonal(let n):
                Picker("Frequency", selection: Binding(get: { n }, set: { model.setMesh(.hexagonal(frequency: $0)) })) {
                    ForEach(Self.frequencies, id: \.self) { f in
                        Text("\(f) · \(MeshKind.hexagonal(frequency: f).cellCount.formatted())").tag(f)
                    }
                }
            case .platonic:
                EmptyView()
            }
            if model.meshChoices[model.choiceKey] != nil {
                Button("Use \(d.preferredMesh.title)") { model.setMesh(nil) }
            }
            Text("Faces are flat. Each shows its part of the globe by gnomonic projection, so finer meshes approach a perfectly conformal, equal-area map with ever more interrupts.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var kindIndex: Int {
        switch model.meshKind {
        case .geodesic: 1
        case .hexagonal: 2
        default: 0
        }
    }

    private func setKind(_ index: Int) {
        guard index != kindIndex else { return }
        model.setMesh([MeshKind.graticule(step: 1.5), .geodesic(frequency: 32), .hexagonal(frequency: 24)][index])
    }
}

/// What fills the faces: the layout's choice or any other.
struct ColoringPicker: View {
    @Bindable var model: AppModel

    private struct Choice: Hashable, Identifiable {
        let id: String
        let title: String
        let coloring: LayoutAppearance.Coloring?
    }

    private var choices: [Choice] {
        var list = [Choice(id: "layout", title: "As the layout shows it", coloring: nil),
                    Choice(id: "landsea", title: "Land and sea", coloring: .landSea),
                    Choice(id: "relief", title: "Relief", coloring: .relief),
                    Choice(id: "pieces", title: "Pieces of the cut", coloring: .groups)]
        let world = model.body
        if !world.hasSeas { list.removeAll { $0.id == "landsea" } }
        for (dataset, title) in [(DatasetID.countries, "Countries"), (.plates, "Tectonic plates"), (.timeZones, "Timezones")]
        where world.has(dataset) {
            list.append(Choice(id: "regions:\(dataset)", title: title, coloring: .regions(dataset)))
        }
        for field in world.availableFields {
            list.append(Choice(id: "field:\(field.id)", title: field.title, coloring: .field(field.defaultKey)))
        }
        return list
    }

    var body: some View {
        Picker("Fill", selection: Binding(
            get: { choices.first { $0.coloring == model.coloringOverride && model.coloringOverride != nil }?.id ?? "layout" },
            set: { id in model.coloringOverride = choices.first { $0.id == id }?.coloring })) {
            ForEach(choices) { Text($0.title).tag($0.id) }
        }
    }
}

// MARK: - Export

struct ExportMenu: View {
    @Bindable var model: AppModel
    @State private var isExporting = false

    var body: some View {
        Menu {
            Button("PNG Image (4K)…") { export(width: 3840) }
            Button("PNG Image (8K)…") { export(width: 7680) }
            Button("Unfolding Animation (GIF)…") { exportGIF() }
            Button("Unfolding Film (4K)…") { exportFilm() }
            Divider()
            Button("Paper Globe (PDF)…") { model.isShowingPaper = true }
            Divider()
            Button("Copy Image") { copy() }
        } label: {
            Label(isExporting ? "Exporting…" : "Export", systemImage: "square.and.arrow.up")
        }
        .help("Export the map")
        .disabled(model.state == nil || isExporting)
        .sheet(isPresented: $model.isShowingPaper) { PaperSheet(model: model) }
        .task {
            // For demos and checks: -showPaper YES.
            if UserDefaults.standard.bool(forKey: "showPaper") {
                try? await Task.sleep(for: .seconds(2))
                model.isShowingPaper = true
            }
        }
    }

    /// What an export needs, captured on the main actor.
    private struct Job: Sendable {
        let state: MapState
        let settings: FrameSettings
    }

    /// - Parameter closed: draw the map with its gaps as closed as shown.
    @MainActor private func job(width: Int, unfold: Double = 1, closed: Bool = true) -> Job? {
        guard let state = model.state else { return nil }
        let closing = unfold >= 1 && closed ? model.liveClosing : 0
        let height = MapExport.height(for: state, width: width, closing: closing)
        var settings = MapExport.settings(for: state, palette: model.palette, dark: model.isDark, width: width, height: height,
                                          coloring: model.coloring, layers: model.layers, date: model.date, unfold: unfold,
                                          globe: model.globe)
        settings.sealSlits = model.sealSlits && state.appearance.sealSlits
        settings.lineScale *= model.lineWeight
        settings.graticuleStep = model.graticuleStep
        // The map as shown: with its gaps closed, if they are.
        settings.closing = closing
        return Job(state: state, settings: settings)
    }

    /// Renders off the main thread. Very large images get fewer samples so
    /// the colour and depth targets stay within a few hundred megabytes.
    nonisolated private static func render(_ job: Job, width: Int, renderer: MapRenderer? = nil) throws -> CGImage {
        var width = width
        let closing = job.settings.closing
        var height = MapExport.height(for: job.state, width: width, closing: closing)
        // At most about 50 megapixels.
        if width * height > 50_000_000 {
            let k = (50_000_000 / Double(width * height)).squareRoot()
            width = Int(Double(width) * k)
            height = MapExport.height(for: job.state, width: width, closing: closing)
        }
        let r = try renderer ?? MapRenderer(sampleCount: width * height > 16_000_000 ? 2 : 4)
        var settings = job.settings
        settings.viewport = MapExport.fittedViewport(for: job.state, width: Double(width), height: Double(height),
                                                     unfold: settings.unfold, globe: settings.globe, closing: closing)
        return try r.image(job.state, settings: settings, width: width, height: height)
    }

    @MainActor private func run(_ work: @escaping @Sendable () throws -> Void) {
        isExporting = true
        Task {
            let failure: Error? = await Task.detached(priority: .userInitiated) {
                do { try work(); return nil } catch { return error }
            }.value
            isExporting = false
            if let failure { NSAlert(error: failure).runModal() }
        }
    }

    @MainActor private func export(width: Int) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(model.layoutID).png"
        guard panel.runModal() == .OK, let url = panel.url, let job = job(width: width) else { return }
        run { try MapExport.png(try Self.render(job, width: width)).write(to: url) }
    }

    @MainActor private func exportGIF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = "\(model.layoutID)-unfolding.gif"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The unfolding only: every frame the same size, the gaps open.
        let jobs = (0..<60).compactMap { job(width: 900, unfold: AppModel.ease(Double($0) / 59), closed: false) }
        guard !jobs.isEmpty else { return }
        run {
            // One renderer for every frame: the mesh is uploaded once.
            let renderer = try MapRenderer()
            var frames = try jobs.map { try Self.render($0, width: 900, renderer: renderer) }
            if let last = frames.last { frames += Array(repeating: last, count: 24) }
            try MapExport.gif(frames, delay: 1.0 / 25).write(to: url)
        }
    }

    /// The globe turning into place, unfolding and holding still: HEVC, 4K.
    @MainActor private func exportFilm() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.nameFieldStringValue = "\(model.layoutID)-unfolding.mov"
        guard panel.runModal() == .OK, let url = panel.url, let base = job(width: 3840) else { return }
        let (width, height) = MapExport.movieSize(width: 3840)
        // With the gaps closed in the app, the film ends by closing them.
        let close = model.gapsClosed && base.state.closedGapsIfReady != nil
        let frames = MapExport.unfoldingStoryboard(fps: 30, globe: model.globe, close: close ? 3 : 0)
        run {
            let renderer = try MapRenderer()
            try MapExport.movie(to: url, width: width, height: height, fps: 30, count: frames.count) { k in
                var settings = base.settings
                settings.unfold = frames[k].unfold
                settings.globe = frames[k].globe
                settings.closing = frames[k].closing
                settings.viewport = MapExport.fittedViewport(for: base.state, width: Double(width), height: Double(height),
                                                             unfold: settings.unfold, globe: settings.globe,
                                                             closing: settings.closing)
                return try renderer.image(base.state, settings: settings, width: width, height: height)
            }
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    @MainActor private func copy() {
        guard let job = job(width: 2400) else { return }
        isExporting = true
        Task {
            let image = await Task.detached(priority: .userInitiated) { try? Self.render(job, width: 2400) }.value
            isExporting = false
            guard let image else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))])
        }
    }
}
