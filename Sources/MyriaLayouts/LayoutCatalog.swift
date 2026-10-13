import Foundation
import MyriaData

/// Every layout JJ knows, in gallery order. Add a new layout by conforming
/// to `Layout` and appending it here.
public enum LayoutCatalog {
    public static let all: [any Layout] = [
        // The planet
        CoastlineLayout(),
        MidOceanLayout(),
        TectonicLayout(),
        RiverLayout(),
        // People
        TimeZoneLayout(),
        CountriesLayout(),
        PopulationLayout(),
        FlightsLayout(),
        // Sky and climate
        DayNightLayout(),
        WindLayout(),
        RainfallLayout(),
        // Other worlds, and this one
        WaterlineLayout(),
        CraterLayout(),
        // Van Wijk, 2008
        GraticularLayout(.cylindrical),
        GraticularLayout(.conical),
        GraticularLayout(.azimuthal),
        GraticularLayout(.twoHemispheres),
        GraticularLayout(.polyconic),
        PlatonicLayout(),
        SubdivisionLayout(),
        GeoAlignedLayout(.continents),
        GeoAlignedLayout(.northUp),
        GeoAlignedLayout(.separated),
        GeoAlignedLayout(.coastline),
        PointOfViewLayout(),
        // Laboratory
        FieldLabLayout(),
    ]

    public static func layout(id: String) -> (any Layout)? {
        all.first { $0.descriptor.id == id }
    }

    /// Layouts whose data a body has.
    public static func available(for body: Body) -> [any Layout] {
        all.filter { $0.descriptor.isAvailable(for: body) }
    }
}
