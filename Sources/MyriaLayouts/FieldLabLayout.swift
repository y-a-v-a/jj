import Foundation
import MyriaCore
import MyriaData

/// Van Wijk's framework, open to experiment: any field the world offers,
/// weighing the edges the way the user chooses.
public struct FieldLabLayout: Layout {
    public init() {}

    static let modes = ["Keep high values whole", "Keep low values whole", "Tear along a contour"]

    public var descriptor: LayoutDescriptor { descriptor(for: .earth) }

    public func descriptor(for body: Body) -> LayoutDescriptor {
        let fields = body.availableFields
        return LayoutDescriptor(
            id: "field-lab", title: "Field Lab",
            summary: "Any field, weighed your way",
            story: "Van Wijk's framework in one place: a field on the sphere weighs every edge, the maximum spanning tree keeps the heaviest as folds, and the map tears along the rest. Choose the field and how it weighs. Keep high values whole and the map tears where the field is low; keep low values whole for the opposite; or tear along a contour, as |f − f_c| does for land, at a level given as a share of the field's values (0.5: half the world lies below it). The field is scaled to its own range, so a whisper of graticule keeps flat stretches tidy whatever its units.",
            symbol: "slider.horizontal.3", category: .lab,
            parameters: [
                .choice("field", "Field", fields.map(\.title), default: 0),
                .choice("mode", "Weigh", Self.modes, default: 0),
                .slider("level", "Contour level", 0.05...0.95, step: 0.01, default: 0.5,
                        help: "For a contour: the share of the world's values below it"),
                centerParameter,
            ],
            preferredMesh: .geodesic(frequency: 40))
    }

    /// The field chosen, among those the world has.
    static func field(_ p: LayoutParameters, of body: Body) -> FieldDescriptor? {
        let fields = body.availableFields
        guard !fields.isEmpty else { return nil }
        return fields[min(max(p.index("field"), 0), fields.count - 1)]
    }

    public func cut(_ context: LayoutContext, parameters p: LayoutParameters) throws -> LayoutCut {
        guard let d = Self.field(p, of: context.data.body) else { throw LayoutError.missingData("a field") }
        let key = d.defaultKey
        let field = try context.data.field(key)
        // Scaled to the field's own range (2nd to 98th percentile).
        let lo = field.quantile(0.02), hi = field.quantile(0.98)
        let span = max(hi - lo, 1e-12)
        let v = try context.edgeValues(key).map { $0.isFinite ? min(max(($0 - lo) / span, 0), 1) : 0 }
        let weights: [Double]
        switch p.index("mode") {
        case 1:
            weights = v.map { -$0 }
        case 2:
            let level = (field.quantile(p.value("level", default: 0.5)) - lo) / span
            weights = v.map { abs($0 - level) }
        default:
            weights = v
        }
        let center = p.value("center", default: 10)
        return LayoutCut(hinges: context.mesh.hinges(weights: Weights.add(weights, order(context, center: center))),
                         root: Weights.root(context, longitude: center),
                         notes: ["\(d.title), \(Self.modes[min(max(p.index("mode"), 0), 2)].lowercased())"])
    }

    public func appearance(_ parameters: LayoutParameters) -> LayoutAppearance {
        appearance(parameters, for: .earth)
    }

    public func appearance(_ parameters: LayoutParameters, for body: Body) -> LayoutAppearance {
        guard let d = Self.field(parameters, of: body) else { return LayoutAppearance(coloring: .relief) }
        return LayoutAppearance(coloring: .field(d.defaultKey), showGraticule: true)
    }
}
