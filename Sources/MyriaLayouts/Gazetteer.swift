import Foundation
import MyriaCore
import MyriaData

/// Every name JJ can find on a world: countries, oceans and cities on Earth,
/// named craters, maria and mountains on the Moon and Mars.
public struct Gazetteer: Sendable {
    public struct Entry: Sendable, Hashable, Identifiable {
        public enum Kind: String, Sendable { case country, ocean, city, feature }

        public let kind: Kind
        public let name: String
        /// What it is, or where: "Country", "Netherlands", "Crater, 93 km".
        public let detail: String
        public let location: GeoPoint

        public var id: String { "\(kind.rawValue):\(name):\(detail):\(location.latitude),\(location.longitude)" }

        public init(kind: Kind, name: String, detail: String, location: GeoPoint) {
            self.kind = kind
            self.name = name
            self.detail = detail
            self.location = location
        }
    }

    /// In order of preference: countries, oceans, cities by population,
    /// features by size.
    public let entries: [Entry]
    /// Names folded for matching.
    let keys: [String]

    public init(entries: [Entry]) {
        // Places of one name in one country (three Albanys in the United
        // States) are told apart by where they are.
        // The same place listed twice is listed once.
        var listed = Set<String>()
        let entries = entries.filter { listed.insert($0.id).inserted }
        var seen = [String: Int]()
        for e in entries { seen[e.name + "\u{1}" + e.detail, default: 0] += 1 }
        self.entries = entries.map { e in
            guard seen[e.name + "\u{1}" + e.detail]! > 1 else { return e }
            return Entry(kind: e.kind, name: e.name, detail: "\(e.detail), \(e.location.description)", location: e.location)
        }
        keys = self.entries.map { Self.fold($0.name) }
    }

    /// The gazetteer of a world, from whichever of its datasets name places.
    public init(data: BodyData) {
        let body = data.body
        var entries: [Entry] = []
        if body.has(.countries), let countries = try? data.regions(.countries) {
            for c in countries.regions {
                if let label = c.labelPoint { entries.append(Entry(kind: .country, name: c.name, detail: "Country", location: label)) }
            }
        }
        if body.has(.land) {
            for basin in OceanBasin.allCases {
                entries.append(Entry(kind: .ocean, name: basin.title, detail: "Ocean", location: basin.labelPoint))
            }
        }
        if body.has(.places), let places = try? data.places() {
            for p in places.places { entries.append(Entry(kind: .city, name: p.name, detail: p.country, location: p.location)) }
        }
        if body.has(.features), let features = try? data.features() {
            for f in features.features {
                let size = f.diameter >= 1 ? "\(Int(f.diameter.rounded()).formatted()) km" : "small"
                entries.append(Entry(kind: .feature, name: f.name, detail: f.type.isEmpty ? size : "\(f.type), \(size)",
                                     location: f.location))
            }
        }
        self.init(entries: entries)
    }

    /// The gazetteer of a world, built once.
    public static func of(_ data: BodyData) -> Gazetteer {
        (try? data.cached("gazetteer") { Gazetteer(data: data) }) ?? Gazetteer(entries: [])
    }

    /// Lower case, without diacritics: "São Paulo" → "sao paulo".
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Entries whose name, or a word in it, starts with `query`: whole names
    /// first, then names that start with it, then names with a word that
    /// does; each in the gazetteer's order.
    public func search(_ query: String, limit: Int = 12) -> [Entry] {
        let q = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard q.count >= 2 else { return [] }
        var exact: [Int] = [], prefix: [Int] = [], word: [Int] = []
        for (i, key) in keys.enumerated() {
            if key == q {
                exact.append(i)
            } else if key.hasPrefix(q) {
                prefix.append(i)
            } else if word.count < limit, key.contains(" " + q) || key.contains("-" + q) {
                word.append(i)
            }
        }
        return (exact + prefix + word).prefix(limit).map { entries[$0] }
    }
}

extension OceanBasin {
    /// A point well inside the ocean, for its label and for search.
    public var labelPoint: GeoPoint {
        switch self {
        case .atlantic: GeoPoint(latitude: 20, longitude: -40)
        case .pacific: GeoPoint(latitude: 0, longitude: -150)
        case .indian: GeoPoint(latitude: -20, longitude: 80)
        case .southern: GeoPoint(latitude: -65, longitude: 0)
        case .arctic: GeoPoint(latitude: 85, longitude: 0)
        }
    }
}
