import CoreGraphics
import CoreText
import Foundation
import MyriaCore
import MyriaData

/// The flat map on one large sheet, as a PDF: the map's imagery at print
/// resolution on the palette's page, a title and the credits.
public enum Poster {
    /// ISO sheets, portrait size in millimetres.
    public enum Paper: String, CaseIterable, Sendable {
        case a3, a2, a1, a0

        public var size: Vec2 {
            switch self {
            case .a3: Vec2(297, 420)
            case .a2: Vec2(420, 594)
            case .a1: Vec2(594, 841)
            case .a0: Vec2(841, 1189)
            }
        }

        public var title: String { rawValue.uppercased() }
    }

    /// Lays the map out on `paper` (landscape when the map is wide) and
    /// draws it. `settings` paints the map, its `closing` included.
    /// - Parameters:
    ///   - title: the poster's title, usually the layout's.
    ///   - subtitle: a line under it (the layout's summary).
    public static func make(_ state: MapState, paper: Paper, renderer: MapRenderer, settings: FrameSettings,
                            title: String, subtitle: String, dpi: Double = 300) throws -> Data {
        let closing = settings.unfold >= 1 ? settings.closing : 0
        let bounds = state.bounds(closing: closing)
        let landscape = bounds.width > bounds.height
        let sheet = landscape ? Vec2(paper.size.y, paper.size.x) : paper.size
        // Everything scales with the sheet: units of an A3's short side.
        let unit = min(sheet.x, sheet.y) / 297
        let margin = 15 * unit, footer = 36 * unit
        let area = Rect2(minX: margin, minY: margin + footer, maxX: sheet.x - margin, maxY: sheet.y - margin)
        let scale = min(area.width / max(bounds.width, 1e-9), area.height / max(bounds.height, 1e-9))
        // Map units → millimetres, centred in the area.
        let offset = Vec2(area.center.x - bounds.center.x * scale, area.center.y - bounds.center.y * scale)

        let polygons: [[Vec2]]
        if closing > 0, let gaps = state.closedGapsIfReady {
            polygons = state.projection.mapPolygons.indices.map { gaps.corners(of: $0, amount: closing) }
        } else {
            polygons = state.projection.mapPolygons
        }
        let tiles = try PaperGlobe.imagery(state, polygons: polygons, bounds: bounds, millimetresPerUnit: scale,
                                           renderer: renderer, settings: settings, dpi: dpi)

        let data = NSMutableData()
        let mm = 72 / 25.4
        var box = CGRect(x: 0, y: 0, width: sheet.x * mm, height: sheet.y * mm)
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: title, kCGPDFContextCreator: "JJ"] as CFDictionary)
        else { throw RenderError.allocation("PDF context") }
        let style = settings.style
        ctx.beginPDFPage(nil)
        ctx.scaleBy(x: mm, y: mm)
        // The palette's page, edge to edge; the tiles carry the same colour.
        ctx.setFillColor(style.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: sheet.x, height: sheet.y))
        ctx.saveGState()
        ctx.interpolationQuality = .high
        for tile in tiles {
            let r = tile.rect
            ctx.draw(tile.image, in: CGRect(x: offset.x + r.minX * scale, y: offset.y + r.minY * scale,
                                            width: r.width * scale, height: r.height * scale))
        }
        ctx.restoreGState()

        // Title, subtitle and credits along the foot of the sheet.
        let ink = style.ink.cgColor, grey = style.secondaryInk.cgColor
        var y = margin + footer - 9 * unit
        PaperGlobe.text(ctx, title, size: 8 * unit, at: CGPoint(x: margin, y: y), bold: true, color: ink, centered: false)
        y -= 6 * unit
        PaperGlobe.text(ctx, subtitle, size: 3.6 * unit, at: CGPoint(x: margin, y: y), color: grey, centered: false)
        let body = state.data.body
        let sources = Array(Set(body.datasets.map(\.attribution))).sorted()
        let credits = "A myriahedral projection after Jarke J. van Wijk, “Unfolding the Earth: Myriahedral Projections”, "
            + "The Cartographic Journal 45(1), 2008. \(state.mesh.cellCount.formatted()) polygons"
            + (closing > 0 ? ", the gaps closed as in his figure 13" : "") + ". Made with JJ. Data: "
            + sources.joined(separator: "; ") + "."
        paragraph(ctx, credits, in: CGRect(x: margin, y: margin, width: min(sheet.x - 2 * margin, 260 * unit), height: footer - 19 * unit),
                  size: 2.1 * unit, color: grey)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// Wrapped text in a rectangle (millimetres).
    static func paragraph(_ ctx: CGContext, _ string: String, in rect: CGRect, size: Double, color: CGColor) {
        guard let font = CTFontCreateUIFontForLanguage(.system, size, nil) else { return }
        let attributes: [NSAttributedString.Key: Any] = [kCTFontAttributeName as NSAttributedString.Key: font,
                                                          kCTForegroundColorAttributeName as NSAttributedString.Key: color]
        let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
    }
}

extension RGBA {
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}
