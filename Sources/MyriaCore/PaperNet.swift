import Foundation

/// A paper model of a myriahedral globe: the unfolded net split into pieces
/// that fit on sheets of paper, glue tabs on the seams, and the pieces packed
/// onto sheets. Print it, cut it out, crease the folds and glue each tab
/// under the edge with the same number, and the map closes into the
/// polyhedron it was unfolded from.
public struct PaperNet: Sendable {
    public struct Options: Sendable, Hashable {
        /// Sheet size in millimetres (width, height).
        public var sheet: Vec2
        /// Margin around the printable area, millimetres.
        public var margin: Double
        /// Diameter of the folded globe (its circumscribed sphere), mm.
        public var diameter: Double
        /// Height kept free at the top of the first sheet for a title, mm.
        public var header: Double
        /// Height of the largest glue tab, mm.
        public var tabHeight: Double
        /// Space between pieces, mm.
        public var gap: Double

        public init(sheet: Vec2 = Paper.a4.size, margin: Double = 10, diameter: Double = 120, header: Double = 26,
                    tabHeight: Double = 5, gap: Double = 3) {
            self.sheet = sheet
            self.margin = margin
            self.diameter = diameter
            self.header = header
            self.tabHeight = tabHeight
            self.gap = gap
        }

        /// Millimetres per map unit: map units are radii of the globe.
        public var scale: Double { diameter / 2 }
        /// The printable area of a sheet.
        public var content: Vec2 { Vec2(sheet.x - 2 * margin, sheet.y - 2 * margin) }
    }

    /// Common paper sizes.
    public enum Paper: String, CaseIterable, Sendable {
        case a4, a3, letter, tabloid

        public var size: Vec2 {
            switch self {
            case .a4: Vec2(210, 297)
            case .a3: Vec2(297, 420)
            case .letter: Vec2(215.9, 279.4)
            case .tabloid: Vec2(279.4, 431.8)
            }
        }

        public var title: String {
            switch self {
            case .a4: "A4"
            case .a3: "A3"
            case .letter: "US Letter"
            case .tabloid: "US Tabloid"
            }
        }
    }

    /// Where a piece goes: map units → millimetres on its sheet, origin at
    /// the sheet's bottom-left corner, y up.
    public struct Placement: Sendable, Hashable {
        public var sheet: Int
        public var rotation: Double
        public var scale: Double
        public var offset: Vec2

        public func apply(_ p: Vec2) -> Vec2 {
            let c = cos(rotation), s = sin(rotation)
            return Vec2((c * p.x - s * p.y) * scale + offset.x, (s * p.x + c * p.y) * scale + offset.y)
        }
    }

    public struct Piece: Sendable {
        public let faces: [Int]
        public var placement: Placement
    }

    /// An edge where the paper is cut and later glued.
    public struct Seam: Sendable {
        public let edge: Int
        /// Printed on both sides of the seam; 1-based.
        public var number: Int
        /// The face carrying the glue tab, if one fits.
        public let tabFace: Int?
        /// The tab in map units, counter-clockwise from its base (the edge,
        /// `tab[0]`–`tab[1]`); empty without a tab.
        public let tab: [Vec2]
        /// Cut to fit the paper, not by the layout.
        public let isPaperCut: Bool
        /// A slit: both sides lie in one piece, just across a narrow gap
        /// (often meeting at one end), so the seam closes edge to edge as
        /// the paper is folded and needs no number.
        public let isSlit: Bool

        /// Whether the seam is numbered: tabs and loose edges are.
        public var isNumbered: Bool { tabFace != nil || !isSlit }
    }

    public enum Failure: Error, CustomStringConvertible {
        case tooLarge(maximumDiameter: Double)

        public var description: String {
            switch self {
            case .tooLarge(let d): "A face does not fit on the sheet; choose a globe of at most \(Int(d / 10)) cm"
            }
        }
    }

    public let options: Options
    public let pieces: [Piece]
    /// The piece of every face.
    public let pieceOf: [Int]
    public let seams: [Seam]
    /// The seam of every edge, or -1 for folds.
    public let seamOf: [Int]
    /// Edges creased inside pieces (every edge that is not a seam).
    public let folds: [Int]
    public let sheetCount: Int
    /// The shortest seam on paper, in millimetres: below about 5 mm folding
    /// and numbering get fiddly.
    public let shortestSeam: Double
    /// Face polygons in map units, as unfolded.
    public let polygons: [[Vec2]]

