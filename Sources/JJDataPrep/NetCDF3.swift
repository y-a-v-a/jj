import Foundation

/// A minimal reader for NetCDF-3 classic ("CDF\x01") and 64-bit offset
/// ("CDF\x02") files: dimensions, attributes and non-record variables.
struct NetCDF3 {
    enum ValueType: Int32 {
        case byte = 1, char, short, int, float, double

        var size: Int {
            switch self {
            case .byte, .char: 1
            case .short: 2
            case .int, .float: 4
            case .double: 8
            }
        }
    }

    enum Attribute {
        case text(String)
        case numbers([Double])

        var number: Double? { if case .numbers(let n) = self { n.first } else { nil } }
    }

    struct Dimension { let name: String; let length: Int }

    struct Variable {
        let name: String
        let dimensions: [Int]
        let attributes: [String: Attribute]
        let type: ValueType
        let size: Int
        let begin: Int
    }

    let data: Data
    private(set) var dimensions: [Dimension] = []
    private(set) var attributes: [String: Attribute] = [:]
    private(set) var variables: [String: Variable] = [:]

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    init(data: Data) throws {
        self.data = data
        var cursor = Cursor(data: data)
        guard try cursor.bytes(3) == Array("CDF".utf8) else { throw PrepError("not a NetCDF-3 file") }
        let version = try cursor.bytes(1)[0]
        guard version == 1 || version == 2 else { throw PrepError("unsupported NetCDF version \(version)") }
        _ = try cursor.int32() // numrecs

        // dim_list
        let dimTag = try cursor.int32(), dimCount = Int(try cursor.int32())
        guard dimTag == 0x0A || (dimTag == 0 && dimCount == 0) else { throw PrepError("bad NetCDF dimension list") }
        for _ in 0..<dimCount {
            let name = try cursor.name()
            dimensions.append(Dimension(name: name, length: Int(try cursor.int32())))
        }
        attributes = try cursor.attributes()

        // var_list
        let varTag = try cursor.int32(), varCount = Int(try cursor.int32())
        guard varTag == 0x0B || (varTag == 0 && varCount == 0) else { throw PrepError("bad NetCDF variable list") }
        for _ in 0..<varCount {
            let name = try cursor.name()
            let rank = Int(try cursor.int32())
            var dims: [Int] = []
            for _ in 0..<rank { dims.append(Int(try cursor.int32())) }
            let attributes = try cursor.attributes()
            guard let type = ValueType(rawValue: try cursor.int32()) else { throw PrepError("bad NetCDF type in \(name)") }
            let size = Int(UInt32(bitPattern: try cursor.int32()))
            let begin = version == 1 ? Int(try cursor.int32()) : Int(try cursor.int64())
            variables[name] = Variable(name: name, dimensions: dims, attributes: attributes, type: type, size: size, begin: begin)
        }
    }

    func shape(of name: String) throws -> [Int] {
        guard let v = variables[name] else { throw PrepError("NetCDF file has no variable \(name)") }
        return v.dimensions.map { dimensions[$0].length }
    }

    /// The variable's values as stored (no scale/offset or fill handling).
    func values(of name: String) throws -> [Double] {
        guard let v = variables[name] else { throw PrepError("NetCDF file has no variable \(name)") }
        guard !v.dimensions.contains(where: { dimensions[$0].length == 0 }) else {
            throw PrepError("record variables are not supported (\(name))")
        }
        let count = try shape(of: name).reduce(1, *)
        guard v.begin + count * v.type.size <= data.count else { throw PrepError("NetCDF variable \(name) is truncated") }
        return data.withUnsafeBytes { raw in
            (0..<count).map { k in
                let at = v.begin + k * v.type.size
                switch v.type {
                case .byte: return Double(Int8(bitPattern: raw[at]))
                case .char: return Double(raw[at])
                case .short: return Double(Int16(bigEndian: raw.loadUnaligned(fromByteOffset: at, as: Int16.self)))
                case .int: return Double(Int32(bigEndian: raw.loadUnaligned(fromByteOffset: at, as: Int32.self)))
                case .float:
                    return Double(Float(bitPattern: UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))))
                case .double:
                    return Double(bitPattern: UInt64(bigEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt64.self)))
                }
            }
        }
    }

    /// Values with `scale_factor`/`add_offset` applied and `_FillValue`/`missing_value` as NaN.
    func unpackedValues(of name: String) throws -> [Double] {
        let v = variables[name]!
        let scale = v.attributes["scale_factor"]?.number ?? 1
        let offset = v.attributes["add_offset"]?.number ?? 0
        let fills = ["_FillValue", "missing_value"].compactMap { v.attributes[$0]?.number }
        return try values(of: name).map { fills.contains($0) ? .nan : $0 * scale + offset }
    }

    private struct Cursor {
        let data: Data
        var offset = 0

        mutating func bytes(_ n: Int) throws -> [UInt8] {
            guard offset + n <= data.count else { throw PrepError("NetCDF header is truncated") }
            defer { offset += n }
            return Array(data[data.startIndex + offset ..< data.startIndex + offset + n])
        }

        mutating func int32() throws -> Int32 {
            let b = try bytes(4)
            return Int32(bitPattern: UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        }

        mutating func int64() throws -> Int64 {
            let hi = Int64(try int32()), lo = Int64(UInt32(bitPattern: try int32()))
            return hi << 32 | lo
        }

        mutating func padded(_ n: Int) throws -> [UInt8] {
            let b = try bytes(n)
            offset += (4 - n % 4) % 4
            return b
        }

        mutating func name() throws -> String {
            let n = Int(try int32())
            return String(decoding: try padded(n), as: UTF8.self)
        }

        mutating func attributes() throws -> [String: Attribute] {
            let tag = try int32(), count = Int(try int32())
            guard tag == 0x0C || (tag == 0 && count == 0) else { throw PrepError("bad NetCDF attribute list") }
            var result: [String: Attribute] = [:]
            for _ in 0..<count {
                let name = try name()
                guard let type = ValueType(rawValue: try int32()) else { throw PrepError("bad NetCDF attribute type") }
                let n = Int(try int32())
                let raw = try padded(n * type.size)
                if type == .char {
                    result[name] = .text(String(decoding: raw, as: UTF8.self))
                } else {
                    result[name] = .numbers(NetCDF3.decode(raw, type: type, count: n))
                }
            }
            return result
        }
    }
}

extension NetCDF3 {
    /// Decodes big-endian numeric attribute values.
    fileprivate static func decode(_ raw: [UInt8], type: ValueType, count: Int) -> [Double] {
        (0..<count).map { k in
            let b = raw[(k * type.size)..<((k + 1) * type.size)]
            let u = b.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            switch type {
            case .byte: return Double(Int8(bitPattern: UInt8(u)))
            case .char: return Double(u)
            case .short: return Double(Int16(bitPattern: UInt16(u)))
            case .int: return Double(Int32(bitPattern: UInt32(u)))
            case .float: return Double(Float(bitPattern: UInt32(u)))
            case .double: return Double(bitPattern: u)
            }
        }
    }
}
