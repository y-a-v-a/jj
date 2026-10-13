import AppKit
import MetalKit
import MyriaCore
import MyriaData
import MyriaLayouts
import MyriaRender
import SwiftUI

/// The map, drawn with Metal.
struct MapView: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> MapMTKView {
        MapMTKView(model: model)
    }

    func updateNSView(_ view: MapMTKView, context: Context) {
        // Read everything a frame depends on, so SwiftUI redraws on change.
        _ = (model.state, model.paletteID, model.isDark, model.coloring, model.layers, model.unfold, model.globe,
             model.camera, model.selectedGroup, model.date, model.sealSlits, model.lineWeight, model.graticuleStep,
             model.transition?.phase, model.foldAnimation?.start)
        view.redraw()
    }
}

/// Viewports shared by the Metal view and the SwiftUI overlays.
@MainActor
enum MapGeometry {
    static let globeBounds = Rect2(minX: -1.12, minY: -1.12, maxX: 1.12, maxY: 1.12)

    /// The camera on the flat map.
    static func mapViewport(_ model: AppModel, size: CGSize) -> Viewport? {
        guard let state = model.state else { return nil }
        return Viewport(bounds: state.projection.bounds, size: Vec2(size.width, size.height), zoom: model.camera.zoom,
                        center: model.camera.center)
    }

    /// The camera for the current fold.
    static func viewport(_ model: AppModel, size: CGSize, unfold: Double) -> Viewport? {
        guard let map = mapViewport(model, size: size) else { return nil }
        guard unfold < 1 else { return map }
        let globe = Viewport(bounds: globeBounds, size: map.size, zoom: min(model.camera.zoom, 4))
        var reset = map
        // While a transition unfolds, it heads for the whole map.
        if model.transition != nil { reset.zoom = 1; reset.center = reset.bounds.center }
        return Viewport.blend(globe, reset, unfold)
    }
}

final class MapMTKView: MTKView, MTKViewDelegate {
    let model: AppModel
    let renderer: MapRenderer?
    private let particles = WindParticles()
    private var dragOrigin: NSPoint?
    private var dragCamera: MapCamera?
    private var dragged = false
    private var lastPointer: NSPoint?