    public init(projection: MyriahedralProjection, options: Options) throws {
        self.options = options
        let mesh = projection.mesh, topology = mesh.topology
        let polygons = projection.mapPolygons
        self.polygons = polygons
        let faceCount = mesh.faceCount
        let s = options.scale
        // Room around faces for tabs, the gap and the nesting raster.
        let tabRoom = options.tabHeight + options.gap / 2 + 1
        let fitBox = Vec2(options.content.x - 2 * tabRoom, options.content.y - 2 * tabRoom)

        // Every face must fit on its own.
        let largest = polygons.indices.max { Self.diameter(of: polygons[$0]) < Self.diameter(of: polygons[$1]) }.map { polygons[$0] } ?? []
        if !largest.isEmpty, Self.bestRotation(Self.hull(largest.map { $0 * s }), fitting: fitBox) == nil {
            let unit = Self.diameter(of: largest)
            throw Failure.tooLarge(maximumDiameter: 2 * min(fitBox.x, fitBox.y) / max(unit, 1e-9))
        }

        // Split the net into pieces that fit and do not overlap.
        var isHinge = projection.unfolding.isCut.map { !$0 }
        var paperCut = Array(repeating: false, count: topology.edges.count)
        var parts: [[Int]] = []
        var stack = [Array(0..<faceCount)]
        while let faces = stack.popLast() {
            let fits = Self.bestRotation(Self.hull(faces.flatMap { polygons[$0] }.map { $0 * s }), fitting: fitBox) != nil
            // Overlaps of a twentieth of a millimetre on paper do not count.
            let overlap = Self.firstOverlap(faces, polygons, tolerance: 0.05 / s)
            if fits && overlap == nil {
                parts.append(faces)
                continue
            }
            // Without an overlap to undo, cut off about as much as fits on a sheet.
            let sheetful = 0.4 * fitBox.x * fitBox.y / (s * s)
            guard let (edge, a, b) = Self.split(faces, overlap: overlap, target: sheetful, mesh: mesh, isHinge: isHinge,
                                                polygons: polygons) else {
                parts.append(faces)
                continue
            }
            isHinge[edge] = false
            paperCut[edge] = true
            stack.append(b)
            stack.append(a)
        }
        // Largest pieces first.
        let area = polygons.map { abs(Planar.signedArea($0)) }
        parts.sort { $0.reduce(0) { $0 + area[$1] } > $1.reduce(0) { $0 + area[$1] } }
        var pieceOf = Array(repeating: 0, count: faceCount)
        for (p, faces) in parts.enumerated() { for f in faces { pieceOf[f] = p } }
        self.pieceOf = pieceOf

        // Glue tabs on one side of every seam. A seam's options are the tabs
        // that clear the faces of their piece: full tabs first, then lower
        // ones, then ones on the middle of the edge, clear of crowded
        // corners. Seams with the fewest options choose first, each tab
        // clearing the tabs chosen before it.
        let grid = FaceGrid(polygons: polygons)
        let tolerance = 0.02 / s
        var folds: [Int] = [], seamEdges: [Int] = []
        for e in topology.edges.indices {
            if isHinge[e] { folds.append(e) } else { seamEdges.append(e) }
        }
        let shapes: [(height: Double, span: Double)] = [(1, 1), (0.5, 1), (0.5, 0.6), (0.3, 0.5)]
        let choices: [[(face: Int, tab: [Vec2])]] = seamEdges.map { e in
            let edge = topology.edges[e]
            var found: [(face: Int, tab: [Vec2])] = []
            for shape in shapes {
                for f in e % 2 == 0 ? [edge.leftFace, edge.rightFace] : [edge.rightFace, edge.leftFace] {
                    var (a, b) = Self.segment(of: edge, in: f, mesh: mesh, polygons: polygons)
                    if shape.span < 1 {
                        (a, b) = (Vec2.lerp(a, b, (1 - shape.span) / 2), Vec2.lerp(a, b, (1 + shape.span) / 2))
                    }
                    let tab = Self.tab(a, b, away: Planar.centroid(polygons[f]), height: options.tabHeight * shape.height / s)
                    let blocked = grid.candidates(Rect2(bounding: tab)).contains { g in
                        pieceOf[g] == pieceOf[f] && Self.overlaps(tab, polygons[g], tolerance: tolerance)
                    }
                    if !blocked { found.append((f, tab)) }
                }
            }
            return found
        }
        var chosen = [Int: (face: Int, tab: [Vec2])]()
        // Placed tabs by grid cell (the face grid's cells), for quick conflicts.
        var tabCells = [Int: Set<Int>]()
        func cells(_ tab: [Vec2]) -> [Int] { grid.cellIndices(Rect2(bounding: tab)) }
        func blockers(_ tab: [Vec2], in piece: Int, except: Int = -1) -> [Int] {
            var near = Set<Int>()
            for c in cells(tab) { near.formUnion(tabCells[c] ?? []) }
            return near.filter { j in
                j != except && pieceOf[chosen[j]!.face] == piece && Self.overlaps(tab, chosen[j]!.tab, tolerance: tolerance)
            }
        }
        func place(_ i: Int, _ option: (face: Int, tab: [Vec2])) {
            if let old = chosen[i] { for c in cells(old.tab) { tabCells[c]?.remove(i) } }
            chosen[i] = option
            for c in cells(option.tab) { tabCells[c, default: []].insert(i) }
        }
        for i in seamEdges.indices.sorted(by: { (choices[$0].count, $0) < (choices[$1].count, $1) }) {
            if let option = choices[i].first(where: { blockers($0.tab, in: pieceOf[$0.face]).isEmpty }) { place(i, option) }
        }
        // A seam left without a tab may take the place of one tab that can
        // move elsewhere.
        repair: for i in seamEdges.indices where chosen[i] == nil {
            for option in choices[i] {
                let blocking = blockers(option.tab, in: pieceOf[option.face])
                guard blocking.count == 1, let j = blocking.first else { continue }
                for alternative in choices[j] where alternative.tab != chosen[j]!.tab {
                    let piece = pieceOf[alternative.face]
                    let clear = blockers(alternative.tab, in: piece, except: j).isEmpty
                        && !(piece == pieceOf[option.face] && Self.overlaps(alternative.tab, option.tab, tolerance: tolerance))
                    if clear {
                        place(j, alternative)
                        place(i, option)
                        continue repair
                    }
                }
            }
        }
        var seams: [Seam] = []
        var seamOf = Array(repeating: -1, count: topology.edges.count)
        for (i, e) in seamEdges.enumerated() {
            let edge = topology.edges[e]
            let (la, lb) = Self.segment(of: edge, in: edge.leftFace, mesh: mesh, polygons: polygons)
            let (ra, rb) = Self.segment(of: edge, in: edge.rightFace, mesh: mesh, polygons: polygons)
            // A slit: the other side lies just across a narrow gap.
            let isSlit = pieceOf[edge.leftFace] == pieceOf[edge.rightFace]
                && max((la - ra).length, (lb - rb).length) < 2 * options.tabHeight / s
            seamOf[e] = seams.count
            seams.append(Seam(edge: e, number: 0, tabFace: chosen[i]?.face, tab: chosen[i]?.tab ?? [], isPaperCut: paperCut[e],
                              isSlit: isSlit))
        }
        self.folds = folds
        var tabsOf = Array(repeating: [[Vec2]](), count: parts.count)
        for option in chosen.values { tabsOf[pieceOf[option.face]].append(option.tab) }
        shortestSeam = seams.map { seam -> Double in
            let edge = topology.edges[seam.edge]
            let (a, b) = Self.segment(of: edge, in: edge.leftFace, mesh: mesh, polygons: polygons)
            return (b - a).length * s
        }.min() ?? 0

        // Nest the pieces onto sheets by their shapes, each turned to its
        // most compact orientation or a quarter turn from it.
        var outlines: [[[Vec2]]] = []
        var rotations: [Double] = []
        for (p, faces) in parts.enumerated() {
            let shapes = (faces.map { polygons[$0] } + tabsOf[p]).map { $0.map { $0 * s } }
            outlines.append(shapes)
            rotations.append(Self.bestRotation(Self.hull(shapes.flatMap { $0 }), fitting: options.content) ?? 0)
        }
        let (placements, sheetCount) = Self.nest(outlines, rotations: rotations, options: options)
        self.sheetCount = sheetCount
        self.pieces = parts.indices.map { Piece(faces: parts[$0], placement: placements[$0]) }

        // Number the seams in reading order: sheet by sheet, top to bottom.
        let positions = seams.map {
            Self.sheetPosition($0, topology: topology, pieceOf: pieceOf, placements: placements, polygons: polygons, mesh: mesh)
        }
        let order = seams.indices.filter { seams[$0].isNumbered }.sorted { i, j in
            let (pi, qi) = positions[i], (pj, qj) = positions[j]
            if pi != pj { return pi < pj }
            if abs(qi.y - qj.y) > 1e-6 { return qi.y > qj.y }
            return qi.x < qj.x
        }
        for (n, i) in order.enumerated() { seams[i].number = n + 1 }
        self.seams = seams
        self.seamOf = seamOf
    }

