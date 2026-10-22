import Foundation

/// 风扇实时状态
public struct FanInfo {
    public let index: Int
    public var rpm: Double      // F%dAc 实际转速
    public var min: Double      // F%dMn 报告下限
    public var max: Double      // F%dMx 上限
    public var target: Double   // F%dTg 目标转速
    public var mode: Int        // F%dMd 0=自动 1=手动 3=系统(thermalmonitord 接管)

    public var name: String { "风扇 \(index + 1)" }
}

public struct FanSnapshot {
    public let fans: [FanInfo]
    public let timestamp: Date
}

public enum FanAccess {
    /// 当前进程是否为 root(SMC 风扇键写入需要 root)
    public static var isRoot: Bool { geteuid() == 0 }

    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }
}

public extension SMC {
    func fanCount() throws -> Int {
        let v = try readValue(SMCKey("FNum")!)
        guard let n = v.intValue, n > 0, n < 16 else { return 0 }
        return n
    }

    /// 读取全部风扇当前状态
    func readFans() throws -> [FanInfo] {
        let n = try fanCount()
        var fans = [FanInfo]()
        fans.reserveCapacity(n)
        for i in 0..<n {
            func key(_ suffix: String) -> SMCKey? { SMCKey("F\(i)\(suffix)") }
            let min = (try? readDouble(key("Mn")!)) ?? 0
            let max = (try? readDouble(key("Mx")!)) ?? 0
            // Ac/Md 偶发读到坏值(多客户端并发时),低于合理范围时重读
            var rpm = (try? readDouble(key("Ac")!)) ?? 0
            if min > 500, rpm < min * 0.5 {
                for _ in 0..<2 {
                    Thread.sleep(forTimeInterval: 0.05)
                    rpm = (try? readDouble(key("Ac")!)) ?? rpm
                    if rpm >= min * 0.5 { break }
                }
            }
            var target = (try? readDouble(key("Tg")!)) ?? 0
            if target < 0 { target = (try? readDouble(key("Tg")!)) ?? target }
            var mode = (try? readInt(key("Md")!)) ?? -1
            if mode < 0 { mode = (try? readInt(key("Md")!)) ?? mode }
            fans.append(FanInfo(index: i, rpm: rpm, min: min, max: max, target: target, mode: mode))
        }
        return fans
    }
}

/// 风扇写入器。
/// Apple Silicon:F%dMd=1(手动模式)+ F%dTg(目标转速);
///   若模式写入被拒(M3/M4 上 thermalmonitord 持有 mode 3),走 Ftst=1 诊断解锁流程;
///   M5 上模式键为小写 F%dmd。
/// Intel:直接写 F%dMn(最小转速),系统仍按自动曲线在其上调度。
public final class FanWriter {
    private let smc: SMC
    private let keys: Set<String>          // 本机存在的键缓存
    private var modeKeyCache: [Int: String] = [:]   // 每个风扇的模式键名(Md 或 md)
    private var ftstApplied = false
    private var heldFans: Set<Int> = []
    private var originalMin: [Int: Data] = [:]      // Intel 恢复用
    private var originalMode: [Int: Int] = [:]      // AS:记录接管前的模式(系统常为 1)

    public private(set) var lastError: String?

    public init(smc: SMC, allKeys: [SMCKey]? = nil) {
        self.smc = smc
        self.keys = Set((allKeys ?? smc.allKeys()).map(\.description))
    }

    // MARK: - 模式

    private func modeKey(for index: Int) -> String? {
        if let cached = modeKeyCache[index] { return cached }
        let upper = "F\(index)Md", lower = "F\(index)md"
        let k = keys.contains(upper) ? upper : (keys.contains(lower) ? lower : nil)
        if let k = k { modeKeyCache[index] = k }
        return k
    }

    /// 读取风扇当前模式
    public func readMode(_ index: Int) -> Int {
        guard let mk = modeKey(for: index), let k = SMCKey(mk),
              let v = try? smc.readInt(k) else { return -1 }
        return v
    }

    private func writeMode(_ index: Int, _ value: Int) throws {
        guard let mk = modeKey(for: index), let k = SMCKey(mk) else {
            throw SMCError.keyNotFound("F\(index)Md")
        }
        try smc.write(k, SMCValue.uint8Bytes(value))
    }

    // MARK: - Apple Silicon 控制

    /// 把风扇切到手动模式(M1/M2 直接写;M3/M4 写 F%dMd 被拒时走 Ftst 解锁;M5 小写键)
    public func hold(_ index: Int) throws {
        guard !heldFans.contains(index) else { return }
        if FanAccess.isAppleSilicon {
            originalMode[index] = originalMode[index] ?? readMode(index)
            do {
                try writeMode(index, 1)
            } catch {
                if let k = SMCKey("Ftst") {
                    try? smc.write(k, SMCValue.uint8Bytes(1))
                    ftstApplied = true
                }
                try retryUntilDone(timeout: 10) { [self] in
                    try writeMode(index, 1)
                    return readMode(index) == 1
                }
            }
            // 实测 M1 上 Md 会被系统回写,但 F%dTg 目标依然生效,不强求模式位
        } else {
            // Intel:记录原始 Mn,便于退出恢复
            if originalMin[index] == nil, let k = SMCKey("F\(index)Mn") {
                originalMin[index] = try? smc.read(k)
            }
        }
        heldFans.insert(index)
    }

    /// 写入目标转速(Apple Silicon 写 F%dTg;Intel 写 F%dMn)。
    /// 写入后立即回读在实测中会偶发返回 0,验证由守护进程下一轮被动完成。
    public func writeTarget(_ index: Int, rpm: Double) throws {
        if FanAccess.isAppleSilicon {
            guard let k = SMCKey("F\(index)Tg") else { throw SMCError.keyNotFound("F\(index)Tg") }
            try smc.write(k, SMCValue.floatBytes(rpm))
        } else {
            guard let k = SMCKey("F\(index)Mn") else { throw SMCError.keyNotFound("F\(index)Mn") }
            try smc.write(k, SMCValue.fpe2Bytes(rpm))
        }
    }

    /// 恢复单个风扇为系统控制(还原接管前的模式;thermalmonitord 会自行接管)
    public func release(_ index: Int) {
        heldFans.remove(index)
        if FanAccess.isAppleSilicon {
            if let mk = modeKey(for: index), let k = SMCKey(mk) {
                let back = originalMode[index] ?? 0
                try? smc.write(k, SMCValue.uint8Bytes(back))
            }
            if ftstApplied && heldFans.isEmpty {
                if let k = SMCKey("Ftst") { try? smc.write(k, SMCValue.uint8Bytes(0)) }
                ftstApplied = false
            }
        } else if let orig = originalMin[index], let k = SMCKey("F\(index)Mn") {
            try? smc.write(k, orig)
        }
    }

    public func releaseAll() {
        for i in heldFans { release(i) }
    }

    public var holdingCount: Int { heldFans.count }

    // MARK: - 重试工具

    private func retryUntilDone(timeout: Double, interval: Double = 0.1,
                                _ body: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastErr: Error?
        while Date() < deadline {
            do {
                if try body() { return }
            } catch { lastErr = error }
            Thread.sleep(forTimeInterval: interval)
        }
        if let e = lastErr { throw e }
    }
}
