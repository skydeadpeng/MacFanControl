import Foundation
import IOKit

// AppleSMC 用户态通信:IOConnectCallStructMethod 传 80 字节协议结构,
// 字段偏移与 C 结构体自然对齐一致(已在本机用探测程序实测验证)。
public enum SMCError: Error, CustomStringConvertible {
    case serviceNotFound
    case cannotOpen(Int)
    case callFailed(Int)
    case keyNotFound(String)
    case notPrivileged
    case badData(String)

    public var description: String {
        switch self {
        case .serviceNotFound: return "未找到 AppleSMC 服务"
        case .cannotOpen(let kr): return String(format: "打开 AppleSMC 失败 (0x%x)", kr)
        case .callFailed(let kr):
            if kr == 0xE00002C2 { return "无权限:SMC 写入需要 root(守护进程模式下自动获得)" }
            return String(format: "SMC 调用失败 (0x%x)", kr)
        case .keyNotFound(let k): return "SMC 键不存在: \(k)"
        case .notPrivileged: return "无权限:该操作需要 root"
        case .badData(let m): return "数据异常: \(m)"
        }
    }
}

/// 4 字符 SMC 键,如 "F0Ac"、"#KEY"
public struct SMCKey: Hashable, CustomStringConvertible {
    public let raw: UInt32

    public init(raw: UInt32) { self.raw = raw }

    public init?(_ string: String) {
        let b = Array(string.utf8)
        guard b.count == 4 else { return nil }
        self.raw = (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    public var description: String {
        let b: [UInt8] = [UInt8((raw >> 24) & 0xFF), UInt8((raw >> 16) & 0xFF),
                          UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)]
        return String(bytes: b, encoding: .ascii) ?? String(format: "%08x", raw)
    }

    /// 返回把首字符替换为数字后的新键,如 "F0Ac" -> "F1Ac"
    public func replacingFirstChar(with digit: Int) -> SMCKey {
        SMCKey(raw: (raw & 0x00FFFFFF) | (UInt32(UInt8(48 + digit)) << 24))
    }
}

public struct SMCKeyInfo {
    public let dataSize: UInt32
    public let dataType: UInt32

    public var typeName: String { SMCKey(raw: dataType).description }
}

public final class SMC {
    private var conn: io_connect_t = IO_OBJECT_NULL

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != IO_OBJECT_NULL else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        var c: io_connect_t = IO_OBJECT_NULL
        let kr = IOServiceOpen(service, mach_task_self_, 0, &c)
        guard kr == kIOReturnSuccess else { throw SMCError.cannotOpen(Int(kr)) }
        conn = c
    }

    deinit {
        if conn != IO_OBJECT_NULL { IOServiceClose(conn) }
    }

    // MARK: - 协议结构(80 字节,偏移与 C 结构体自然对齐一致:
    // keyInfo 嵌套结构体按 4 字节对齐补齐为 12 字节)

    private enum Layout {
        static let total = 80
        static let key = 0          // UInt32
        static let dataSize = 28    // UInt32 (keyInfo.dataSize)
        static let dataType = 32    // UInt32 (keyInfo.dataType)
        static let data8 = 42       // UInt8  子命令
        static let data32 = 44      // UInt32 索引
        static let bytes = 48       // 32 字节数据
    }

    private enum Cmd {
        static let readBytes: UInt8 = 5
        static let writeBytes: UInt8 = 6
        static let readIndex: UInt8 = 8
        static let readKeyInfo: UInt8 = 9
    }

