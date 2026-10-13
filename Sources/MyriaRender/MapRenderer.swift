import CoreGraphics
import Foundation
import Metal
import MyriaCore
import MyriaData
import MyriaLayouts
import simd

public enum RenderError: Error, CustomStringConvertible {
    case noDevice
    case compile(String)
    case allocation(String)

    public var description: String {
        switch self {
        case .noDevice: "no Metal device"
        case .compile(let message): "shader compilation failed: \(message)"
        case .allocation(let what): "could not render: \(what)"
        }
    }
}

/// Compiled shaders and pipeline states for one device and target format.
final class RenderPipelines {
    let surface: MTLRenderPipelineState
    let line: MTLRenderPipelineState
    let point: MTLRenderPipelineState
    let depthWrite: MTLDepthStencilState
    let depthTest: MTLDepthStencilState
    let depthOff: MTLDepthStencilState

    nonisolated(unsafe) private static var libraries: [ObjectIdentifier: MTLLibrary] = [:]
    private static let lock = NSLock()

    static func library(_ device: MTLDevice) throws -> MTLLibrary {
        lock.lock()
        defer { lock.unlock() }
        if let library = libraries[ObjectIdentifier(device)] { return library }
        do {
            let library = try device.makeLibrary(source: Shaders.source, options: nil)
            libraries[ObjectIdentifier(device)] = library
            return library
        } catch {
            throw RenderError.compile("\(error)")
        }
    }

    init(device: MTLDevice, pixelFormat: MTLPixelFormat, sampleCount: Int) throws {
        let library = try Self.library(device)
        func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.rasterSampleCount = sampleCount
            d.depthAttachmentPixelFormat = .depth32Float
            let c = d.colorAttachments[0]!
            c.pixelFormat = pixelFormat
            c.isBlendingEnabled = true
            c.rgbBlendOperation = .add
            c.alphaBlendOperation = .add
            c.sourceRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do { return try device.makeRenderPipelineState(descriptor: d) } catch { throw RenderError.compile("\(error)") }
        }
        surface = try pipeline("surfaceVertex", "surfaceFragment")
        line = try pipeline("lineVertex", "lineFragment")
        point = try pipeline("pointVertex", "pointFragment")
        func depth(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        depthWrite = depth(.less, write: true)
        depthTest = depth(.lessEqual, write: false)
        depthOff = depth(.always, write: false)
    }
}

/// Keys of resources being prepared off the main thread.
final class PendingRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var keys = Set<String>()

    /// True if the key was not pending yet (and now is).
    func begin(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return keys.insert(key).inserted
    }

    func end(_ key: String) {
        lock.lock()
        keys.remove(key)
        lock.unlock()
    }
}

/// Buffers rewritten every frame, rotated so the CPU never writes one the
/// GPU may still be reading (MTKView keeps at most three frames in flight).
final class BufferRing {
    private var buffers: [MTLBuffer?] = [nil, nil, nil]
    private var index = 0

    func next(_ device: MTLDevice, length: Int) -> MTLBuffer? {
        index = (index + 1) % buffers.count
        if buffers[index] == nil || buffers[index]!.length < length {
            buffers[index] = device.makeBuffer(length: max(length, 16), options: .storageModeShared)
        }
        return buffers[index]
    }
}

/// A GPU buffer with a count of elements.
struct GPUArray {
    let buffer: MTLBuffer
    let count: Int

    init?<T>(_ device: MTLDevice, _ values: [T]) {
        guard !values.isEmpty else { return nil }
        guard let b = values.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
        else { return nil }
        buffer = b
        count = values.count
    }
}

/// Draws myriahedral maps with Metal: on screen through `encode`, off screen
/// through `image`. Faces live on the GPU in their own coordinates; a pose
/// per face places them flat, folding or on the globe, so unfolding costs
/// one small buffer update per frame.
public final class MapRenderer {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let pixelFormat: MTLPixelFormat
    public let sampleCount: Int
    let pipelines: RenderPipelines

    /// Prepare missing overlays and fields off the calling thread and draw
    /// without them meanwhile (the app), instead of building them on the
    /// spot (exports, tests).
    public var buildsAsynchronously = false
    /// Called (on any thread) when something prepared in the background is ready.
    public var onResourceReady: (@Sendable () -> Void)?
    private let pending = PendingRequests()

