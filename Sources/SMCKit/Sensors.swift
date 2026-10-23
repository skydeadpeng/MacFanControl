import Foundation

/// 一个温度传感器读数
public struct SensorReading {
    public let key: String
    public let value: Double
    public var label: String { SensorNames.label(for: key) }
}

public enum SensorNames {
    /// 常见键的中文名(社区数据整理,覆盖 Apple Silicon 与主流 Intel 机型);未收录的按前缀推断
    static let known: [String: String] = [
        // CPU(Apple Silicon 簇/峰值/邻近)
        "TCMz": "CPU 峰值", "TCMb": "CPU 平均", "TCMc": "CPU P核峰值",
        // CPU(Intel 经典)
        "TC0P": "CPU 邻近", "TC0D": "CPU 核心", "TC0E": "CPU 核心", "TC0F": "CPU 核心",
        "TC0H": "CPU 散热片", "TC0C": "CPU 核心", "TC1C": "CPU 核心1", "TC2C": "CPU 核心2",
        "TC3C": "CPU 核心3", "TC4C": "CPU 核心4", "TC5C": "CPU 核心5", "TC6C": "CPU 核心6",
        "TC7C": "CPU 核心7", "TC8C": "CPU 核心8", "TCSA": "CPU 系统代理",
        // GPU
        "TG0P": "GPU 邻近", "TG0D": "GPU 核心", "TG0H": "GPU 散热片", "TG1D": "GPU2 核心",
        "TG1P": "GPU2 邻近",
        // 内存/主板
        "Tm0P": "内存", "TM0P": "内存", "TM0A": "内存 A", "TM0B": "内存 B", "TMVR": "内存 VRM",
        "TN0D": "北桥", "TN1D": "北桥2", "TS0P": "南桥",
        // 电池/电源
        "TB0T": "电池 1", "TB1T": "电池 2", "TB2T": "电池 3", "TB3T": "电池 4",
        "TP0P": "电源", "TP1P": "电源2", "TPCD": "电源二极管",
        // 环境/外壳
        "TAOL": "环境", "TaLP": "环境", "TA0P": "环境", "TA1P": "环境2", "TaSP": "环境(睡眠)",
        "Ts0S": "掌托左", "Ts1S": "掌托右", "Ts0P": "掌托", "Ts1P": "掌托2",
        "TCXC": "扩充槽",
        // 存储/其他
        "TH0P": "HDD", "TH0a": "出风口 a", "TH0b": "出风口 b", "TH1a": "出风口 c", "TH1b": "出风口 d",
        "TH0x": "出风口 e",
        "TW0P": "无线网卡", "TL0P": "雷电", "TI0P": "Thunderbolt", "TI1P": "Thunderbolt2",
        "TD0P": "SSD 控制", "TDRD": "SSD 二极管", "TD3P": "NAND",
        "TO0P": "光学驱动", "TVEP": "视频", "TVM0": "显存",
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