    // MARK: Queries

    /// The map segment of an edge as it lies in one of its faces.
    public func segment(of edge: Int, in face: Int, mesh: MyriahedralMesh) -> (Vec2, Vec2) {
        Self.segment(of: mesh.topology.edges[edge], in: face, mesh: mesh, polygons: polygons)
    }

    /// Faces in pieces on a sheet.
    public func pieces(onSheet sheet: Int) -> [Int] {
        pieces.indices.filter { pieces[$0].placement.sheet == sheet }
    }

    /// Slits: seams that close edge to edge (a corner's fan of faces is
    /// held in place by its neighbours once they are glued).
    public var slits: Int { seams.filter { $0.tabFace == nil && $0.isSlit }.count }

    /// Seams with neither a tab nor a shared corner: these need tape.
    public var looseSeams: Int { seams.filter { !$0.isNumbered || $0.tabFace == nil }.count - slits }

    // MARK: Geometry

    static func segment(of edge: MeshEdge, in f: Int, mesh: MyriahedralMesh, polygons: [[Vec2]]) -> (Vec2, Vec2) {
        let face = mesh.polyhedron.faces[f]
        let ia = face.firstIndex(of: edge.a)!, ib = face.firstIndex(of: edge.b)!
        return (polygons[f][ia], polygons[f][ib])
    }