    init(model: AppModel) {
        self.model = model
        let device = MTLCreateSystemDefaultDevice()
        renderer = try? MapRenderer(device: device, pixelFormat: .bgra8Unorm, sampleCount: 4)
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        depthStencilPixelFormat = .depth32Float
        sampleCount = renderer?.sampleCount ?? 1
        preferredFramesPerSecond = 120
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        delegate = self
        let options: NSTrackingArea.Options = [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect]
        addTrackingArea(NSTrackingArea(rect: .zero, options: options, owner: self))
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func redraw() {
        needsDisplay = true
        if model.isAnimating || particles.isActive { isPaused = false }
    }

    // MARK: Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let bg = model.style.background
        clearColor = MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)
        guard let renderer, let state = model.state, let drawable = currentDrawable,
              let pass = currentRenderPassDescriptor, let buffer = renderer.queue.makeCommandBuffer()
        else { return }
        let unfold = model.animationStep(at: CACurrentMediaTime())
        guard let viewport = MapGeometry.viewport(model, size: bounds.size, unfold: unfold) else { return }
        let layers = model.layers
        // Wind particles drift over the flat map.
        let windOn = layers.contains(.wind) && unfold >= 1 && state.data.body.has(.wind)
        particles.update(state: state, active: windOn, variant: windVariant(state))
        var settings = FrameSettings(
            style: model.style, coloring: model.coloring, layers: layers, date: model.date, unfold: unfold,
            globe: model.globe, viewport: viewport, pixelScale: drawableSize.width / max(bounds.width, 1),
            lineScale: model.lineWeight, graticuleStep: model.graticuleStep,
            highlightGroups: model.selectedGroup.map { [$0] } ?? [], mapLines: particles.lines, sealSlits: model.sealSlits)
        if case .groups = settings.coloring { settings.highlightGroups = [] }
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        renderer.encode(state, settings: settings, into: encoder, drawableSize: drawableSize)
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
        isPaused = !(model.isAnimating || particles.isActive)
    }

    private func windVariant(_ state: MapState) -> String {
        let m = state.parameters.index("month", default: 0)
        return state.layout.id == "winds" && m > 0 ? String(format: "%02d", m) : "annual"
    }

    // MARK: Coordinates

    /// View point with a top-left origin, as viewports use.
    private func viewPoint(_ event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow, from: nil)
        return NSPoint(x: p.x, y: bounds.height - p.y)
    }

    private var flat: Bool { model.unfold >= 1 && model.transition == nil }

    private func mapPoint(_ p: NSPoint) -> Vec2? {
        MapGeometry.mapViewport(model, size: bounds.size)?.toMap(Vec2(p.x, p.y))
    }

    /// The globe point under a view point while closed.
    private func globePoint(_ p: NSPoint) -> Vec3? {
        guard model.unfold <= 0.001, let v = MapGeometry.viewport(model, size: bounds.size, unfold: 0) else { return nil }
        let q = v.toMap(Vec2(p.x, p.y))
        let r2 = q.x * q.x + q.y * q.y
        guard r2 < 1 else { return nil }
        let world = Vec3(q.x, q.y, (1 - r2).squareRoot())
        // World = globe rotation × globe coordinates.
        let g = model.globe
        let inverse = Mat3(Vec3(g.c0.x, g.c1.x, g.c2.x), Vec3(g.c0.y, g.c1.y, g.c2.y), Vec3(g.c0.z, g.c1.z, g.c2.z))
        return inverse.apply(world)
    }

    // MARK: Zoom

    func zoom(by factor: Double, around p: NSPoint) {
        guard var v = MapGeometry.mapViewport(model, size: bounds.size) else { return }
        v.zoom(by: factor, around: Vec2(p.x, p.y))
        model.camera = MapCamera(zoom: v.zoom, center: v.center)
    }

    override func scrollWheel(with event: NSEvent) {
        let p = viewPoint(event)
        if event.modifierFlags.contains(.command) {
            // Rolling or swiping away from you zooms in, whatever the scroll
            // direction setting. A wheel notch is a line, a trackpad reports points.
            let away = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
            let steps = away / (event.hasPreciseScrollingDeltas ? 120 : 5)
            zoom(by: pow(2, steps), around: p)
        } else if !flat {
            model.rotateGlobe(by: CGSize(width: -event.scrollingDeltaX, height: -event.scrollingDeltaY))
        } else if var v = MapGeometry.mapViewport(model, size: bounds.size) {
            let scale: Double = event.hasPreciseScrollingDeltas ? 1 : 12
            v.pan(by: Vec2(event.scrollingDeltaX * scale, event.scrollingDeltaY * scale))
            model.camera = MapCamera(zoom: v.zoom, center: v.center)
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: viewPoint(event))
    }

    override func smartMagnify(with event: NSEvent) {
        zoom(by: model.camera.zoom > 1.5 ? 1 / model.camera.zoom : 2.5, around: viewPoint(event))
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragOrigin = viewPoint(event)
        dragCamera = model.camera
        dragged = false
        if event.clickCount == 2, flat {
            zoom(by: 2, around: viewPoint(event))
            dragOrigin = nil
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let p = viewPoint(event)
        if hypot(p.x - origin.x, p.y - origin.y) > 2 { dragged = true }
        guard dragged else { return }
        if !flat {
            model.rotateGlobe(by: CGSize(width: event.deltaX, height: event.deltaY))
        } else if let start = dragCamera, var v = MapGeometry.mapViewport(model, size: bounds.size) {
            v.zoom = start.zoom
            v.center = start.center ?? v.bounds.center
            v.pan(by: Vec2(p.x - origin.x, p.y - origin.y))
            model.camera = MapCamera(zoom: v.zoom, center: v.center)
        }
        model.hover = nil
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil }
        guard !dragged, event.clickCount == 1, flat, let q = mapPoint(viewPoint(event)), let state = model.state else { return }
        if event.modifierFlags.contains(.option), let (_, location) = state.location(atMapPoint: q) {
            recenter(on: location)
            return
        }
        guard let (face, _) = state.location(atMapPoint: q), let groups = state.cut.faceGroups, groups[face] >= 0 else {
            model.selectedGroup = nil
            return
        }
        model.selectedGroup = model.selectedGroup == groups[face] ? nil : groups[face]
    }

    /// Option-click: centre the layout on a place.
    private func recenter(on location: GeoPoint) {
        let d = model.descriptor
        if d.parameter("lat") != nil, d.parameter("lon") != nil {
            model.parameterValues[model.layoutID, default: [:]]["lat"] = location.latitude.rounded()
            model.parameterValues[model.layoutID, default: [:]]["lon"] = location.longitude.rounded()
            model.rebuild(transition: true)
        } else if let key = ["center", "lambda0"].first(where: { d.parameter($0) != nil }) {
            model.parameterValues[model.layoutID, default: [:]][key] = (location.longitude / 5).rounded() * 5
            model.rebuild(transition: true)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = viewPoint(event)
        lastPointer = p
        if flat, let q = mapPoint(p) {
            model.hover(at: q, viewPoint: CGPoint(x: p.x, y: p.y))
        } else if let g = globePoint(p) {
            model.hoverGlobe(at: g, viewPoint: CGPoint(x: p.x, y: p.y))
        } else {
            model.hover = nil
        }
    }

    override func mouseExited(with event: NSEvent) {
        model.hover = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        let p = viewPoint(event)
        let menu = NSMenu()
        if flat, let q = mapPoint(p), let (_, location) = model.state?.location(atMapPoint: q) {
            let item = NSMenuItem(title: "Centre the Map Here", action: #selector(centreHere(_:)), keyEquivalent: "")
            item.representedObject = location
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }
        let fold = NSMenuItem(title: model.unfold >= 1 ? "Fold into a Globe" : "Unfold the Map", action: #selector(toggleFold), keyEquivalent: "")
        fold.target = self
        menu.addItem(fold)
        let fit = NSMenuItem(title: "Show the Whole Map", action: #selector(fitMap), keyEquivalent: "")
        fit.target = self
        menu.addItem(fit)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func centreHere(_ sender: NSMenuItem) {
        if let location = sender.representedObject as? GeoPoint { recenter(on: location) }
    }

    @objc private func toggleFold() { model.toggleFold() }

    @objc private func fitMap() { model.camera = MapCamera() }
}

/// Particles drifting with the mean surface wind, drawn as fading trails.
@MainActor
final class WindParticles {
    private struct Particle {
        var position: Vec3
        var age: Int
        var trail: [Vec2]
    }

    private var particles: [Particle] = []
    private var stateID: UUID?
    private var variant = ""
    private var wind: WindField?
    private var last = CACurrentMediaTime()
    private(set) var lines: [MapLine] = []
    private(set) var isActive = false
    private var seed: UInt64 = 0x9E3779B97F4A7C15

    private func random() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / Double(1 << 53)
    }

    private func randomPoint() -> Vec3 {
        let z = random() * 2 - 1, phi = random() * 2 * .pi, r = (1 - z * z).squareRoot()
        return Vec3(r * cos(phi), r * sin(phi), z)
    }

    func update(state: MapState, active: Bool, variant: String) {
        isActive = active
        guard active else {
            lines = []
            return
        }
        if stateID != state.id || self.variant != variant {
            stateID = state.id
            self.variant = variant
            wind = try? state.data.wind(variant)
            particles = (0..<2400).map { _ in Particle(position: randomPoint(), age: Int(random() * 90), trail: []) }
        }
        guard let wind else { return }
        let now = CACurrentMediaTime()
        let dt = min(now - last, 0.05)
        last = now
        // A 10 m/s wind moves a particle about 2.5° a second on screen.
        let speedScale = 0.0044 * dt * 60
        lines.removeAll(keepingCapacity: true)
        let projection = state.projection
        for i in particles.indices {
            var p = particles[i]
            p.age += 1
            let w = wind.vector(at: p.position)
            if p.age > 120 || w.length < 0.3 {
                p = Particle(position: randomPoint(), age: 0, trail: [])
            } else {
                p.position = (p.position + w * (speedScale / 10)).normalized
            }
            let q = projection.project(p.position).point
            if let lastPoint = p.trail.last, (q - lastPoint).length > 0.03 { p.trail.removeAll() }
            p.trail.append(q)
            if p.trail.count > 10 { p.trail.removeFirst() }
            let fade = min(1, Float(p.age) / 15) * min(1, Float(120 - p.age) / 20)
            for k in 1..<max(p.trail.count, 1) where p.trail.count > 1 {
                lines.append(MapLine(a: p.trail[k - 1], b: p.trail[k], alpha: fade * Float(k) / Float(p.trail.count)))
            }
            particles[i] = p
        }
    }
}
