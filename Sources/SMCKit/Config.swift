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

/// 定时夜间模式(时间窗内改用指定预设曲线,夜间降噪)
public struct NightMode: Codable, Equatable {
    public var enabled: Bool = false
    public var start: Int = 23 * 60      // 开始时间(当天分钟数,23:00)
    public var end: Int = 7 * 60         // 结束时间(07:00,可跨午夜)
    public var preset: String = "quiet"  // quiet | balanced | turbo

    public init() {}

    enum CodingKeys: String, CodingKey { case enabled, start, end, preset }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        start = try c.decodeIfPresent(Int.self, forKey: .start) ?? 23 * 60
        end = try c.decodeIfPresent(Int.self, forKey: .end) ?? 7 * 60
        preset = try c.decodeIfPresent(String.self, forKey: .preset) ?? "quiet"
    }

    public init?(dict: [String: Any]) {
        guard !dict.isEmpty else { return nil }
        self.init()
        if let v = dict["enabled"] as? Bool { enabled = v }
        if let n = dict["start"] as? NSNumber { start = n.intValue }
        if let n = dict["end"] as? NSNumber { end = n.intValue }
        if let v = dict["preset"] as? String { preset = v }
    }

    /// 时间窗是否生效(支持跨午夜,如 23:00–07:00)
    public func windowActive(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        let m = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        if start == end { return true }
        if start < end { return m >= start && m < end }
        return m >= start || m < end
    }

    public var timeText: String {
        func mm(_ v: Int) -> String { String(format: "%02d:%02d", v / 60 % 24, v % 60) }
        return "\(mm(start))–\(mm(end))"
    }
}

/// 控制配置(JSON 持久化)
public struct Config: Codable {
    public var enabled: Bool = true
    public var mode: String = "auto"              // auto | manual
    public var sensors: [String]? = nil           // nil = 自动选择 CPU/GPU
    public var tempStart: Double = 70             // °C,开始升速(兼容旧版两点曲线)
    public var tempFull: Double = 95              // °C,全速
    public var curves: [String: [CurvePoint]] = [:]   // 风扇序号 -> 多点曲线(空=用上面两点)
    public var batteryCurves: [String: [CurvePoint]] = [:]  // 用电池时的曲线(空=沿用 curves)
    public var nightMode: NightMode? = nil        // 定时夜间模式
    public var minRPM: [String: Double] = [:]     // 风扇序号 -> 自动曲线下限
    public var manualRPM: [String: Double] = [:]  // 风扇序号 -> 手动转速
    public var interval: Double = 2               // 秒

    public init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, mode, sensors, tempStart, tempFull, curves, batteryCurves, nightMode, minRPM, manualRPM, interval
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? "auto"
        sensors = try c.decodeIfPresent([String].self, forKey: .sensors)
        tempStart = try c.decodeIfPresent(Double.self, forKey: .tempStart) ?? 70
        tempFull = try c.decodeIfPresent(Double.self, forKey: .tempFull) ?? 95
        curves = try c.decodeIfPresent([String: [CurvePoint]].self, forKey: .curves) ?? [:]
        batteryCurves = try c.decodeIfPresent([String: [CurvePoint]].self, forKey: .batteryCurves) ?? [:]
        nightMode = try c.decodeIfPresent(NightMode.self, forKey: .nightMode)
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
        if let v = patch.batteryCurves { batteryCurves = v }
        if let v = patch.nightMode { nightMode = v }
        if let v = patch.minRPM { minRPM.merge(v) { _, new in new } }
        if let v = patch.manualRPM { manualRPM.merge(v) { _, new in new } }
        if let v = patch.interval { interval = min(max(v, 1), 10) }
    }

    /// 预设曲线的两点范围(与 GUI 预设一致)
    public static func presetRange(_ name: String) -> (start: Double, full: Double) {
        switch name {
        case "quiet": return (80, 100)
        case "turbo": return (55, 85)
        default: return (70, 95)
        }
    }

    /// 当前应采用的曲线集合:夜间窗口优先(走预设两点),其次电池曲线,最后常规曲线
    public func effectiveCurves(onAC: Bool, now: Date = Date()) -> [String: [CurvePoint]] {
        if let nm = nightMode, nm.enabled, nm.windowActive(now: now) { return [:] }
        if !onAC, !batteryCurves.isEmpty { return batteryCurves }
        return curves
    }

    /// 夜间模式当前是否生效(独立出来供状态展示)
    public func nightActive(now: Date = Date()) -> Bool {
        guard let nm = nightMode else { return false }
        return nm.enabled && nm.windowActive(now: now)
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
    public var batteryCurves: [String: [CurvePoint]]?
    public var nightMode: NightMode?
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
        if let d = dict["batteryCurves"] as? [String: [[Double]]] {
            batteryCurves = d.mapValues { pts in
                pts.compactMap { p in p.count == 2 ? CurvePoint(temp: p[0], rpm: p[1]) : nil }
            }
        }
        if let d = dict["nightMode"] as? [String: Any] { nightMode = NightMode(dict: d) }
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