    // Per mesh.
    private var meshOverlays: MeshOverlays?
    private var frames: GPUArray?
    private var base: GPUArray?
    private var fills: [DatasetID: GPUArray] = [:]
    private var lines: [String: GPUArray] = [:]
    private var points: [String: GPUArray] = [:]
    // Per state.
    private var stateKey: UUID?
    private var cutLines: GPUArray?
    private var facePaints: GPUArray?
    private var groupPaintCount = 0
    private var highlightKey: [Int] = []
    private var highlight: GPUArray?
    private var regionPaints: [DatasetID: (slots: [Int: Int], count: Int)] = [:]
    private var paintBuffers: [String: GPUArray] = [:]
    // Per frame.
    private var poseKey: (UUID, Double, Mat3, Double)?
    private var poseBuffer: MTLBuffer?
    private let poseRing = BufferRing()
    private let foldScratch = Folding.FoldScratch()
    private let lineRing = BufferRing()
    // Textures, per world.
    private var fieldTextures: [String: (texture: MTLTexture, field: GridField)] = [:]
    private var elevations: [String: (texture: MTLTexture, field: GridField)] = [:]
    private var luts: [[RGBA]: MTLTexture] = [:]
    private var dummy: MTLTexture?

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), pixelFormat: MTLPixelFormat = .bgra8Unorm,
                sampleCount: Int = 4) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw RenderError.noDevice }
        self.device = device
        self.queue = queue
        self.pixelFormat = pixelFormat
        self.sampleCount = device.supportsTextureSampleCount(sampleCount) ? sampleCount : 1
        pipelines = try RenderPipelines(device: device, pixelFormat: pixelFormat, sampleCount: self.sampleCount)
    }

    // MARK: Resources

    /// Whether a resource can be used now. When building asynchronously and
    /// it isn't ready, `work` runs in the background and the caller draws
    /// without it this frame.
    private func available(_ ready: Bool, key: String, _ work: @escaping @Sendable () -> Void) -> Bool {
        guard buildsAsynchronously, !ready else { return true }
        if pending.begin(key) {
            let pending = self.pending, done = onResourceReady
            Task.detached(priority: .userInitiated) {
                work()
                pending.end(key)
                done?()
            }
        }
        return false
    }

    private func available(_ item: MeshOverlays.Item, _ state: MapState) -> Bool {
        let overlays = state.overlays
        return available(overlays.isBuilt(item), key: "\(ObjectIdentifier(overlays)):\(item)") { overlays.prepare(item) }
    }

    private func available(_ key: FieldKey, _ data: BodyData) -> Bool {
        available(data.isFieldLoaded(key), key: "\(data.body.id):field:\(key)") { _ = try? data.field(key) }
    }

    private func prepareMesh(_ state: MapState) {
        guard state.overlays !== meshOverlays else { return }
        meshOverlays = state.overlays
        fills = [:]
        lines = [:]
        points = [:]
        let mesh = state.mesh
        frames = GPUArray(device, (0..<mesh.faceCount).map { f -> FaceFrameGPU in
            let fr = mesh.frames[f]
            return FaceFrameGPU(origin: SIMD4(Float(fr.origin.x), Float(fr.origin.y), Float(fr.origin.z), 0),
                                xAxis: SIMD4(Float(fr.xAxis.x), Float(fr.xAxis.y), Float(fr.xAxis.z), 0),
                                yAxis: SIMD4(Float(fr.yAxis.x), Float(fr.yAxis.y), Float(fr.yAxis.z), 0))
        })
        var vertices: [SurfaceVertex] = []
        vertices.reserveCapacity(mesh.faceCount * 6)
        for f in 0..<mesh.faceCount {
            let v = mesh.frames[f].localVertices
            let out = Self.cornerOutwards(v)
            for k in 1..<(v.count - 1) {
                for i in [0, k, k + 1] {
                    vertices.append(SurfaceVertex(local: SIMD2(Float(v[i].x), Float(v[i].y)),
                                                  outward: SIMD2(Float(out[i].x), Float(out[i].y)), face: UInt32(f), paint: .max))
                }
            }
        }
        base = GPUArray(device, vertices)
    }

    private func prepareState(_ state: MapState) {
        guard state.id != stateKey else { return }
        stateKey = state.id
        highlightKey = []
        highlight = nil
        regionPaints = [:]
        paintBuffers = [:]
        // Both sides of every cut edge.
        let mesh = state.mesh, isCut = state.projection.unfolding.isCut
        var instances: [LineInstance] = []
        for (e, edge) in mesh.topology.edges.enumerated() where isCut[e] {
            for f in [edge.leftFace, edge.rightFace] {
                let (a, b) = Self.localEdge(mesh, face: f, edge: edge)
                instances.append(LineInstance(a: a, b: b, face: UInt32(f), style: 0))
            }
        }
        cutLines = GPUArray(device, instances)
        // Pieces, coloured so neighbours differ.
        let labels = state.cut.faceGroups ?? pieceLabels(state)
        let slots = RegionColoring.slots(labels: labels, mesh: mesh, slotCount: 6)
        groupPaintCount = 6
        facePaints = GPUArray(device, labels.map { UInt32(slots[$0] ?? 0) })
    }

    private func pieceLabels(_ state: MapState) -> [Int] {
        state.context.components(of: Array(repeating: 0, count: state.mesh.faceCount)) { !state.projection.unfolding.isCut[$0] }
    }

    static func localEdge(_ mesh: MyriahedralMesh, face f: Int, edge: MeshEdge) -> (SIMD2<Float>, SIMD2<Float>) {
        let face = mesh.polyhedron.faces[f], local = mesh.frames[f].localVertices
        let a = local[face.firstIndex(of: edge.a)!], b = local[face.firstIndex(of: edge.b)!]
        return (SIMD2(Float(a.x), Float(a.y)), SIMD2(Float(b.x), Float(b.y)))
    }

    /// Outward unit normals of a counter-clockwise polygon's edges (edge i
    /// runs from corner i to corner i + 1).
    static func edgeNormals(_ v: [Vec2]) -> [Vec2] {
        v.indices.map { i in
            let d = v[(i + 1) % v.count] - v[i]
            return Vec2(d.y, -d.x).normalized
        }
    }

    /// Per corner, the offset that moves both adjacent edges outwards by one unit.
    static func cornerOutwards(_ v: [Vec2]) -> [Vec2] {
        let n = edgeNormals(v)
        return v.indices.map { i in
            let a = n[(i + v.count - 1) % v.count], b = n[i]
            return (a + b) / max(1 + a.dot(b), 0.25)
        }
    }

    /// The dilation direction of a point of a face: outwards across the
    /// edges it lies on, zero inside.
    static func outward(of p: Vec2, corners: [Vec2], normals: [Vec2], tolerance: Double) -> Vec2 {
        var on: [Vec2] = []
        for i in corners.indices where abs(normals[i].dot(p - corners[i])) <= tolerance {
            // Only within the edge's extent.
            let a = corners[i], b = corners[(i + 1) % corners.count]
            let t = (p - a).dot(b - a) / max((b - a).lengthSquared, 1e-300)
            if t > -1e-6 && t < 1 + 1e-6 { on.append(normals[i]) }
        }
        switch on.count {
        case 0: return .zero
        case 1: return on[0]
        default: return (on[0] + on[1]) / max(1 + on[0].dot(on[1]), 0.25)
        }
    }

    private func fill(_ dataset: DatasetID, _ state: MapState) -> GPUArray? {
        if let cached = fills[dataset] { return cached }
        guard available(.fills(dataset), state), let overlay = try? state.overlays.fills(dataset) else { return nil }
        var vertices: [SurfaceVertex] = []
        vertices.reserveCapacity(overlay.positions.count)
        let mesh = state.mesh
        var lastFace = -1
        var corners: [Vec2] = [], normals: [Vec2] = [], tolerance = 0.0
        for i in overlay.positions.indices {
            let p = overlay.positions[i], f = Int(overlay.faces[i])
            if f != lastFace {
                lastFace = f
                corners = mesh.frames[f].localVertices
                normals = Self.edgeNormals(corners)
                tolerance = 1e-9 * (corners.map(\.length).max() ?? 1)
            }
            let o = Self.outward(of: p, corners: corners, normals: normals, tolerance: tolerance)
            vertices.append(SurfaceVertex(local: SIMD2(Float(p.x), Float(p.y)), outward: SIMD2(Float(o.x), Float(o.y)),
                                          face: UInt32(f), paint: UInt32(max(overlay.features[i], 0))))
        }
        let array = GPUArray(device, vertices)
        fills[dataset] = array
        return array
    }

    /// Line instances for an overlay, with a style index per segment.
    private func lineArray(_ key: String, _ state: MapState, item: MeshOverlays.Item? = nil, style: (Int32) -> UInt32 = { _ in 0 },
                           _ make: () throws -> LineOverlay) -> GPUArray? {
        if let cached = lines[key] { return cached }
        if let item, !available(item, state) { return nil }
        guard let overlay = try? make() else { return nil }
        var instances: [LineInstance] = []
        instances.reserveCapacity(overlay.count)
        for i in 0..<overlay.count {
            instances.append(LineInstance(a: SIMD2(Float(overlay.a[i].x), Float(overlay.a[i].y)),
                                          b: SIMD2(Float(overlay.b[i].x), Float(overlay.b[i].y)),
                                          face: UInt32(overlay.faces[i]), style: style(overlay.attributes[i])))
        }
        let array = GPUArray(device, instances)
        lines[key] = array
        return array
    }

    private func meshLines(_ state: MapState) -> GPUArray? {
        lineArray("mesh", state) {
            let mesh = state.mesh
            var overlay = LineOverlay()
            for (e, edge) in mesh.topology.edges.enumerated() where !mesh.isInternalEdge[e] {
                let (a, b) = Self.localEdge(mesh, face: edge.leftFace, edge: edge)
                overlay.a.append(Vec2(Double(a.x), Double(a.y)))
                overlay.b.append(Vec2(Double(b.x), Double(b.y)))
                overlay.faces.append(Int32(edge.leftFace))
                overlay.attributes.append(0)
            }
            return overlay
        }
    }

    private func pointArray(_ key: String, _ make: () throws -> [PointInstance]) -> GPUArray? {
        if let cached = points[key] { return cached }
        let array = (try? make()).flatMap { GPUArray(device, $0) }
        points[key] = array
        return array
    }

    private func highlightLines(_ state: MapState, groups: [Int]) -> GPUArray? {
        guard groups != highlightKey else { return highlight }
        highlightKey = groups
        guard let labels = state.cut.faceGroups, !groups.isEmpty else {
            highlight = nil
            return nil
        }
        let wanted = Set(groups)
        let mesh = state.mesh, isCut = state.projection.unfolding.isCut
        var instances: [LineInstance] = []
        for (e, edge) in mesh.topology.edges.enumerated() {
            let inL = wanted.contains(labels[edge.leftFace]), inR = wanted.contains(labels[edge.rightFace])
            guard inL || inR else { continue }
            if inL && inR {
                guard isCut[e] else { continue }
                for f in [edge.leftFace, edge.rightFace] {
                    let (a, b) = Self.localEdge(mesh, face: f, edge: edge)
                    instances.append(LineInstance(a: a, b: b, face: UInt32(f), style: 0))
                }
            } else {
                let f = inL ? edge.leftFace : edge.rightFace
                let (a, b) = Self.localEdge(mesh, face: f, edge: edge)
                instances.append(LineInstance(a: a, b: b, face: UInt32(f), style: 0))
            }
        }
        highlight = GPUArray(device, instances)
        return highlight
    }

    private func preparePoses(_ state: MapState, unfold: Double, globe: Mat3, closing: Double) {
        let closing = unfold >= 1 && closing > 0 && state.closedGapsIfReady != nil ? closing : 0
        if let key = poseKey, key.0 == state.id, key.1 == unfold, key.2 == globe, key.3 == closing, poseBuffer != nil { return }
        let count = state.mesh.faceCount + 1
        let length = count * MemoryLayout<FacePoseGPU>.stride
        // A fresh buffer of the ring: earlier frames may still read theirs.
        guard let buffer = poseRing.next(device, length: length) else { return }
        poseBuffer = buffer
        let poses = buffer.contents().bindMemory(to: FacePoseGPU.self, capacity: count)
        if closing > 0, let gaps = state.closedGapsIfReady {
            // Closing the gaps bends every face by its own affine map.
            let frames = state.mesh.frames
            for f in 0..<state.mesh.faceCount {
                let (a, b, t) = gaps.affine(face: f, local: frames[f].localVertices, amount: closing)
                poses[f] = FacePoseGPU(r0: SIMD4(Float(a.x), Float(b.x), 0, Float(t.x)), r1: SIMD4(Float(a.y), Float(b.y), 0, Float(t.y)),
                                       r2: SIMD4(0, 0, 1, 0))
            }
        } else {
            state.poses.forEachPoseRows(unfold: unfold, globe: globe, scratch: foldScratch) { f, r0, r1, r2 in
                poses[f] = FacePoseGPU(r0: r0, r1: r1, r2: r2)
            }
        }
        // One more pose, the identity, for lines given in map coordinates.
        poses[count - 1] = FacePoseGPU(r0: SIMD4(1, 0, 0, 0), r1: SIMD4(0, 1, 0, 0), r2: SIMD4(0, 0, 1, 0))
        poseKey = (state.id, unfold, globe, closing)
    }

    // MARK: Textures

    private func texture(of field: GridField) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: field.width, height: field.height,
                                                         mipmapped: false)
        d.usage = .shaderRead
        // Unified memory shares; discrete GPUs (Intel Macs) need managed storage.
        d.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        let halves = field.values.map { Float16($0) }
        halves.withUnsafeBytes {
            t.replace(region: MTLRegionMake2D(0, 0, field.width, field.height), mipmapLevel: 0,
                      withBytes: $0.baseAddress!, bytesPerRow: field.width * 2)
        }
        return t
    }

    private func fieldTexture(_ key: FieldKey, _ data: BodyData) -> (texture: MTLTexture, field: GridField)? {
        let cacheKey = "\(data.body.id)/\(key)"
        if let cached = fieldTextures[cacheKey] { return cached }
        guard available(key, data), let field = try? data.field(key), let t = texture(of: field) else { return nil }
        if fieldTextures.count > 6 { fieldTextures.removeAll() }
        fieldTextures[cacheKey] = (t, field)
        return (t, field)
    }

    private func elevationTexture(_ data: BodyData) -> (texture: MTLTexture, field: GridField)? {
        if let cached = elevations[data.body.id] { return cached }
        let key = FieldKey("elevation")
        guard data.body.has(.elevation), available(key, data), let field = try? data.field(key), let t = texture(of: field)
        else { return nil }
        elevations[data.body.id] = (t, field)
        return (t, field)
    }

    private func lut(_ rows: [[RGBA]]) -> MTLTexture? {
        let flat = rows.flatMap { $0 }
        if let cached = luts[flat] { return cached }
        let width = rows[0].count
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: rows.count, mipmapped: false)
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        let bytes = flat.flatMap { c in [c.r, c.g, c.b, c.a].map { UInt8((min(max($0, 0), 1) * 255).rounded()) } }
        bytes.withUnsafeBytes {
            t.replace(region: MTLRegionMake2D(0, 0, width, rows.count), mipmapLevel: 0, withBytes: $0.baseAddress!,
                      bytesPerRow: width * 4)
        }
        if luts.count > 16 { luts.removeAll() }
        luts[flat] = t
        return t
    }

    private func placeholderTexture() -> MTLTexture {
        if let dummy { return dummy }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: 1, height: 1, mipmapped: false)
        let t = device.makeTexture(descriptor: d)!
        dummy = t
        return t
    }

    /// The value range a field's colour scale spans: robust quantiles,
    /// computed once per field and body.
    public static func range(of key: FieldKey, field: GridField, scale: FieldScale, data: BodyData) -> (Double, Double) {
        (try? data.cached("range:\(key)") { () -> RangeBox in
            switch scale {
            case .diverging: RangeBox(lo: min(field.quantile(0.02), -1e-6), hi: max(field.quantile(0.995), 1e-6))
            case .logarithmic: RangeBox(lo: 0, hi: max(field.quantile(0.995), 1e-6))
            case .linear: RangeBox(lo: max(field.range.lowerBound, 0), hi: field.quantile(0.99))
            }
        }).map { ($0.lo, $0.hi) } ?? (0, 1)
    }

    struct RangeBox: Sendable {
        let lo: Double
        let hi: Double
    }

    // MARK: Drawing

    /// Encodes one frame of `state` into a render pass whose colour target
    /// is `drawableSize` pixels.
    public func encode(_ state: MapState, settings s: FrameSettings, into encoder: MTLRenderCommandEncoder, drawableSize: CGSize) {
        prepareMesh(state)
        prepareState(state)
        preparePoses(state, unfold: s.unfold, globe: s.globe, closing: s.closing)
        guard let frames, let base, let poseBuffer else { return }
        // Long arms of a folding map may reach past the depth range: clamp, don't clip.
        encoder.setDepthClipMode(.clamp)
        var s = s
        let style = s.style
        let data = state.data
        let folded = s.unfold < 1
        // Worlds without seas show their relief instead of land and sea.
        if !data.body.hasSeas, case .landSea = s.coloring { s.coloring = .relief }
        // Height is drawn as relief: hypsometric tints and bathymetry on the
        // Earth, a world's own colours elsewhere.
        if case .field(let key) = s.coloring, key.id == "elevation" { s.coloring = .relief }
        let px = Float(s.pixelScale * s.lineScale)

        var view = ViewUniforms(viewProjection: s.viewport.matrix(), viewportSize: SIMD2(Float(drawableSize.width), Float(drawableSize.height)),
                                fold: Float(1 - min(max(s.unfold, 0), 1)), depthBias: 0,
                                light: SIMD4(-0.45, 0.55, 0.7, s.sealSlits && !folded ? Float(0.6 * s.pixelScale) : 0))
        var surface = SurfaceUniforms(
            oceanColor: style.ocean.simd, backfaceColor: style.backface.simd, nightColor: style.night.simd,
            graticuleColor: style.graticule.simd, sun: .zero, fieldGrid: .zero, fieldSizeRange: SIMD4(1, 1, 0, 1),
            elevationGrid: .zero, elevationSize: SIMD4(1, 1, 0, 1),
            graticule: SIMD4(s.layers.contains(.graticule) ? Float(s.graticuleStep) : 0, 1.0 * px, 0, 0),
            reliefRange: .zero,
            baseMode: 0, fieldScale: 0, hasElevation: 0, fieldOverlay: 0)
        if s.layers.contains(.night) {
            let sun = SolarPosition.sunDirection(at: s.date)
            surface.sun = SIMD4(Float(sun.x), Float(sun.y), Float(sun.z), 1)
        }

        // Textures: field, its colour scale, elevation and relief tints.
        var fieldTex: MTLTexture = placeholderTexture()
        var fieldLUT: MTLTexture? = lut([style.colormap(.sequential).table()])
        // Densities fade in over the base: land and sea, or on worlds
        // without seas their relief.
        var reliefUnderField = false
        if case .field(let key) = s.coloring, let descriptor = data.body.field(key.id),
           let (t, field) = fieldTexture(key, data) {
            fieldTex = t
            let (lo, hi) = Self.range(of: key, field: field, scale: descriptor.scale, data: data)
            surface.fieldGrid = SIMD4(Float(field.lon0), Float(field.lat0), Float(field.dlon), Float(field.dlat))
            surface.fieldSizeRange = SIMD4(Float(field.width), Float(field.height), Float(lo), Float(hi))
            surface.fieldScale = descriptor.scale == .diverging ? 1 : 0
            if descriptor.scale == .logarithmic || descriptor.colormap == .density {
                surface.fieldOverlay = 2
                reliefUnderField = !data.body.hasSeas
            } else {
                surface.baseMode = 1
            }
            fieldLUT = lut([style.colormap(descriptor.colormap).table()])
        }
        let reliefColoring = reliefUnderField || { if case .relief = s.coloring { return true }; return false }()
        let wantsRelief = style.hillshade > 0 || reliefColoring
        var elevationTex: MTLTexture = placeholderTexture()
        if wantsRelief, s.layers.contains(.land) || reliefColoring,
           let (t, field) = elevationTexture(data) {
            elevationTex = t
            surface.hasElevation = 1
            surface.elevationGrid = SIMD4(Float(field.lon0), Float(field.lat0), Float(field.dlon), Float(field.dlat))
            // Slopes are measured in Earth metres per degree; smaller worlds have steeper degrees.
            let exaggeration = 18 * Float(6371.0 / data.body.radius)
            surface.elevationSize = SIMD4(Float(field.width), Float(field.height), Float(style.hillshade), exaggeration)
        }
        if reliefColoring, surface.hasElevation == 1 { surface.baseMode = 2 }
        if case .groups = s.coloring { surface.baseMode = 3 }
        var reliefLUT = lut([style.reliefSea.table(), style.reliefLand.table()])
        if let tint = data.body.relief, let (_, field) = elevationTexture(data) {
            let table = Colormap(hex: tint.stops).table()
            reliefLUT = lut([table, table])
            let range = (try? data.cached("range:relief") { RangeBox(lo: field.quantile(0.003), hi: field.quantile(0.997)) })
                ?? RangeBox(lo: -1, hi: 1)
            surface.reliefRange = SIMD4(Float(range.lo), Float(range.hi), 1, 0)
        }

        // An atmosphere around the globe while it is folded.
        if folded && s.atmosphere {
            let closed = Float(1 - min(max(s.unfold, 0), 1))
            let radius = Float(s.viewport.scale * s.pixelScale)
            let darkPage = style.background.relativeLuminance < 0.2
            let air = style.ocean.perceptualMix(with: .white, darkPage ? 0.35 : 0.15)
            var styles = [LineStyleGPU(color: air.withAlpha((darkPage ? 0.55 : 0.35) * pow(Double(closed), 6)).simd,
                                       width: 0, glow: radius * 0.16)]
            var halo = [PointInstance(local: .zero, face: UInt32(state.mesh.faceCount), style: 0, radius: radius * 0.98)]
            var flatView = view
            flatView.viewportSize = view.viewportSize
            encoder.setRenderPipelineState(pipelines.point)
            encoder.setDepthStencilState(pipelines.depthOff)
            encoder.setVertexBytes(&halo, length: MemoryLayout<PointInstance>.stride, index: 0)
            encoder.setVertexBuffer(poseBuffer, offset: 0, index: 1)
            encoder.setVertexBytes(&styles, length: MemoryLayout<LineStyleGPU>.stride, index: 2)
            encoder.setVertexBytes(&flatView, length: MemoryLayout<ViewUniforms>.stride, index: 3)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
        }

        encoder.setDepthStencilState(folded ? pipelines.depthWrite : pipelines.depthOff)

        // Surfaces.
        encoder.setRenderPipelineState(pipelines.surface)
        encoder.setVertexBuffer(frames.buffer, offset: 0, index: 1)
        encoder.setVertexBuffer(poseBuffer, offset: 0, index: 2)
        encoder.setFragmentTexture(fieldTex, index: 0)
        encoder.setFragmentTexture(fieldLUT, index: 1)
        encoder.setFragmentTexture(elevationTex, index: 2)
        encoder.setFragmentTexture(reliefLUT, index: 3)
        encoder.setFragmentBytes(&surface, length: MemoryLayout<SurfaceUniforms>.stride, index: 0)
        let groupPaints = style.categorical.map { PaintGPU(color: $0.simd, mode: surface.hasElevation == 1 ? 2 : 0) }
        var layer: Float = 0

        func drawSurface(_ array: GPUArray, paints: [PaintGPU]) {
            view.depthBias = folded ? -layer * 2e-5 : 0
            layer += 1
            encoder.setVertexBuffer(array.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&view, length: MemoryLayout<ViewUniforms>.stride, index: 3)
            encoder.setFragmentBytes(&view, length: MemoryLayout<ViewUniforms>.stride, index: 3)
            var paints = paints.isEmpty ? [PaintGPU(color: style.ocean.simd, mode: 0)] : paints
            if paints.count * MemoryLayout<PaintGPU>.stride <= 4096 {
                encoder.setFragmentBytes(&paints, length: paints.count * MemoryLayout<PaintGPU>.stride, index: 1)
            } else {
                // Large paint tables (countries, lakes) are kept between frames.
                let key = "\(paints.count):\(paints.first.map { "\($0.color)\($0.mode)" } ?? ""):\(paints.last.map { "\($0.color)" } ?? "")"
                if paintBuffers[key] == nil { paintBuffers[key] = GPUArray(device, paints) }
                if let b = paintBuffers[key] { encoder.setFragmentBuffer(b.buffer, offset: 0, index: 1) }
            }
            if let facePaints {
                encoder.setFragmentBuffer(facePaints.buffer, offset: 0, index: 2)
            } else {
                var zero: UInt32 = 0
                encoder.setFragmentBytes(&zero, length: 4, index: 2)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: array.count)
        }

        drawSurface(base, paints: groupPaints)
        let landMode: UInt32 = {
            if case .relief = s.coloring { return surface.hasElevation == 1 ? 1 : 0 }
            return surface.hasElevation == 1 ? 2 : 0
        }()
        if case .regions(let dataset) = s.coloring,
           available(state.context.hasFaceRegions(dataset), key: "\(state.id):regions:\(dataset)", { [context = state.context] in
               _ = try? context.faceRegions(dataset)
           }),
           let regions = fill(dataset, state) {
            let count = (dataset == .timeZones ? (try? data.timeZones().regions.count) : (try? data.regions(dataset).count)) ?? 0
            let slots = regionSlots(dataset, state)
            let paints = (0..<max(count, 1)).map { r in
                PaintGPU(color: style.categorical[(slots[r] ?? r) % style.categorical.count].mixed(with: style.background, 0.18).simd, mode: 0)
            }
            drawSurface(regions, paints: paints)
            // Land shows through as a hill-shaded tint over the regions.
            if s.layers.contains(.land), let land = fill(.land, state) {
                let dilation = view.light.w
                view.light.w = 0
                let tint = RGBA(0, 0, 0, style.background.relativeLuminance > 0.4 ? 0.07 : 0.22)
                drawSurface(land, paints: [PaintGPU(color: tint.simd, mode: 5)])
                view.light.w = dilation
            }
        } else if s.layers.contains(.land), let land = fill(.land, state) {
            drawSurface(land, paints: [PaintGPU(color: style.land.simd, mode: landMode)])
        }
        if s.layers.contains(.lakes), s.layers.contains(.land) || { if case .regions = s.coloring { return true }; return false }(),
           let lakes = fill(.lakes, state) {
            let count = (try? data.regions(.lakes).count) ?? 1
            let mode: UInt32 = { if case .relief = s.coloring { return 0 }; return 0 }()
            drawSurface(lakes, paints: Array(repeating: PaintGPU(color: style.ocean.simd, mode: mode), count: max(count, 1)))
        }

        // Lines.
        encoder.setRenderPipelineState(pipelines.line)
        encoder.setDepthStencilState(folded ? pipelines.depthTest : pipelines.depthOff)
        encoder.setVertexBuffer(poseBuffer, offset: 0, index: 1)
        view.depthBias = folded ? -(layer + 4) * 2e-5 : 0
        encoder.setVertexBytes(&view, length: MemoryLayout<ViewUniforms>.stride, index: 3)
        let zoomBoost = Float(min(max(log2(max(s.viewport.zoom, 1)) * 0.25, 0), 1))

        func drawLines(_ array: GPUArray?, _ styles: [LineStyleGPU]) {
            guard let array, !styles.isEmpty else { return }
            var styles = styles
            encoder.setVertexBuffer(array.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&styles, length: styles.count * MemoryLayout<LineStyleGPU>.stride, index: 2)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: array.count)
        }
        func lineStyle(_ c: RGBA, _ width: Float, glow: Float = 0) -> LineStyleGPU {
            LineStyleGPU(color: c.simd, width: width * px * (1 + zoomBoost), glow: glow * px)
        }

        if s.layers.contains(.mesh) { drawLines(meshLines(state), [lineStyle(style.mesh, 0.6)]) }
        if s.layers.contains(.timeZoneBorders) {
            drawLines(lineArray("tz", state, item: .lines(.timeZones)) { try state.overlays.lines(.timeZones) }, [lineStyle(style.border, 0.7)])
        }
        if s.layers.contains(.countryBorders) {
            drawLines(lineArray("borders", state, item: .lines(.countryBorders)) { try state.overlays.lines(.countryBorders) }, [lineStyle(style.border, 0.8)])
        }
        if s.layers.contains(.lakes) && s.layers.contains(.coastlines) {
            drawLines(lineArray("lakeshores", state, item: .lines(.lakes)) { try state.overlays.lines(.lakes) }, [lineStyle(style.coastline, 0.5)])
        }
        if s.layers.contains(.rivers) {
            drawLines(lineArray("rivers", state, item: .lines(.rivers), style: { $0 <= 2 ? 0 : ($0 <= 4 ? 1 : 2) }) { try state.overlays.lines(.rivers) },
                      [lineStyle(style.river, 1.6), lineStyle(style.river, 1.0), lineStyle(style.river.withAlpha(style.river.a * 0.8), 0.6)])
        }
        if s.layers.contains(.coastlines) {
            drawLines(lineArray("coast", state, item: .coastlines) { try state.overlays.coastlines() }, [lineStyle(style.coastline, 0.75)])
        }
        if s.layers.contains(.plateBoundaries) {
            drawLines(lineArray("plates", state, item: .lines(.plateBoundaries), style: { UInt32(max(0, min($0, 4))) }) { try state.overlays.lines(.plateBoundaries) },
                      PlateBoundaryKind.allCases.map { lineStyle(style.boundary($0), $0 == .other ? 1.0 : 1.8, glow: 0) })
        }
        if s.layers.contains(.flights) {
            let darkPage = style.background.relativeLuminance < 0.2
            // Light pages get fewer, finer arcs; on dark ones they glow.
            let limit = darkPage ? 2500 : 1200
            let k = darkPage ? 1.0 : 0.6
            drawLines(lineArray("flights:\(limit)", state, item: .flights(limit: limit), style: { $0 >= 6 ? 0 : ($0 >= 3 ? 1 : 2) }) { try state.overlays.flightArcs(limit: limit) },
                      [lineStyle(style.route.withAlpha(min(style.route.a * 2 * k, 1)), 0.9, glow: darkPage ? 2 : 0),
                       lineStyle(style.route.withAlpha(style.route.a * 1.2 * k), 0.6, glow: darkPage ? 1 : 0),
                       lineStyle(style.route.withAlpha(style.route.a * 0.8 * k), 0.45)])
        }
        if s.layers.contains(.tissot) {
            drawLines(lineArray("tissot", state, item: .tissot) { state.overlays.tissot() }, [lineStyle(style.tissot, 1.1)])
        }
        if s.layers.contains(.cuts) { drawLines(cutLines, [lineStyle(style.cut, 0.9)]) }
        if !s.highlightGroups.isEmpty, !folded {
            drawLines(highlightLines(state, groups: s.highlightGroups), [lineStyle(style.highlight, 1.8)])
        }
        if !s.mapLines.isEmpty, !folded {
            let face = UInt32(state.mesh.faceCount)
            let buckets = 4
            let instances = s.mapLines.map { l in
                LineInstance(a: SIMD2(Float(l.a.x), Float(l.a.y)), b: SIMD2(Float(l.b.x), Float(l.b.y)), face: face,
                             style: UInt32(min(buckets - 1, max(0, Int(l.alpha * Float(buckets))))))
            }
            let length = instances.count * MemoryLayout<LineInstance>.stride
            if let buffer = lineRing.next(device, length: length) {
                instances.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: length) }
                var styles = (0..<buckets).map { lineStyle(style.wind.withAlpha(style.wind.a * (Double($0) + 1) / Double(buckets)), 1.1) }
                encoder.setVertexBuffer(buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&styles, length: styles.count * MemoryLayout<LineStyleGPU>.stride, index: 2)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: instances.count)
            }
        }

        // Points.
        encoder.setRenderPipelineState(pipelines.point)
        encoder.setVertexBuffer(poseBuffer, offset: 0, index: 1)
        if !s.markers.isEmpty, !folded {
            // A found place: a dot with a ring that pulses outwards.
            for marker in s.markers {
                let face = UInt32(state.mesh.faceCount)
                let ring = Float(6 + 22 * marker.phase) * px
                var points = [PointInstance(local: SIMD2(Float(marker.point.x), Float(marker.point.y)), face: face, style: 0, radius: ring),
                              PointInstance(local: SIMD2(Float(marker.point.x), Float(marker.point.y)), face: face, style: 1, radius: 4 * px)]
                var styles = [LineStyleGPU(color: style.highlight.withAlpha(0.55 * (1 - marker.phase)).simd, width: 0, glow: 4 * px),
                              LineStyleGPU(color: style.cut.simd, width: 0, glow: 2 * px)]
                encoder.setVertexBytes(&points, length: points.count * MemoryLayout<PointInstance>.stride, index: 0)
                encoder.setVertexBytes(&styles, length: styles.count * MemoryLayout<LineStyleGPU>.stride, index: 2)
                encoder.setVertexBytes(&view, length: MemoryLayout<ViewUniforms>.stride, index: 3)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: points.count)
            }
        }
        if s.layers.contains(.cities), points["cities"] != nil || available(.cities(limit: 600), state) {
            let cities = pointArray("cities") {
                let overlay = try state.overlays.cities()
                let places = try data.places().places
                return overlay.positions.indices.map { i in
                    let pop = Double(places[Int(overlay.items[i])].pop)
                    return PointInstance(local: SIMD2(Float(overlay.positions[i].x), Float(overlay.positions[i].y)),
                                         face: UInt32(overlay.faces[i]), style: 0,
                                         radius: Float(min(max(0.8 + 0.9 * log10(max(pop, 1e5) / 1e5), 0.8), 3.2)))
                }
            }
            if let cities {
                var styles = [LineStyleGPU(color: style.city.simd, width: 0, glow: Float(style.background.relativeLuminance < 0.2 ? 3 : 0) * px)]
                // Radii are stored in points; scale them to pixels.
                encoder.setVertexBuffer(cities.buffer, offset: 0, index: 0)
                encoder.setVertexBytes(&styles, length: MemoryLayout<LineStyleGPU>.stride, index: 2)
                var scaled = view
                scaled.viewportSize = view.viewportSize / px
                encoder.setVertexBytes(&scaled, length: MemoryLayout<ViewUniforms>.stride, index: 3)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: cities.count)
            }
        }
    }

    private func regionSlots(_ dataset: DatasetID, _ state: MapState) -> [Int: Int] {
        if let cached = regionPaints[dataset] { return cached.slots }
        let labels = (try? state.context.faceRegions(dataset)) ?? []
        let slots = labels.isEmpty ? [:] : RegionColoring.slots(labels: labels, mesh: state.mesh, slotCount: 6)
        regionPaints[dataset] = (slots, slots.count)
        return slots
    }

    // MARK: Off screen

    /// Renders a frame into an image of `width × height` pixels. The
    /// settings' viewport size is taken as points; `pixelScale` maps them.
    public func image(_ state: MapState, settings: FrameSettings, width: Int, height: Int) throws -> CGImage {
        func texture(_ format: MTLPixelFormat, samples: Int, usage: MTLTextureUsage, storage: MTLStorageMode) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.sampleCount = samples
            d.usage = usage
            d.storageMode = storage
            guard let t = device.makeTexture(descriptor: d) else { throw RenderError.allocation("\(width)×\(height) target") }
            return t
        }
        let resolve = try texture(pixelFormat, samples: 1, usage: [.renderTarget, .shaderRead],
                                  storage: device.hasUnifiedMemory ? .shared : .managed)
        let pass = MTLRenderPassDescriptor()
        let color = pass.colorAttachments[0]!
        if sampleCount > 1 {
            color.texture = try texture(pixelFormat, samples: sampleCount, usage: .renderTarget, storage: .private)
            color.resolveTexture = resolve
            color.storeAction = .multisampleResolve
        } else {
            color.texture = resolve
            color.storeAction = .store
        }
        color.loadAction = .clear
        let bg = settings.style.background
        color.clearColor = MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)
        pass.depthAttachment.texture = try texture(.depth32Float, samples: sampleCount, usage: .renderTarget, storage: .private)
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare

        guard let buffer = queue.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw RenderError.allocation("command buffer")
        }
        encode(state, settings: settings, into: encoder, drawableSize: CGSize(width: width, height: height))
        encoder.endEncoding()
        if resolve.storageMode == .managed, let blit = buffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: resolve)
            blit.endEncoding()
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error { throw RenderError.allocation("GPU work failed: \(error)") }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        resolve.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw RenderError.allocation("image") }
        return image
    }
}

extension RGBA {
    var simd: SIMD4<Float> { SIMD4(Float(r), Float(g), Float(b), Float(a)) }
}