    /// A trapezoidal tab on segment a–b, on the side away from `inside`, its
    /// sides sloping in at 55°; at most a third of the edge high.
    static func tab(_ a: Vec2, _ b: Vec2, away inside: Vec2, height: Double) -> [Vec2] {
        let d = b - a, length = d.length
        guard length > 0 else { return [] }
        let u = d / length
        var n = Vec2(u.y, -u.x)
        if n.dot((a + b) / 2 - inside) < 0 { n = -n }
        let h = min(height, length / 3)
        let inset = min(h / tan(55 * Double.pi / 180), length * 0.4)
        // The base first, then the outer corners, counter-clockwise.
        let tab = [a, b, b + n * h - u * inset, a + n * h + u * inset]
        return Planar.signedArea(tab) >= 0 ? tab : [b, a, a + n * h + u * inset, b + n * h - u * inset]
    }

    static func rotate(_ p: Vec2, _ angle: Double) -> Vec2 {
        let c = cos(angle), s = sin(angle)
        return Vec2(c * p.x - s * p.y, s * p.x + c * p.y)
    }

    static func diameter(of poly: [Vec2]) -> Double {
        var d = 0.0
        for p in poly { for q in poly { d = max(d, (p - q).length) } }
        return d
    }

    /// Andrew's monotone chain; counter-clockwise.
    static func hull(_ points: [Vec2]) -> [Vec2] {
        let sorted = points.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
        guard sorted.count > 2 else { return sorted }
        var lower: [Vec2] = [], upper: [Vec2] = []
        for p in sorted {
            while lower.count >= 2, (lower[lower.count - 1] - lower[lower.count - 2]).cross(p - lower[lower.count - 2]) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2, (upper[upper.count - 1] - upper[upper.count - 2]).cross(p - upper[upper.count - 2]) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// The rotation (whole degrees) whose bounding box fits `box` with the
    /// least area, preferring landscape boxes, which pack into shelves.
    static func bestRotation(_ hull: [Vec2], fitting box: Vec2) -> Double? {
        var best: (angle: Double, area: Double)?
        for degree in 0..<180 {
            let angle = Double(degree) * .pi / 180
            let r = Rect2(bounding: hull.map { rotate($0, angle) })
            guard r.width <= box.x, r.height <= box.y else { continue }
            let area = r.width * r.height * (r.width >= r.height ? 1 : 1.02)
            if area < best?.area ?? .infinity { best = (angle, area) }
        }
        return best?.angle
    }

    /// Separating axes: whether two convex polygons overlap by more than
    /// `tolerance` (touching does not count).
    static func overlaps(_ p: [Vec2], _ q: [Vec2], tolerance: Double) -> Bool {
        guard p.count >= 3, q.count >= 3 else { return false }
        for poly in [p, q] {
            var prev = poly[poly.count - 1]
            for c in poly {
                let edge = c - prev
                prev = c
                let length = edge.length
                guard length > 0 else { continue }
                let n = Vec2(-edge.y, edge.x) / length
                var minP = Double.infinity, maxP = -Double.infinity, minQ = Double.infinity, maxQ = -Double.infinity
                for v in p { let t = n.dot(v); minP = min(minP, t); maxP = max(maxP, t) }
                for v in q { let t = n.dot(v); minQ = min(minQ, t); maxQ = max(maxQ, t) }
                if maxP - minQ <= tolerance || maxQ - minP <= tolerance { return false }
            }
        }
        return true
    }

    /// Some pair of faces lying on top of each other, if any.
    static func firstOverlap(_ faces: [Int], _ polygons: [[Vec2]], tolerance: Double) -> (Int, Int)? {
        let boxes = faces.map { Rect2(bounding: polygons[$0]) }
        let order = faces.indices.sorted { boxes[$0].minX < boxes[$1].minX }
        for (k, i) in order.enumerated() {
            for j in order[(k + 1)...] {
                if boxes[j].minX >= boxes[i].maxX { break }
                guard boxes[j].minY < boxes[i].maxY, boxes[i].minY < boxes[j].maxY else { continue }
                if overlaps(polygons[faces[i]], polygons[faces[j]], tolerance: tolerance) { return (faces[i], faces[j]) }
            }
        }
        return nil
    }

    /// Splits a piece in two at a hinge: on the path between two overlapping
    /// faces if there are any, else where one part comes closest to `target`
    /// area (about a sheetful) without exceeding half. Cells (hexagons) are
    /// never split.
    static func split(_ faces: [Int], overlap: (Int, Int)?, target: Double, mesh: MyriahedralMesh, isHinge: [Bool],
                      polygons: [[Vec2]]) -> (edge: Int, [Int], [Int])? {
        let topology = mesh.topology
        let inPiece = Set(faces)
        var parent = [Int: (face: Int, edge: Int)]()
        var order = [faces[0]]
        var seen: Set = [faces[0]]
        var head = 0
        while head < order.count {
            let f = order[head]
            head += 1
            for e in topology.faceEdges[f] where isHinge[e] {
                let g = topology.edges[e].otherFace(f)
                guard inPiece.contains(g), !seen.contains(g) else { continue }
                seen.insert(g)
                parent[g] = (f, e)
                order.append(g)
            }
        }
        let area = Dictionary(uniqueKeysWithValues: faces.map { ($0, abs(Planar.signedArea(polygons[$0]))) })
        var subtree = area
        for f in order.reversed() { if let p = parent[f] { subtree[p.face]! += subtree[f]! } }
        let total = subtree[faces[0]]!

        var candidates: [Int]
        if let (f, g) = overlap {
            // Faces on the path between f and g, child side of each edge.
            var up: [Int] = [], seenUp = Set<Int>()
            var x = f
            while let p = parent[x] { up.append(x); seenUp.insert(x); x = p.face }
            seenUp.insert(x)
            var down: [Int] = []
            var y = g
            while !seenUp.contains(y), let p = parent[y] { down.append(y); y = p.face }
            let meet = y
            candidates = up.prefix { $0 != meet } + down
        } else {
            candidates = Array(order.dropFirst())
        }
        candidates = candidates.filter { !mesh.isInternalEdge[parent[$0]!.edge] }
        // The smaller side of each candidate cut, aimed at a sheetful.
        let aim = overlap == nil ? min(target, total / 2) : total / 2
        func part(_ f: Int) -> Double { min(subtree[f]!, total - subtree[f]!) }
        guard let child = candidates.min(by: { abs(aim - part($0)) < abs(aim - part($1)) }) else { return nil }
        let cut = parent[child]!.edge
        // The child's subtree.
        var part: [Int] = [child]
        var stack = [child]
        var below: Set = [child]
        while let f = stack.popLast() {
            for e in topology.faceEdges[f] where isHinge[e] && e != cut {
                let g = topology.edges[e].otherFace(f)
                guard inPiece.contains(g), !below.contains(g), parent[g]?.face == f else { continue }
                below.insert(g)
                part.append(g)
                stack.append(g)
            }
        }
        let rest = faces.filter { !below.contains($0) }
        return (cut, rest, part)
    }

    /// Nests pieces (convex polygons in millimetres) onto sheets: each
    /// piece, largest first, rasterised at 1 mm with half the gap around it,
    /// goes to the highest, then leftmost, free spot of the earliest sheet
    /// with room, in whichever of four quarter-turn orientations fits best.
    static func nest(_ pieces: [[[Vec2]]], rotations: [Double], options: Options) -> (placements: [Placement], sheets: Int) {
        let cell = 1.0
        let cols = Int((options.content.x / cell).rounded(.down)), rows = Int((options.content.y / cell).rounded(.down))
        let headerRows = Int((options.header / cell).rounded(.up))
        let pad = options.gap / 2 + cell * 0.71

        /// A piece in one orientation: runs of covered cells (row, first, last).
        struct Raster {
            var rotation: Double, left: Double, top: Double, width: Int, height: Int
            var runs: [(row: Int32, first: Int32, last: Int32)]
            var area: Int { runs.reduce(0) { $0 + Int($1.last - $1.first) + 1 } }
        }
        /// The cells a piece covers, turned by `rotation`, with half the gap
        /// around it: (left, top) of the grid, its size, and the cells.
        func coverage(_ shapes: [[Vec2]], _ rotation: Double) -> (left: Double, top: Double, width: Int, height: Int, covered: [Bool]) {
            let turned = shapes.map { $0.map { rotate($0, rotation) } }
            var b = Rect2.empty
            for shape in turned { for p in shape { b.include(p) } }
            let left = b.minX - pad, top = b.maxY + pad
            let width = Int(((b.width + 2 * pad) / cell).rounded(.up)), height = Int(((b.height + 2 * pad) / cell).rounded(.up))
            var covered = [Bool](repeating: false, count: width * height)
            for shape in turned {
                let sb = Rect2(bounding: shape)
                let i0 = max(0, Int(((sb.minX - pad - left) / cell).rounded(.down))), i1 = min(width - 1, Int(((sb.maxX + pad - left) / cell).rounded(.down)))
                let j0 = max(0, Int(((top - sb.maxY - pad) / cell).rounded(.down))), j1 = min(height - 1, Int(((top - sb.minY + pad) / cell).rounded(.down)))
                guard i0 <= i1, j0 <= j1 else { continue }
                for j in j0...j1 {
                    for i in i0...i1 where !covered[j * width + i] {
                        let centre = Vec2(left + (Double(i) + 0.5) * cell, top - (Double(j) + 0.5) * cell)
                        if Planar.distanceOutside(shape, centre) <= pad { covered[j * width + i] = true }
                    }
                }
            }
            return (left, top, width, height, covered)
        }
        /// The raster of a piece turned by `rotation` and then `quarters`
        /// quarter turns, the turns done on the grid itself.
        func raster(_ c: (left: Double, top: Double, width: Int, height: Int, covered: [Bool]), _ rotation: Double,
                    quarters: Int) -> Raster? {
            var (left, top, width, height, covered) = c
            for _ in 0..<quarters {
                // (x, y) → (−y, x): column i becomes row W−1−i, row j column j.
                var turned = [Bool](repeating: false, count: width * height)
                for j in 0..<height { for i in 0..<width where covered[j * width + i] { turned[(width - 1 - i) * height + j] = true } }
                (left, top) = (-top, left + Double(width) * cell)
                (width, height) = (height, width)
                covered = turned
            }
            guard width <= cols, height <= rows else { return nil }
            var runs: [(row: Int32, first: Int32, last: Int32)] = []
            for j in 0..<height {
                var i = 0
                while i < width {
                    if covered[j * width + i] {
                        let first = i
                        while i < width, covered[j * width + i] { i += 1 }
                        runs.append((Int32(j), Int32(first), Int32(i - 1)))
                    } else {
                        i += 1
                    }
                }
            }
            return Raster(rotation: rotation + Double(quarters) * .pi / 2, left: left, top: top, width: width, height: height, runs: runs)
        }

        /// Occupied cells of a sheet, as per-row prefix counts (row-major,
        /// `cols + 1` a row) for constant-time range queries.
        struct Sheet {
            let stride: Int
            var prefix: [Int32]
            /// Cells still free: sheets with less room than a piece are skipped.
            var free: Int
            init(rows: Int, cols: Int, blockedRows: Int) {
                stride = cols + 1
                prefix = [Int32](repeating: 0, count: rows * stride)
                for r in 0..<min(blockedRows, rows) { for c in 0...cols { prefix[r * stride + c] = Int32(c) } }
                free = (rows - min(blockedRows, rows)) * cols
            }
            /// Nil if the piece fits with its corner at (x, y); else the next
            /// x worth trying on this row, past the cells in the way.
            func conflict(_ r: Raster, x: Int, y: Int) -> Int? {
                prefix.withUnsafeBufferPointer { prefix in
                    r.runs.withUnsafeBufferPointer { runs in
                        for run in runs {
                            let base = (y + Int(run.row)) * stride + x
                            let a = base + Int(run.first), b = base + Int(run.last)
                            let total = prefix[b + 1]
                            guard total != prefix[a] else { continue }
                            // The last occupied cell in a…b: where the count stops rising.
                            var lo = a, hi = b
                            while lo < hi {
                                let mid = (lo + hi) / 2
                                if prefix[mid + 1] == total { hi = mid } else { lo = mid + 1 }
                            }
                            return x + (lo - a) + 1
                        }
                        return nil
                    }
                }
            }
            func isFree(_ r: Raster, x: Int, y: Int) -> Bool { conflict(r, x: x, y: y) == nil }
            mutating func occupy(_ r: Raster, x: Int, y: Int) {
                var k = 0
                while k < r.runs.count {
                    // One row at a time: mark its cells, then recount the row.
                    let row = y + Int(r.runs[k].row), base = row * stride
                    var occupied = (0..<(stride - 1)).map { prefix[base + $0 + 1] > prefix[base + $0] }
                    while k < r.runs.count, y + Int(r.runs[k].row) == row {
                        for i in (x + Int(r.runs[k].first))...(x + Int(r.runs[k].last)) { occupied[i] = true }
                        k += 1
                    }
                    let before = Int(prefix[base + stride - 1])
                    for i in 0..<(stride - 1) { prefix[base + i + 1] = prefix[base + i] + (occupied[i] ? 1 : 0) }
                    free -= Int(prefix[base + stride - 1]) - before
                }
            }
        }

        var sheets: [Sheet] = []
        var placements = [Placement](repeating: Placement(sheet: 0, rotation: 0, scale: options.scale, offset: .zero), count: pieces.count)
        let area = pieces.map { $0.reduce(0) { $0 + abs(Planar.signedArea($1)) } }
        for p in pieces.indices.sorted(by: { area[$0] > area[$1] }) {
            let base = coverage(pieces[p], rotations[p])
            var orientations = (0..<4).compactMap { raster(base, rotations[p], quarters: $0) }
            if orientations.isEmpty,
               let snug = bestRotation(hull(pieces[p].flatMap { $0 }), fitting: Vec2(Double(cols) * cell - 2 * pad - 1, Double(rows) * cell - 2 * pad - 1)),
               let r = raster(coverage(pieces[p], snug), snug, quarters: 0) {
                orientations = [r]
            }
            guard !orientations.isEmpty else { continue }
            var best: (sheet: Int, y: Int, x: Int, raster: Raster)?
            search: for (k, sheet) in sheets.enumerated() where sheet.free >= orientations[0].area {
                for r in orientations {
                    // Highest, then leftmost spot for this orientation.
                    rows: for y in 0...(rows - r.height) {
                        if let b = best, b.sheet == k, y > b.y { break rows }
                        var x = 0
                        while x <= cols - r.width {
                            if let next = sheet.conflict(r, x: x, y: y) {
                                x = next
                                continue
                            }
                            if best == nil || best!.sheet > k || (best!.sheet == k && (y, x) < (best!.y, best!.x)) {
                                best = (k, y, x, r)
                            }
                            break rows
                        }
                    }
                }
                if best != nil { break search }
            }
            if best == nil {
                // A fresh sheet; the first one keeps room for the title.
                sheets.append(Sheet(rows: rows, cols: cols, blockedRows: sheets.isEmpty ? headerRows : 0))
                let k = sheets.count - 1
                for r in orientations {
                    for y in 0...(rows - r.height) {
                        if let b = best, y >= b.y { break }
                        if let x = (0...(cols - r.width)).first(where: { sheets[k].isFree(r, x: $0, y: y) }) {
                            best = (k, y, x, r)
                            break
                        }
                    }
                }
                if best == nil, k == 0 {
                    // Too tall for the first sheet below its title: start the next.
                    sheets.append(Sheet(rows: rows, cols: cols, blockedRows: 0))
                    if let r = orientations.first { best = (1, 0, 0, r) }
                }
            }
            guard let b = best else { continue }
            sheets[b.sheet].occupy(b.raster, x: b.x, y: b.y)
            let offset = Vec2(options.margin + Double(b.x) * cell - b.raster.left,
                              options.sheet.y - options.margin - Double(b.y) * cell - b.raster.top)
            placements[p] = Placement(sheet: b.sheet, rotation: b.raster.rotation, scale: options.scale, offset: offset)
        }
        return (placements, max(1, sheets.count))
    }

    static func sheetPosition(_ seam: Seam, topology: MeshTopology, pieceOf: [Int], placements: [Placement],
                              polygons: [[Vec2]], mesh: MyriahedralMesh) -> (Int, Vec2) {
        let edge = topology.edges[seam.edge]
        let f = seam.tabFace ?? edge.leftFace
        let (a, b) = segment(of: edge, in: f, mesh: mesh, polygons: polygons)
        let placement = placements[pieceOf[f]]
        return (placement.sheet, placement.apply((a + b) / 2))
    }
}

/// Faces by map position, for quick overlap queries.
struct FaceGrid {
    let bounds: Rect2
    let cell: Double
    let cols: Int, rows: Int
    let cells: [[Int]]

    init(polygons: [[Vec2]]) {
        var b = Rect2.empty
        for p in polygons { b.include(Rect2(bounding: p)) }
        let n = max(polygons.count, 1)
        cell = max(b.width, b.height, 1e-9) / max(1, Double(n).squareRoot())
        cols = max(1, Int((b.width / cell).rounded(.up)) + 1)
        rows = max(1, Int((b.height / cell).rounded(.up)) + 1)
        bounds = b
        var cells = Array(repeating: [Int](), count: cols * rows)
        for (f, poly) in polygons.enumerated() {
            let r = Rect2(bounding: poly)
            let (c0, r0) = (Int((r.minX - b.minX) / cell), Int((r.minY - b.minY) / cell))
            let (c1, r1) = (Int((r.maxX - b.minX) / cell), Int((r.maxY - b.minY) / cell))
            for row in max(0, r0)...min(rows - 1, r1) {
                for col in max(0, c0)...min(cols - 1, c1) { cells[row * cols + col].append(f) }
            }
        }
        self.cells = cells
    }

    /// The grid cells a rectangle touches (clamped to the grid).
    func cellIndices(_ r: Rect2) -> [Int] {
        let c0 = min(cols - 1, max(0, Int(((r.minX - bounds.minX) / cell).rounded(.down))))
        let r0 = min(rows - 1, max(0, Int(((r.minY - bounds.minY) / cell).rounded(.down))))
        let c1 = min(cols - 1, max(0, Int(((r.maxX - bounds.minX) / cell).rounded(.down))))
        let r1 = min(rows - 1, max(0, Int(((r.maxY - bounds.minY) / cell).rounded(.down))))
        var out: [Int] = []
        for row in r0...r1 { for col in c0...c1 { out.append(row * cols + col) } }
        return out
    }

    func candidates(_ r: Rect2) -> [Int] {
        var out = Set<Int>()
        for c in cellIndices(r) { out.formUnion(cells[c]) }
        return Array(out)
    }
}
