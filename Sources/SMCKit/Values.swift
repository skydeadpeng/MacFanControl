import Foundation

/// SMC 值的类型与解码。
/// Apple Silicon 上风扇转速/温度多为 "flt "(小端 IEEE754 float);
/// Intel 上风扇为 "fpe2"(大端定点),温度为 "sp78"。
public enum SMCValue {
    case double(Double, type: String)
    case int(Int, type: String)
    case raw(Data, type: String)

    public var doubleValue: Double? {
        switch self {
        case .double(let d, _): return d
        case .int(let i, _): return Double(i)
        case .raw: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .double(let d, _): return Int(d.rounded())
        case .int(let i, _): return i
        case .raw: return nil
        }
    }

    public var typeName: String {
        switch self {
        case .double(_, let t): return t
        case .int(_, let t): return t
        case .raw(_, let t): return t
        }
    }

    public static func decode(_ data: Data, typeName: String) -> SMCValue {
        let t = typeName.trimmingCharacters(in: .whitespaces)
        switch t {
        case "flt":
            // 小端 float32
            guard data.count >= 4 else { return .raw(data, type: typeName) }
            let bits = UInt32(data[data.startIndex]) | UInt32(data[data.startIndex + 1]) << 8
                | UInt32(data[data.startIndex + 2]) << 16 | UInt32(data[data.startIndex + 3]) << 24
            return .double(Double(Float(bitPattern: bits)), type: typeName)
        case "fpe2":
            // 大端定点:2 字节 ÷4,4 字节 ÷16384
            let bytes = [UInt8](data.prefix(4))
            if bytes.count == 2 {
                let raw16 = UInt32(bytes[0]) << 8 | UInt32(bytes[1])
                return .double(Double(raw16) / 4.0, type: typeName)
            } else if bytes.count == 4 {
                let raw32 = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
                return .double(Double(raw32) / 16384.0, type: typeName)
            }
            return .raw(data, type: typeName)
        case "sp78":
            guard data.count >= 2 else { return .raw(data, type: typeName) }
            let i = Int(Int8(bitPattern: data[data.startIndex]))
            let frac = Double(data[data.startIndex + 1]) / 256.0
            return .double(Double(i) + frac, type: typeName)
        case "fp5f":
            guard data.count >= 2 else { return .raw(data, type: typeName) }
            let raw = Int(Int16(bitPattern: UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])))
            return .double(Double(raw) / 320.0, type: typeName)
        case "sp5a":
            guard data.count >= 2 else { return .raw(data, type: typeName) }
            let raw = Int(UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1]))
            return .double(Double(raw >> 9) + Double(raw & 0x1FF) / 512.0, type: typeName)
        case "ioft":
            // 8 字节小端定点 ÷65536(Apple Silicon GPU 传感器)
            guard data.count >= 4 else { return .raw(data, type: typeName) }
            var v: UInt64 = 0
            for (i, b) in data.prefix(8).enumerated() { v |= UInt64(b) << (8 * i) }
            return .double(Double(v) / 65536.0, type: typeName)
        case "ui8", "flag", "ui8 ":
            guard let b = data.first else { return .raw(data, type: typeName) }
            return .int(Int(b), type: typeName)
        case "ui16":
            guard data.count >= 2 else { return .raw(data, type: typeName) }
            return .int(Int(UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])), type: typeName)
        case "ui32":
            guard data.count >= 4 else { return .raw(data, type: typeName) }
            let v = UInt32(data[data.startIndex]) << 24 | UInt32(data[data.startIndex + 1]) << 16
                | UInt32(data[data.startIndex + 2]) << 8 | UInt32(data[data.startIndex + 3])
            return .int(Int(v), type: typeName)
        default:
            return .raw(data, type: typeName)
        }
    }

    // MARK: - 编码(写入用)

    /// Apple Silicon "flt ":小端 float32
    public static func floatBytes(_ v: Double) -> Data {
        let bits = Float(v).bitPattern
        return Data([UInt8(truncatingIfNeeded: bits),
                     UInt8(truncatingIfNeeded: bits >> 8),
                     UInt8(truncatingIfNeeded: bits >> 16),
                     UInt8(truncatingIfNeeded: bits >> 24)])
    }

    /// Intel "fpe2":2 字节大端 ×4
    public static func fpe2Bytes(_ v: Double) -> Data {
        let raw = UInt16(clamping: Int(v * 4))
        return Data([UInt8(raw >> 8), UInt8(raw & 0xFF)])
    }

    public static func uint8Bytes(_ v: Int) -> Data {
        Data([UInt8(clamping: v)])
    }
}
