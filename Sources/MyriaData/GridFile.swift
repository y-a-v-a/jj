import Foundation

/// A stack of equirectangular rasters ("layers") on the sphere, stored in
/// JJ's small binary grid format:
///
///     "JJGRID01"                 8 bytes magic
///     header length N            UInt32, little endian
///     header                     N bytes of UTF-8 JSON (`GridFile.Header`)
///     payload                    layer-major, then rows, then columns;
///                                little-endian values, LZFSE-compressed
///                                when `compression` is "lzfse"
///
/// Cell (i, j) of a layer is centred at longitude `lon0 + i·dlon` and
/// latitude `lat0 + j·dlat`. Stored values decode as `raw · scale + offset`;
/// raw values equal to `missing` decode to NaN.
public struct GridFile: Sendable {
    public struct Header: Codable, Sendable, Hashable {
        public enum ValueType: String, Codable, Sendable { case float32, int16, uint8 }

        public var width: Int
        public var height: Int
        public var layers: [String]
        public var type: ValueType
        public var lon0: Double
        public var lat0: Double
        public var dlon: Double
        public var dlat: Double
        public var scale: Double
        public var offset: Double
        public var missing: Double?
        public var units: String
        public var source: String
        public var compression: String

        public init(width: Int, height: Int, layers: [String], type: ValueType, lon0: Double, lat0: Double,
                    dlon: Double, dlat: Double, scale: Double = 1, offset: Double = 0, missing: Double? = nil,
                    units: String, source: String, compression: String = "lzfse") {
            self.width = width
            self.height = height
            self.layers = layers
            self.type = type
            self.lon0 = lon0
            self.lat0 = lat0
            self.dlon = dlon
            self.dlat = dlat
            self.scale = scale
            self.offset = offset
            self.missing = missing
            self.units = units
            self.source = source
            self.compression = compression
        }

        var bytesPerValue: Int {
            switch type {
            case .float32: 4
            case .int16: 2
            case .uint8: 1
            }
        }
    }

    public enum Error: Swift.Error, CustomStringConvertible {
        case notAGrid
        case truncated
        case decompressionFailed
        case unknownLayer(String)

        public var description: String {
            switch self {
            case .notAGrid: "not a JJ grid file"
            case .truncated: "grid file is truncated"
            case .decompressionFailed: "could not decompress the grid payload"
            case .unknownLayer(let name): "grid has no layer named \(name)"
            }
        }
    }

    static let magic = Array("JJGRID01".utf8)

    public let header: Header
    /// Decoded values per layer, row-major.
    public let layers: [[Float]]

    public init(header: Header, layers: [[Float]]) {
        precondition(layers.count == header.layers.count, "one array per layer name")
        precondition(layers.allSatisfy { $0.count == header.width * header.height }, "width × height values per layer")
        self.header = header
        self.layers = layers
    }

    public func layer(named name: String) throws -> [Float] {
        guard let i = header.layers.firstIndex(of: name) else { throw Error.unknownLayer(name) }
        return layers[i]
    }

    // MARK: Reading

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    public init(data: Data) throws {
        guard data.count >= 12, Array(data.prefix(8)) == Self.magic else { throw Error.notAGrid }
        let n = data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self))) }
        guard data.count >= 12 + n else { throw Error.truncated }
        let header = try JSONDecoder().decode(Header.self, from: data.subdata(in: 12..<(12 + n)))
        var payload = data.subdata(in: (12 + n)..<data.count)
        if header.compression == "lzfse" {
            guard let raw = try? (payload as NSData).decompressed(using: .lzfse) as Data else {
                throw Error.decompressionFailed
            }
            payload = raw
        }
        let count = header.width * header.height
        guard payload.count >= count * header.layers.count * header.bytesPerValue else { throw Error.truncated }
        let scale = Float(header.scale), offset = Float(header.offset)
        let missing = header.missing.map(Float.init)
        var layers: [[Float]] = []
        layers.reserveCapacity(header.layers.count)
        payload.withUnsafeBytes { raw in
            for l in 0..<header.layers.count {
                let base = l * count * header.bytesPerValue
                var values = [Float](repeating: 0, count: count)
                for k in 0..<count {
                    let at = base + k * header.bytesPerValue
                    let v: Float = switch header.type {
                    case .float32: Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
                    case .int16: Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: Int16.self)))
                    case .uint8: Float(raw.load(fromByteOffset: at, as: UInt8.self))
                    }
                    values[k] = v == missing ? .nan : v * scale + offset
                }
                layers.append(values)
            }
        }
        self.header = header
        self.layers = layers
    }

    // MARK: Writing

    /// Encodes the grid. Values are stored as `(value - offset) / scale`,
    /// rounded for integer types; NaN is stored as `missing`.
    public func encoded() throws -> Data {
        var payload = Data(capacity: header.width * header.height * header.layers.count * header.bytesPerValue)
        let scale = header.scale, offset = header.offset
        for layer in layers {
            for v in layer {
                let raw = v.isNaN ? (header.missing ?? 0) : (Double(v) - offset) / scale
                switch header.type {
                case .float32:
                    withUnsafeBytes(of: Float(raw).bitPattern.littleEndian) { payload.append(contentsOf: $0) }
                case .int16:
                    let r = Int16(clamping: Int(raw.rounded()))
                    withUnsafeBytes(of: r.littleEndian) { payload.append(contentsOf: $0) }
                case .uint8:
                    payload.append(UInt8(clamping: Int(raw.rounded())))
                }
            }
        }
        if header.compression == "lzfse" {
            payload = try (payload as NSData).compressed(using: .lzfse) as Data
        }
        let json = try JSONEncoder().encode(header)
        var out = Data(Self.magic)
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(json)
        out.append(payload)
        return out
    }

    public func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }
}
