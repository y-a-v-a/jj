import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MyriaCore
import MyriaLayouts
import UniformTypeIdentifiers

/// A myriahedral globe to print, cut out and fold: the map's net on sheets
/// of paper, as a PDF with cut lines, fold lines and numbered glue tabs.
public enum PaperGlobe {
    /// How many faces the paper globe has.
    public enum Detail: String, CaseIterable, Sendable {
        case simple, detailed, fine

        public var title: String {
            switch self {
            case .simple: "Simple (about 80 faces)"
            case .detailed: "Detailed (about 320 faces)"
            case .fine: "Fine (about 720 faces)"
            }
        }
    }

    /// A myriahedron coarse enough to fold by hand, of the same kind as the
    /// layout's own; nil when the layout chooses its own solid.
    public static func mesh(for descriptor: LayoutDescriptor, detail: Detail) -> MeshKind? {
        guard !descriptor.fixesMesh else { return nil }
        let level = Detail.allCases.firstIndex(of: detail)!
        return switch descriptor.preferredMesh {
        case .graticule: .graticule(step: [30, 15, 10][level])
        case .hexagonal: .hexagonal(frequency: [3, 5, 8][level])
        case .geodesic, .platonic: .geodesic(frequency: [2, 4, 6][level])
        }
    }

    /// Parameters for the paper: layouts that subdivide their own solid
    /// subdivide it only as far as hands can fold (80, 320 or 1280 faces).
    public static func parameters(_ parameters: LayoutParameters, for descriptor: LayoutDescriptor,
                                  detail: Detail) -> LayoutParameters {
        var p = parameters
        if descriptor.parameter("levels") != nil { p["levels"] = Double(Detail.allCases.firstIndex(of: detail)! + 1) }
        return p
    }

    /// More faces than anyone would cut out.
    public static let maximumFaces = 6000

    public enum Failure: Error, CustomStringConvertible {
        case tooManyFaces(Int)

        public var description: String {
            switch self {
            case .tooManyFaces(let n): "\(n.formatted()) faces are too many to cut out; choose a coarser myriahedron (at most \(maximumFaces.formatted()))"
            }
        }
    }

    public struct Result: Sendable {
        public let net: PaperNet
        public let pdf: Data
    }

    /// Lays out the net of `state` and draws it as a PDF.
    /// - Parameters:
    ///   - settings: how to paint the map (palette, colouring, layers); the
    ///     viewport is replaced.
    ///   - dpi: resolution of the map imagery, lowered for very large globes.
    public static func make(_ state: MapState, options: PaperNet.Options, renderer: MapRenderer, settings: FrameSettings,
                            title: String, dpi: Double = 300) throws -> Result {
        guard state.mesh.faceCount <= maximumFaces else { throw Failure.tooManyFaces(state.mesh.faceCount) }
        let net = try PaperNet(projection: state.projection, options: options)
        let tiles = try imagery(state, net: net, renderer: renderer, settings: settings, dpi: dpi)
        let pdf = try draw(net, state: state, tiles: tiles, title: title)
        return Result(net: net, pdf: pdf)
    }

