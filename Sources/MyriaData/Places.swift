import Foundation
import MyriaCore

/// A populated place (Natural Earth populated places).
public struct Place: Sendable, Hashable, Codable {
    public let name: String
    public let country: String
    public let lat: Double
    public let lon: Double
    /// Population of the metropolitan area.
    public let pop: Int
    /// Natural Earth scale rank: lower is more prominent.
    public let rank: Int
    public let capital: Bool

    public var location: GeoPoint { GeoPoint(latitude: lat, longitude: lon) }
}

public struct PlaceSet: Sendable {
    /// Sorted by population, largest first.
    public let places: [Place]
    let index: PointIndex

    public init(places: [Place]) {
        self.places = places.sorted { $0.pop > $1.pop }
        index = PointIndex(self.places.map(\.location.unitVector))
    }

    public init(contentsOf url: URL) throws {
        self.init(places: try JSONDecoder().decode([Place].self, from: Data(contentsOf: url)))
    }

    /// The place nearest to `p` and its distance in radians.
    public func nearest(to p: Vec3) -> (place: Place, distance: Double)? {
        index.nearest(to: p).map { (places[$0.index], $0.distance) }
    }
}

/// The world's air routes (OpenFlights): airports and the number of airline
/// routes between pairs of them.
public struct FlightNetwork: Sendable {
    public struct Airport: Sendable, Hashable {
        public let location: GeoPoint
        public let code: String
        public let name: String
        public let city: String
        public let country: String
        public let routeCount: Int
    }

    public struct Route: Sendable, Hashable {
        public let from: Int
        public let to: Int
        /// Airline routes flying between the two airports.
        public let count: Int
    }

    public let airports: [Airport]
    public let routes: [Route]

    public init(airports: [Airport], routes: [Route]) {
        self.airports = airports
        self.routes = routes
    }

    public init(contentsOf url: URL) throws {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let rawAirports = root["airports"] as? [[Any]], let rawRoutes = root["routes"] as? [[Any]]
        else { throw GeoJSONError.malformedGeometry("flights.json") }
        func number(_ v: Any) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }
        airports = rawAirports.map { a in
            Airport(location: GeoPoint(latitude: number(a[0]), longitude: number(a[1])),
                    code: a.count > 2 ? a[2] as? String ?? "" : "", name: a.count > 3 ? a[3] as? String ?? "" : "",
                    city: a.count > 4 ? a[4] as? String ?? "" : "", country: a.count > 5 ? a[5] as? String ?? "" : "",
                    routeCount: a.count > 6 ? Int(number(a[6])) : 0)
        }
        routes = rawRoutes.map { Route(from: Int(number($0[0])), to: Int(number($0[1])), count: Int(number($0[2]))) }
    }

    /// The great-circle arc of a route, with points no more than `step`
    /// radians apart.
    public func arc(_ route: Route, step: Double = 0.02) -> [Vec3] {
        let a = airports[route.from].location.unitVector, b = airports[route.to].location.unitVector
        let n = max(1, Int((a.angle(to: b) / step).rounded(.up)))
        return (0...n).map { Spherical.slerp(a, b, Double($0) / Double(n)) }
    }
}
