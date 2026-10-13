import AppKit
import MyriaCore
import MyriaData
import MyriaLayouts
import MyriaRender
import SwiftUI

/// "Print, cut, fold": the current map as a paper globe.
struct PaperSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("paperDetail") private var detail = PaperGlobe.Detail.detailed
    @AppStorage("paperDiameter") private var diameter = 12.0
    @AppStorage("paperSize") private var paper = Locale.current.measurementSystem == .us ? PaperNet.Paper.letter : .a4
    @State private var preview: Preview?
    @State private var page = 0
    @State private var failure: String?
    @State private var isSaving = false

    struct Preview {
        let pages: [NSImage]
        let summary: String
    }

    /// Everything the paper depends on, to rebuild the preview on change.
    private struct Choice: Hashable {
        let detail: PaperGlobe.Detail
        let diameter: Double
        let paper: PaperNet.Paper
    }

    var body: some View {
        let d = model.descriptor
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Paper Globe").font(.title2.weight(.semibold))
                Text("Print the \(d.title) map, cut it out, fold it and glue it: it closes into the globe it was unfolded from.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Form {
                    if PaperGlobe.mesh(for: d, detail: detail) != nil || d.parameter("levels") != nil {
                        Picker("Faces", selection: $detail) {
                            ForEach(PaperGlobe.Detail.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    } else {
                        LabeledContent("Faces", value: "The layout's own solid")
                    }
                    LabeledContent("Size") {
                        HStack {
                            Slider(value: Binding(get: { diameter }, set: { diameter = $0.rounded() }), in: 6...40)
                            Text("\(Int(diameter)) cm").monospacedDigit().frame(width: 44, alignment: .trailing)
                        }
                    }
                    Picker("Paper", selection: $paper) {
                        ForEach(PaperNet.Paper.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                .formStyle(.columns)
                Group {
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else if let preview {
                        Text(preview.summary).foregroundStyle(.secondary)
                    } else {
                        Text("Unfolding…").foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                Spacer()
                HStack {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if isSaving { ProgressView().controlSize(.small) }
                    Button("Save PDF…") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(preview == nil || isSaving)
                }
            }
            .frame(width: 330)
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(.white).shadow(radius: 3, y: 1)
                    if let preview, preview.pages.indices.contains(page) {
                        Image(nsImage: preview.pages[page]).resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 460 * paper.size.x / paper.size.y, height: 460)
                if let count = preview?.pages.count, count > 1 {
                    HStack {
                        Button { page = max(page - 1, 0) } label: { Image(systemName: "chevron.left") }
                            .disabled(page == 0)
                        Text("Sheet \(page + 1) of \(count)").monospacedDigit()
                        Button { page = min(page + 1, count - 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(page == count - 1)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(24)
        .task(id: Choice(detail: detail, diameter: diameter, paper: paper)) {
            failure = nil
            // Let the slider settle.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let job = job() else { return }
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Preview, Error> in
                Result { try Self.preview(job) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let p):
                preview = p
                page = min(page, p.pages.count - 1)
            case .failure(let error):
                preview = nil
                failure = "\(error)"
            }
        }
    }

    // MARK: Work

    /// What a paper globe needs, captured on the main actor.
    struct Job: Sendable {
        let engine: MapEngine
        let layout: any MapLayout
        let parameters: LayoutParameters
        let mesh: MeshKind
        let options: PaperNet.Options
        let palette: Palette
        let coloring: LayoutAppearance.Coloring?
        let layers: Set<LayerID>
        let date: Date
        let title: String
    }

    private func job() -> Job? {
        let d = model.descriptor
        let options = PaperNet.Options(sheet: paper.size, diameter: diameter * 10)
        return Job(engine: model.engine, layout: model.layout,
                   parameters: PaperGlobe.parameters(model.parameters, for: d, detail: detail),
                   mesh: PaperGlobe.mesh(for: d, detail: detail) ?? model.meshKind, options: options, palette: model.palette,
                   coloring: model.coloringOverride, layers: model.layers.subtracting([.labels, .flights, .mesh, .cuts]),
                   date: model.date, title: d.title)
    }

    nonisolated static func make(_ job: Job, dpi: Double) throws -> PaperGlobe.Result {
        let state = try job.engine.build(job.layout, parameters: job.parameters, mesh: MeshSpec(job.mesh))
        let settings = MapExport.settings(for: state, palette: job.palette, dark: false, width: 1000, height: 1000,
                                          coloring: job.coloring, layers: job.layers, date: job.date)
        return try PaperGlobe.make(state, options: job.options, renderer: try renderer(), settings: settings,
                                   title: job.title, dpi: dpi)
    }

    nonisolated static func preview(_ job: Job) throws -> Preview {
        let result = try make(job, dpi: 72)
        let net = result.net
        let pages = (0..<net.sheetCount).compactMap { PaperGlobe.page(result.pdf, index: $0, width: 700) }
            .map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        let tabs = net.seams.filter { $0.tabFace != nil }.count
        let summary = "\(net.pieces.count) \(net.pieces.count == 1 ? "piece" : "pieces") on \(net.sheetCount) \(net.sheetCount == 1 ? "sheet" : "sheets"), \(tabs) glue tabs."
        return Preview(pages: pages, summary: summary)
    }

    /// One renderer for every paper globe: the shaders compile once.
    nonisolated(unsafe) private static var shared: MapRenderer?
    private static let lock = NSLock()

    nonisolated static func renderer() throws -> MapRenderer {
        lock.lock()
        defer { lock.unlock() }
        if let shared { return shared }
        let r = try MapRenderer()
        shared = r
        return r
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(model.layoutID)-paper-globe.pdf"
        guard panel.runModal() == .OK, let url = panel.url, let job = job() else { return }
        isSaving = true
        Task {
            let error: Error? = await Task.detached(priority: .userInitiated) {
                do {
                    try Self.make(job, dpi: 300).pdf.write(to: url)
                    return nil
                } catch {
                    return error
                }
            }.value
            isSaving = false
            if let error {
                NSAlert(error: error).runModal()
            } else {
                NSWorkspace.shared.open(url)
                dismiss()
            }
        }
    }
}