    private func call(_ prepare: (inout [UInt8]) -> Void) throws -> [UInt8] {
        var input = [UInt8](repeating: 0, count: Layout.total)
        var output = [UInt8](repeating: 0, count: Layout.total)
        prepare(&input)
        var outSize = Layout.total
        let kr = input.withUnsafeMutableBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                IOConnectCallStructMethod(conn, 2,
                                          inPtr.baseAddress, Layout.total,
                                          outPtr.baseAddress, &outSize)
            }
        }
        guard kr == kIOReturnSuccess else {
            if kr == kIOReturnNotPrivileged { throw SMCError.notPrivileged }
            throw SMCError.callFailed(Int(kr))
        }
        return output
    }

    // MARK: - 基础操作

    public func keyInfo(_ key: SMCKey) throws -> SMCKeyInfo {
        let out = try call { i in
            i.store32(key.raw, at: Layout.key)
            i[Layout.data8] = Cmd.readKeyInfo
        }
        return SMCKeyInfo(dataSize: out.load32(Layout.dataSize), dataType: out.load32(Layout.dataType))
    }

    public func read(_ key: SMCKey) throws -> Data {
        let info = try keyInfo(key)
        guard info.dataSize > 0, info.dataSize <= 32 else { throw SMCError.badData("size=\(info.dataSize) for \(key)") }
        let out = try call { i in
            i.store32(key.raw, at: Layout.key)
            i.store32(info.dataSize, at: Layout.dataSize)
            i[Layout.data8] = Cmd.readBytes
        }
        return Data(out[Layout.bytes ..< Layout.bytes + Int(info.dataSize)])
    }

    public func write(_ key: SMCKey, _ data: Data) throws {
        guard !data.isEmpty, data.count <= 32 else { throw SMCError.badData("write size \(data.count)") }
        _ = try call { i in
            i.store32(key.raw, at: Layout.key)
            i.store32(UInt32(data.count), at: Layout.dataSize)
            i[Layout.data8] = Cmd.writeBytes
            data.enumerated().forEach { j, b in i[Layout.bytes + j] = b }
        }
    }

    public func keyCount() throws -> Int {
        guard let d = try? read(SMCKey("#KEY")!), d.count == 4 else { throw SMCError.badData("#KEY") }
        return Int(d[0]) << 24 | Int(d[1]) << 16 | Int(d[2]) << 8 | Int(d[3])
    }

    public func key(at index: Int) throws -> SMCKey {
        let out = try call { i in
            i[Layout.data8] = Cmd.readIndex
            i.store32(UInt32(index), at: Layout.data32)
        }
        return SMCKey(raw: out.load32(Layout.key))
    }

    /// 枚举全部 SMC 键(约 2100 个,耗时 ~1 秒)
    public func allKeys() -> [SMCKey] {
        guard let count = (try? keyCount()) ?? nil else { return [] }
        var keys = [SMCKey]()
        keys.reserveCapacity(count)
        for i in 0..<count {
            guard let k = try? key(at: i) else { continue }
            keys.append(k)
        }
        return keys
    }

    // MARK: - 带类型解码的读取

    public func readValue(_ key: SMCKey) throws -> SMCValue {
        let info = try keyInfo(key)
        let d = try read(key)
        return SMCValue.decode(d, typeName: info.typeName)
    }

    public func readDouble(_ key: SMCKey) throws -> Double {
        guard let v = try readValue(key).doubleValue else { throw SMCError.badData("无法解码 \(key)") }
        return v
    }

    /// 读一个键并按整数解析(ui8 等)
    public func readInt(_ key: SMCKey) throws -> Int {
        guard let v = try readValue(key).intValue else { throw SMCError.badData("无法解码 \(key)") }
        return v
    }
}

extension Array where Element == UInt8 {
    mutating func store32(_ v: UInt32, at o: Int) {
        self[o] = UInt8(truncatingIfNeeded: v)
        self[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
        self[o + 2] = UInt8(truncatingIfNeeded: v >> 16)
        self[o + 3] = UInt8(truncatingIfNeeded: v >> 24)
    }

    func load32(_ o: Int) -> UInt32 {
        return UInt32(self[o]) | UInt32(self[o + 1]) << 8 | UInt32(self[o + 2]) << 16 | UInt32(self[o + 3]) << 24
    }
}
