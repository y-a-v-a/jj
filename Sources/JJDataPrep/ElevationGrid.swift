import Foundation
import MyriaData

/// ETOPO1 ice-surface relief (grid registered, 1 arc-minute: 10801 latitudes
/// × 21601 longitudes from −90/−180 to 90/180), subsampled server-side by
/// ERDDAP and fetched as NetCDF-3 in latitude bands.
enum ElevationGrid {
    static let erddap = "https://coastwatch.pfeg.noaa.gov/erddap/griddap/etopo180.nc"
    static let latCount = 10801, lonCount = 21601
    static let sizeLimit = 12 * 1_048_576

    static func run(_ ws: Workspace, stride arcMinutes: Int) throws {
        let rows = (latCount - 1) / arcMinutes + 1
        let lastLon = ((lonCount - 1) / arcMinutes) * arcMinutes
        let bandRows = 360
        var lats: [Double] = []
        var lons: [Double] = []
        var values: [Double] = []
        for r0 in Swift.stride(from: 0, to: rows, by: bandRows) {
            let r1 = min(r0 + bandRows, rows) - 1
            let query = "altitude[\(r0 * arcMinutes):\(arcMinutes):\(r1 * arcMinutes)][0:\(arcMinutes):\(lastLon)]"
            let file = try ws.raw("etopo180_\(arcMinutes)min_rows\(r0)-\(r1).nc", from: erddap + "?" + query)
            let nc = try NetCDF3(contentsOf: file)
            let shape = try nc.shape(of: "altitude")
            let bandLons = try nc.values(of: "longitude")
            guard shape == [r1 - r0 + 1, bandLons.count] else { throw PrepError("\(file.lastPathComponent): unexpected shape \(shape)") }
            if lons.isEmpty { lons = bandLons } else if lons != bandLons { throw PrepError("longitudes differ between bands") }
            lats += try nc.values(of: "latitude")
            values += try nc.unpackedValues(of: "altitude")
        }
        var width = lons.count
        let height = lats.count
        guard height == rows, height > 1, width > 1 else { throw PrepError("unexpected ETOPO grid \(width)×\(height)") }

        // Drop the duplicated 180° column; make rows run south → north.
        let wrapped = abs(lons[width - 1] - lons[0] - 360) < 1e-6
        if wrapped { width -= 1 }
        let northFirst = lats[0] > lats[height - 1]
        var layer = [Float](repeating: 0, count: width * height)
        for j in 0..<height {
            let src = northFirst ? height - 1 - j : j
            for i in 0..<width { layer[j * width + i] = Float(values[src * lons.count + i]) }
        }
        let lat0 = northFirst ? lats[height - 1] : lats[0]
        let step = Double(arcMinutes) / 60
        let finite = layer.filter { !$0.isNaN }
        let missing = layer.count - finite.count

        let header = GridFile.Header(
            width: width, height: height, layers: ["elevation"], type: .int16,
            lon0: lons[0], lat0: lat0, dlon: step, dlat: step, missing: missing > 0 ? -32768 : nil,
            units: "m",
            source: "ETOPO1 Global Relief Model, ice surface, grid registered (Amante & Eakins 2009, NOAA Technical "
                + "Memorandum NESDIS NGDC-24, doi:10.7289/V5C8276M), NOAA NCEI; subsampled every \(arcMinutes) arc-minutes "
                + "via NOAA CoastWatch ERDDAP (dataset etopo180).",
            compression: "lzfse")
        let data = try GridFile(header: header, layers: [layer]).encoded()
        print("   \(width)×\(height) at \(arcMinutes)′, lon0 \(lons[0]), lat0 \(lat0); "
            + "elevation \(Int(finite.min() ?? .nan))…\(Int(finite.max() ?? .nan)) m"
            + (missing > 0 ? ", \(missing) missing" : ""))
        if data.count > sizeLimit && arcMinutes < 6 {
            print("   \(formatBytes(data.count)) exceeds \(formatBytes(sizeLimit)); retrying at 6 arc-minutes")
            return try run(ws, stride: 6)
        }
        try ws.write(data, to: "elevation.grid")
    }
}
