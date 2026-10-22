import Foundation

/// 一个温度传感器读数
public struct SensorReading {
    public let key: String
    public let value: Double
    public var label: String { SensorNames.label(for: key) }
}

public enum SensorNames {
    /// 常见键的中文名;未收录的按前缀推断,再退回原始键名
    static let known: [String: String] = [
        "TC0P": "CPU 邻近", "TC0D": "CPU 核心", "TC0E": "CPU 核心", "TC0F": "CPU 核心",
        "TC0H": "CPU 散热片",
        "TCMz": "CPU 峰值", "TCMb": "CPU 平均",
        "TG0P": "GPU 邻近", "TG0D": "GPU 核心", "TG0H": "GPU 散热片", "TG1D": "GPU 2 核心",
        "Tm0P": "内存", "TMVR": "内存 VRM", "Ts0S": "掌托左", "Ts1S": "掌托右",
        "TaLP": "环境", "TAOL": "环境", "TB0T": "电池 1", "TB1T": "电池 2", "TB2T": "电池 3",
        "TN0D": "北桥", "TP0P": "电源", "TA0p": "环境",
        "TH0a": "出风口 a", "TH0b": "出风口 b", "TH1a": "出风口 c", "TH1b": "出风口 d",
        "TM0A": "内存 A", "TW0P": "Airport 卡",
    ]

    static let prefixes: [(String, String)] = [
        ("TC", "CPU"), ("Tp", "CPU"), ("TG", "GPU"), ("Tg", "GPU"),
        ("TM", "内存"), ("Tm", "内存"), ("TB", "电池"), ("TA", "环境"), ("Ta", "环境"),
        ("TP", "供电"), ("TD", "二极管"), ("TH", "散热片"), ("Ts", "掌托"), ("TN", "北桥"),
        ("TW", "无线"), ("TI", "Thunderbolt"), ("TL", " Lightning"),
    ]

    public static func label(for key: String) -> String {
        if let n = known[key] { return n }
        for (p, name) in prefixes where key.hasPrefix(p) {
            return "\(name) \(key.dropFirst(2))"
        }
        return key
    }
}

public extension SMC {
    /// 读取全部温度类传感器(T 开头、可解码、数值合理),按温度降序。
    /// cachedKeys 传入预枚举的键列表,避免守护进程轮询时反复全量枚举。
    func readTemperatures(cachedKeys: [SMCKey]? = nil) -> [SensorReading] {
        var result = [SensorReading]()
        for k in cachedKeys ?? allKeys() {
            let name = k.description
            guard name.hasPrefix("T") else { continue }
            guard let info = try? keyInfo(k) else { continue }
            let type = info.typeName.trimmingCharacters(in: .whitespaces)
            guard ["flt", "sp78", "fp5f", "sp5a", "fpe2", "ioft"].contains(type) else { continue }
            guard let d = try? read(k) else { continue }
            guard let v = SMCValue.decode(d, typeName: info.typeName).doubleValue else { continue }
            guard v > 0, v < 110 else { continue }
            result.append(SensorReading(key: name, value: v))
        }
        return result.sorted { $0.value > $1.value }
    }

    /// 默认控制传感器:CPU 核心(TC 簇 + Tp 系列)+ CPU 峰值 + GPU(取最大值作为控制温度)
    static func defaultControlSensors(for keys: [String]) -> [String] {
        let coreKeys = keys.filter { k in
            k.hasPrefix("Tp")
                || k.range(of: "^TC\\d\\d$", options: .regularExpression) != nil
        }
        var selected = coreKeys
        if keys.contains("TCMz") { selected.append("TCMz") }
        else if keys.contains("TCMb") { selected.append("TCMb") }
        else if keys.contains("TC0P") { selected.append("TC0P") }
        else if keys.contains("TC0D") { selected.append("TC0D") }
        if keys.contains("TC0P") && !coreKeys.isEmpty && !keys.contains("TCMz") && !keys.contains("TCMb") {
            selected.append("TC0P")
        }
        let gpu = keys.filter { $0.range(of: "^TG[0-9]", options: .regularExpression) != nil }
        selected.append(contentsOf: gpu)
        if selected.isEmpty {
            return Array(keys.filter { $0.hasPrefix("T") }.prefix(8))
        }
        return selected
    }
}