    /// A sheet of a paper globe's PDF as an image `width` pixels wide.
    public static func page(_ pdf: Data, index: Int, width: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: index + 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let scale = Double(width) / box.width
        guard let ctx = CGContext(data: nil, width: width, height: Int((box.height * scale).rounded()), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: scale, y: scale)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    // MARK: Imagery

    struct Tile {
        let rect: Rect2
        let image: CGImage
    }

    /// The unfolded map rendered in square tiles over the faces, in map
    /// units, kept as JPEG so the PDF stays small.
    static func imagery(_ state: MapState, net: PaperNet, renderer: MapRenderer, settings base: FrameSettings,
                        dpi requested: Double) throws -> [Tile] {
        let size = 2048
        let bounds = state.projection.bounds
        let boxes = net.polygons.map { Rect2(bounding: $0) }
        func plan(_ dpi: Double) -> [Rect2] {
            let unit = Double(size) / (net.options.scale / 25.4 * dpi)
            let cols = Int((bounds.width / unit).rounded(.up)), rows = Int((bounds.height / unit).rounded(.up))
            var rects: [Rect2] = []
            for row in 0..<max(rows, 1) {
                for col in 0..<max(cols, 1) {
                    let r = Rect2(minX: bounds.minX + Double(col) * unit, minY: bounds.minY + Double(row) * unit,
                                  maxX: bounds.minX + Double(col + 1) * unit, maxY: bounds.minY + Double(row + 1) * unit)
                    if boxes.contains(where: { $0.minX < r.maxX && r.minX < $0.maxX && $0.minY < r.maxY && r.minY < $0.maxY }) {
                        rects.append(r)
                    }
                }
            }
            return rects
        }
        // About 160 megapixels at most.
        var dpi = requested
        var rects = plan(dpi)
        let budget = 160_000_000.0
        if Double(rects.count * size * size) > budget {
            dpi *= (budget / Double(rects.count * size * size)).squareRoot()
            rects = plan(dpi)
        }
        var settings = base
        settings.unfold = 1
        settings.sealSlits = true
        settings.atmosphere = false
        settings.markers = []
        settings.pixelScale = 1
        settings.lineScale = max(1, dpi / 160)
        // Tiles overlap by a few pixels, so no hairline shows where they meet.
        let pad = 4
        let padUnits = Double(pad) / (net.options.scale / 25.4 * dpi)
        return try rects.map { r in
            let padded = Rect2(minX: r.minX - padUnits, minY: r.minY - padUnits, maxX: r.maxX + padUnits, maxY: r.maxY + padUnits)
            let side = size + 2 * pad
            settings.viewport = Viewport(bounds: padded, size: Vec2(Double(side), Double(side)), margin: 0)
            let image = try renderer.image(state, settings: settings, width: side, height: side)
            return Tile(rect: padded, image: try jpeg(image))
        }
    }

    static func jpeg(_ image: CGImage) throws -> CGImage {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw RenderError.allocation("JPEG encoder")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: data),
              let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw RenderError.allocation("JPEG data") }
        return jpeg
    }

    // MARK: PDF

    static let millimetre = 72 / 25.4

    static func draw(_ net: PaperNet, state: MapState, tiles: [Tile], title: String) throws -> Data {
        let o = net.options
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: o.sheet.x * millimetre, height: o.sheet.y * millimetre)
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: "\(title) — paper globe",
                                                                        kCGPDFContextCreator: "JJ"] as CFDictionary)
        else { throw RenderError.allocation("PDF context") }
        let mesh = state.mesh
        let ink = CGColor(gray: 0.1, alpha: 1), grey = CGColor(gray: 0.45, alpha: 1)
        for sheet in 0..<net.sheetCount {
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            ctx.scaleBy(x: millimetre, y: millimetre)
            if sheet == 0 { header(ctx, net: net, state: state, title: title) }
            text(ctx, "\(title) · paper globe · sheet \(sheet + 1) of \(net.sheetCount) · made with JJ, after Jarke van Wijk's myriahedral projections",
                 size: 2.2, at: CGPoint(x: o.sheet.x / 2, y: o.margin / 2), color: grey)
            for p in net.pieces(onSheet: sheet) {
                let piece = net.pieces[p]
                let place = piece.placement
                func sheetPoint(_ q: Vec2) -> CGPoint { let v = place.apply(q); return CGPoint(x: v.x, y: v.y) }
                func path(_ poly: [Vec2]) -> CGPath {
                    let path = CGMutablePath()
                    path.addLines(between: poly.map(sheetPoint))
                    path.closeSubpath()
                    return path
                }

                // The map, clipped to the piece.
                ctx.saveGState()
                let outline = CGMutablePath()
                var bounds = Rect2.empty
                for f in piece.faces {
                    outline.addPath(path(net.polygons[f]))
                    bounds.include(Rect2(bounding: net.polygons[f]))
                }
                ctx.addPath(outline)
                ctx.clip()
                let c = cos(place.rotation) * place.scale, s = sin(place.rotation) * place.scale
                ctx.concatenate(CGAffineTransform(a: c, b: s, c: -s, d: c, tx: place.offset.x, ty: place.offset.y))
                ctx.interpolationQuality = .high
                for tile in tiles where tile.rect.minX < bounds.maxX && bounds.minX < tile.rect.maxX
                    && tile.rect.minY < bounds.maxY && bounds.minY < tile.rect.maxY {
                    ctx.draw(tile.image, in: CGRect(x: tile.rect.minX, y: tile.rect.minY, width: tile.rect.width, height: tile.rect.height))
                }
                ctx.restoreGState()

                // Folds: dashed, inside the piece and along the base of tabs.
                ctx.saveGState()
                ctx.setStrokeColor(CGColor(gray: 0.3, alpha: 0.85))
                ctx.setLineWidth(0.16)
                ctx.setLineDash(phase: 0, lengths: [1.1, 0.8])
                let inPiece = Set(piece.faces)
                for e in net.folds {
                    let edge = mesh.topology.edges[e]
                    guard inPiece.contains(edge.leftFace) else { continue }
                    let (a, b) = net.segment(of: e, in: edge.leftFace, mesh: mesh)
                    ctx.move(to: sheetPoint(a))
                    ctx.addLine(to: sheetPoint(b))
                }
                for seam in net.seams where seam.tabFace.map(inPiece.contains) == true {
                    ctx.move(to: sheetPoint(seam.tab[0]))
                    ctx.addLine(to: sheetPoint(seam.tab[1]))
                }
                ctx.strokePath()
                ctx.restoreGState()

                // Tabs, then every cut line, solid.
                ctx.saveGState()
                ctx.setLineWidth(0.22)
                ctx.setLineJoin(.round)
                ctx.setStrokeColor(ink)
                for seam in net.seams {
                    guard let f = seam.tabFace, inPiece.contains(f) else { continue }
                    let tab = seam.tab
                    ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
                    ctx.addPath(path(tab))
                    ctx.fillPath()
                    ctx.move(to: sheetPoint(tab[1]))
                    for q in tab[2...] { ctx.addLine(to: sheetPoint(q)) }
                    ctx.addLine(to: sheetPoint(tab[0]))
                    ctx.strokePath()
                    let base = (place.apply(tab[1]) - place.apply(tab[0])).length
                    label(ctx, seam.number, at: place.apply(Planar.centroid(tab)), along: place.apply(tab[1]) - place.apply(tab[0]),
                          size: min(3.4, base * 0.2, o.tabHeight * 0.6), boxed: false)
                }
                for seam in net.seams {
                    let edge = mesh.topology.edges[seam.edge]
                    for f in [edge.leftFace, edge.rightFace] where inPiece.contains(f) {
                        let (a, b) = net.segment(of: seam.edge, in: f, mesh: mesh)
                        var pieces = [(a, b)]
                        if seam.tabFace == f {
                            // Beside a short tab the rest of the edge is cut.
                            let near = (seam.tab[0] - a).length < (seam.tab[1] - a).length
                            let (ta, tb) = near ? (seam.tab[0], seam.tab[1]) : (seam.tab[1], seam.tab[0])
                            pieces = [(a, ta), (tb, b)].filter { ($0.1 - $0.0).length > 1e-9 }
                        }
                        for (p, q) in pieces {
                            ctx.move(to: sheetPoint(p))
                            ctx.addLine(to: sheetPoint(q))
                        }
                    }
                }
                ctx.strokePath()
                ctx.restoreGState()

                // Numbers on the receiving edges, just inside the face.
                for seam in net.seams where seam.isNumbered {
                    let edge = mesh.topology.edges[seam.edge]
                    for f in [edge.leftFace, edge.rightFace] where inPiece.contains(f) && seam.tabFace != f {
                        let (a, b) = net.segment(of: seam.edge, in: f, mesh: mesh)
                        let pa = place.apply(a), pb = place.apply(b)
                        let centre = place.apply(Planar.centroid(net.polygons[f]))
                        let mid = (pa + pb) / 2
                        let size = min(3.2, (pb - pa).length * 0.16)
                        guard size > 0.8 else { continue }
                        let inward = (centre - mid).normalized
                        let depth = min(size * 0.95 + 0.4, (centre - mid).length * 0.6)
                        label(ctx, seam.number, at: mid + inward * depth, along: pb - pa, size: size, boxed: true)
                    }
                }
            }
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    static func header(_ ctx: CGContext, net: PaperNet, state: MapState, title: String) {
        let o = net.options
        let x = o.margin
        var y = o.sheet.y - o.margin - 5
        let grey = CGColor(gray: 0.35, alpha: 1)
        text(ctx, title, size: 5.2, at: CGPoint(x: x, y: y), bold: true, centered: false)
        y -= 5
        let faces = state.mesh.cellCount
        let diameter = o.diameter / 10
        let body = state.data.body
        let world = ["earth", "moon"].contains(body.id) ? "the \(body.name)" : body.name
        text(ctx, "A paper globe of \(world): \(faces.formatted()) faces in \(net.pieces.count) \(net.pieces.count == 1 ? "piece" : "pieces") · \(String(format: "%g", diameter)) cm across when folded",
             size: 2.9, at: CGPoint(x: x, y: y), color: grey, centered: false)
        y -= 5.2
        let steps = [
            "1  Cut along the solid lines, tabs included.",
            "2  Crease every dashed line, keeping the print on the outside.",
            "3  Glue each grey tab under the edge with the same number. Narrow slits close edge to edge; a strip of tape inside holds them.",
        ]
        for step in steps {
            text(ctx, step, size: 2.5, at: CGPoint(x: x, y: y), centered: false)
            y -= 3.8
        }
    }

    /// A seam number, set along an edge and kept upright.
    static func label(_ ctx: CGContext, _ number: Int, at p: Vec2, along d: Vec2, size: Double, boxed: Bool) {
        var angle = atan2(d.y, d.x)
        if angle > .pi / 2 { angle -= .pi } else if angle <= -.pi / 2 { angle += .pi }
        text(ctx, "\(number)", size: size, at: CGPoint(x: p.x, y: p.y), angle: angle, bold: true,
             color: CGColor(gray: boxed ? 0.05 : 0.3, alpha: 1), box: boxed ? CGColor(gray: 1, alpha: 0.78) : nil)
    }

    /// Draws a line of text (size in millimetres), centred on `p` or starting there.
    static func text(_ ctx: CGContext, _ string: String, size: Double, at p: CGPoint, angle: Double = 0, bold: Bool = false,
                     color: CGColor = CGColor(gray: 0.1, alpha: 1), centered: Bool = true, box: CGColor? = nil) {
        guard let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) else { return }
        let attributes: [NSAttributedString.Key: Any] = [kCTFontAttributeName as NSAttributedString.Key: font,
                          kCTForegroundColorAttributeName as NSAttributedString.Key: color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: angle)
        let origin = CGPoint(x: centered ? -bounds.midX : 0, y: centered ? -bounds.midY : 0)
        if let box {
            let r = bounds.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -size * 0.25, dy: -size * 0.12)
            ctx.setFillColor(box)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: size * 0.3, cornerHeight: size * 0.3, transform: nil))
            ctx.fillPath()
        }
        ctx.textPosition = origin
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}
