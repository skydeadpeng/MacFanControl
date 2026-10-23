import Foundation

/// 路径约定(root 守护进程使用正式路径;用户直跑用于测试时落到 /tmp)
public enum Paths {
    public static var isRoot: Bool { geteuid() == 0 }

    public static var installDir: String {
        isRoot ? "/Library/Application Support/MacFanControl"
               : "/tmp/macfancontrol"
    }

    public static var configFile: String { installDir + "/config.json" }
    public static var logFile: String { installDir + "/fanctl.log" }
    public static var daemonBinary: String { installDir + "/fanctl" }
    public static var launchdPlist: String { "/Library/LaunchDaemons/com.macfancontrol.daemon.plist" }
    public static var daemonLabel: String { "com.macfancontrol.daemon" }

    /// 客户端尝试连接的 socket 列表(root 守护进程 + 可能的用户测试进程)
    public static var socketCandidates: [String] {
        isRoot ? ["/var/run/macfanctl.sock"]
               : ["/var/run/macfanctl.sock", "/tmp/macfanctl.sock"]
    }

    public static var serverSocket: String {
        isRoot ? "/var/run/macfanctl.sock" : "/tmp/macfanctl.sock"
    }
}

/// 曲线控制点(温度°C → 转速)
public struct CurvePoint: Codable, Equatable {
    public var temp: Double
    public var rpm: Double
    public init(temp: Double, rpm: Double) { self.temp = temp; self.rpm = rpm }
}

/// 控制配置(JSON 持久化)
public struct Config: Codable {
    public var enabled: Bool = true
    public var mode: String = "auto"              // auto | manual
    public var sensors: [String]? = nil           // nil = 自动选择 CPU/GPU
    public var tempStart: Double = 70             // °C,开始升速(兼容旧版两点曲线)
    public var tempFull: Double = 95              // °C,全速
    public var curves: [String: [CurvePoint]] = [:]   // 风扇序号 -> 多点曲线(空=用上面两点)
    public var minRPM: [String: Double] = [:]     // 风扇序号 -> 自动曲线下限
    public var manualRPM: [String: Double] = [:]  // 风扇序号 -> 手动转速
    public var interval: Double = 2               // 秒

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, mode, sensors, tempStart, tempFull, curves, minRPM, manualRPM, interval
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "auto"
        sensors = try c.decodeIfPresent([String].self, forKey: .sensors)
        tempStart = try c.decodeIfPresent(Double.self, forKey: .tempStart) ?? 70
        tempFull = try c.decodeIfPresent(Double.self, forKey: .tempFull) ?? 95
        curves = try c.decodeIfPresent([String: [CurvePoint]].self, forKey: .curves) ?? [:]
        minRPM = try c.decodeIfPresent([String: Double].self, forKey: .minRPM) ?? [:]
        manualRPM = try c.decodeIfPresent([String: Double].self, forKey: .manualRPM) ?? [:]
        interval = try c.decodeIfPresent(Double.self, forKey: .interval) ?? 2
    }

    public static func load(path: String = Paths.configFile) -> Config {
        guard let data = FileManager.default.contents(atPath: path) else { return Config() }
        if let cfg = try? JSONDecoder().decode(Config.self, from: data) { return cfg }
        return Config()
    }

    public func save(path: String = Paths.configFile) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: URL(fileURLWithPath: path))
    }

    /// 用补丁合并(部分字段更新)
    public mutating func apply(patch: ConfigPatch) {
        if let v = patch.enabled { enabled = v }
        if let v = patch.mode { mode = v == "manual" ? "manual" : "auto" }
        if let v = patch.sensors { sensors = v.isEmpty ? nil : v }
        if let v = patch.tempStart { tempStart = min(max(v, 35), 80) }
        if let v = patch.tempFull { tempFull = min(max(v, tempStart + 5), 105) }
        if let v = patch.curves { curves = v }
        if let v = patch.minRPM { minRPM.merge(v) { _, new in new } }
        if let v = patch.manualRPM { manualRPM.merge(v) { _, new in new } }
        if let v = patch.interval { interval = min(max(v, 1), 10) }
    }
}

/// set 命令的部分更新
public struct ConfigPatch: Codable {
    public var enabled: Bool?
    public var mode: String?
    public var sensors: [String]?
    public var tempStart: Double?
    public var tempFull: Double?
    public var curves: [String: [CurvePoint]]?
    public var minRPM: [String: Double]?
    public var manualRPM: [String: Double]?
    public var interval: Double?

    public init(from dict: [String: Any]) {
        enabled = dict["enabled"] as? Bool
        mode = dict["mode"] as? String
        if let s = dict["sensors"] as? [String] { sensors = s }
        if let n = dict["tempStart"] as? NSNumber { tempStart = n.doubleValue }
        if let n = dict["tempFull"] as? NSNumber { tempFull = n.doubleValue }
        if let d = dict["curves"] as? [String: [[Double]]] {
            curves = d.mapValues { pts in
                pts.compactMap { p in p.count == 2 ? CurvePoint(temp: p[0], rpm: p[1]) : nil }
            }
        }
        if let d = dict["minRPM"] as? [String: Double] { minRPM = d }
        if let d = dict["manualRPM"] as? [String: Double] { manualRPM = d }
        if let n = dict["interval"] as? NSNumber { interval = n.doubleValue }
    }
}

/// 温度曲线:多点分段线性插值(两点直线的超集)
public enum FanCurve {
    public static func target(temp: Double, tempStart: Double, tempFull: Double, lo: Double, hi: Double) -> Double {
        guard tempFull > tempStart else { return hi }
        let t = (temp - tempStart) / (tempFull - tempStart)
        let clamped = min(max(t, 0), 1)
        return lo + (hi - lo) * clamped
    }

    /// 多点曲线:按温度分段线性插值,首尾钳制
    public static func target(points: [CurvePoint], temp: Double) -> Double {
        let pts = points.sorted { $0.temp < $1.temp }
        guard let first = pts.first, let last = pts.last else { return 0 }
        if temp <= first.temp { return first.rpm }
        if temp >= last.temp { return last.rpm }
        for i in 1..<pts.count where temp <= pts[i].temp {
            let a = pts[i - 1], b = pts[i]
            let f = (temp - a.temp) / max(0.001, b.temp - a.temp)
            return a.rpm + (b.rpm - a.rpm) * f
        }
        return last.rpm
    }
}

/// 简单日志器(带 1MB 截断)
public final class SimpleLogger {
    private let path: String
    private let queue = DispatchQueue(label: "macfan.log")

    public init(path: String = Paths.logFile) {
        self.path = path
    }

    public func log(_ msg: String) {
        let line = "\(Self.timestamp()) \(msg)\n"
        queue.sync {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: path)[.size]) as? Int, size > 1_048_576 {
                try? fm.removeItem(atPath: path)
            }
            try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                    withIntermediateDirectories: true)
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: URL(fileURLWithPath: path))
            }
        }
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: Date())
    }
}
