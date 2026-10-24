import SwiftUI
import AppKit
import Charts
import Combine
import UserNotifications
import WidgetKit
import SMCKit

// MARK: - 数据模型

/// 历史曲线点(温度°C、CPU%、风扇RPM,保留约 3 分钟)

/// 轻量双语:按系统首选语言返回中/英文案
enum L {
    static let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
    static func t(_ zh: String, _ en: String) -> String { isChinese ? zh : en }
}

/// 历史曲线点(温度°C、CPU%、GPU%、风扇RPM,保留约 15 分钟,跨重启持久化)
struct HistPoint: Identifiable {
    let id = UUID()
    let t: Date
    let temp: Double
    let cpu: Double
    let gpu: Double
    let rpm: Double
}

struct FanRow: Identifiable {
    let id: Int
    let index: Int
    let rpm: Double
    let min: Double
    let max: Double
    let target: Double
    let written: Double
}

struct SensorRow: Identifiable {
    let id: String
    let key: String
    let value: Double
    var label: String { SensorNames.label(for: key) }
}

final class FanModel: ObservableObject {
    @Published var daemonOnline = false
    @Published var controlled = false
    @Published var controlTemp: Double = 0
    @Published var fans: [FanRow] = []
    @Published var sensors: [SensorRow] = []
    @Published var selectedSensors: Set<String> = []
    @Published var config = Config()
    @Published var busy = false
    @Published var message: String?
    @Published var sys: SystemStats.Snapshot?
    @Published var starting = false
    @Published var history: [HistPoint] = []
    @Published var updateAvailable: String?
    @Published var autoStart: Bool = AutoStart.installed {
        didSet {
            if autoStart { AutoStart.install() } else { AutoStart.uninstall() }
        }
    }
    /// 打开"全部传感器"窗口(由 AppDelegate 注入实现)
    var openSensors: (() -> Void)?
    /// 打开"7 天趋势"窗口
    var openTrend: (() -> Void)?
    /// UI 是否可见(AppDelegate 注入:popover/传感器窗/趋势窗任一在前台)。
    /// 不可见时走轻量采样(不扫进程榜/GPU/磁盘 IO),大幅降低常驻 CPU
    var uiVisible: (() -> Bool)?

    // 高温报警(UserDefaults 持久化)
    @Published var alarmEnabled: Bool = UserDefaults.standard.object(forKey: "alarmEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(alarmEnabled, forKey: "alarmEnabled") }
    }
    @Published var alarmTemp: Double = UserDefaults.standard.object(forKey: "alarmTemp") as? Double ?? 90 {
        didSet { UserDefaults.standard.set(alarmTemp, forKey: "alarmTemp") }
    }
    private var lastAlarmAt = Date.distantPast

    // 电源/夜间状态(来自守护进程,用于徽标展示)
    @Published var onAC = true
    @Published var nightActive = false

    // 菜单栏显示指标(可任选组合,UserDefaults 持久化)
    @Published var titleItems: [String] = UserDefaults.standard.stringArray(forKey: "titleItems") ?? ["temp", "cpu"] {
        didSet { UserDefaults.standard.set(titleItems, forKey: "titleItems") }
    }

    // 今日流量
    @Published var todayIn: UInt64 = 0
    @Published var todayOut: UInt64 = 0
    private var trafficDay = ""
    private var lastTrafficIn: UInt64?
    private var lastTrafficOut: UInt64?
    private var trafficSaveCounter = 0

    private var directReader: DirectReader?
    private let stats = SystemStats()
    private var timer: Timer?
    private var refreshing = false
    private var widgetReloadCounter = 0
    private var tickCount = 0

    /// 菜单栏标题(按自选指标组合渲染;temp/cpu/gpu/mem/net/battery/power)
    var statusText: String {
        var parts: [String] = []
        let items = titleItems.isEmpty ? ["temp", "cpu"] : titleItems
        for it in items {
            switch it {
            case "temp":
                let t = daemonOnline ? controlTemp : (sensors.first?.value ?? 0)
                parts.append(t > 0 ? String(format: "%.0f°", t) : "--°")
            case "cpu":
                if let sys { parts.append(String(format: "%.0f%%", sys.cpuUsage * 100)) }
            case "gpu":
                if let g = sys?.gpuUsage { parts.append("G\(g)%") }
            case "mem":
                if let sys { parts.append("\(L.t("内", "M"))\(Int(sys.memPercent * 100))%") }
            case "net":
                if let sys { parts.append("↓\(Self.shortSpeed(sys.netIn)) ↑\(Self.shortSpeed(sys.netOut))") }
            case "battery":
                if let b = sys?.battery, b.present {
                    parts.append("\(L.t("电", "B"))\(Int(b.percent))\(b.charging ? "+" : "")")
                }
            case "power":
                if let b = sys?.battery, b.present, b.watts >= 0.1 {
                    parts.append(b.chargeIn ? String(format: "+%.1fW", b.watts)
                                            : String(format: "%.1fW", b.watts))
                }
            default:
                break
            }
        }
        return parts.isEmpty ? "--°" : parts.joined(separator: " ")
    }

    static func shortSpeed(_ b: Double) -> String {
        if b >= 1_048_576 { return String(format: "%.1fM", b / 1_048_576) }
        if b >= 1024 { return String(format: "%.0fK", b / 1024) }
        return String(format: "%.0f", max(0, b))
    }

    var hasFans: Bool { !fans.isEmpty }

    init() {
        loadTraffic()
        loadTodayStats()
        loadHistory()
        loadTrend()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.tickCount += 1
            // 面板/窗口都不可见时降频到 3 秒一拍(菜单栏文字 3 秒粒度足够)
            if self.uiVisible?() ?? true || self.tickCount % 2 == 0 {
                self.refresh()
            }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        checkForUpdate()
        // 每 6 小时复查一次新版本
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
        refresh()
    }

    // MARK: 版本检查(GitHub Releases)

    private func checkForUpdate() {
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        guard let url = URL(string: "https://api.github.com/repos/skydeadpeng/MacFanControl/releases/latest") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data,
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return }
            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            if latest.compare(current, options: .numeric) == .orderedDescending {
                DispatchQueue.main.async { self?.updateAvailable = tag }
            }
        }.resume()
    }

    // MARK: 今日统计(温度/CPU/功率峰值 + 用电 Wh,跨天自动清零)

    struct DayStats: Codable {
        var date = ""
        var high = 0.0
        var low = 0.0
        var maxCPU = 0.0
        var maxPower = 0.0       // 放电功率峰值 W
        var maxNetDown = 0.0     // B/s
        var maxNetUp = 0.0
        var whOut = 0.0          // 今日放电电量 Wh
        var whIn = 0.0           // 今日充入电量 Wh
    }

    @Published var day = DayStats()
    private var daySaveCounter = 0

    private func loadTodayStats() {
        guard let data = UserDefaults.standard.data(forKey: "dayStats2"),
              let d = try? JSONDecoder().decode(DayStats.self, from: data),
              d.date == Self.dayString else { return }
        day = d
    }

    private func saveDayStats() {
        if let d = try? JSONEncoder().encode(day) {
            UserDefaults.standard.set(d, forKey: "dayStats2")
        }
    }

    /// 每轮刷新调用:更新峰值并积分电量(1.5s 一拍,W×s/3600=Wh)
    private func updateDayStats(temp: Double, cpu: Double) {
        if day.date != Self.dayString {
            day = DayStats()
            day.date = Self.dayString
        }
        if temp > 1 {
            if temp > day.high { day.high = temp }
            if day.low == 0 || temp < day.low { day.low = temp }
        }
        if cpu > day.maxCPU { day.maxCPU = cpu }
        if let s = sys {
            if !s.battery.chargeIn, s.battery.watts > day.maxPower { day.maxPower = s.battery.watts }
            day.maxNetDown = max(day.maxNetDown, s.netIn)
            day.maxNetUp = max(day.maxNetUp, s.netOut)
            if s.battery.present, s.battery.watts > 0.1 {
                let wh = s.battery.watts * 1.5 / 3600
                if s.battery.chargeIn { day.whIn += wh } else { day.whOut += wh }
            }
        }
        daySaveCounter += 1
        if daySaveCounter % 8 == 0 { saveDayStats() }
    }

    private static var dayString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    func refresh() {
        let s = stats.sample(full: uiVisible?() ?? true)
        sys = s
        accumulateTraffic(s)
        checkBattery(s.battery)
        // 桌面小组件:FanBar 在前台运行时约每分钟推一次新数据
        widgetReloadCounter += 1
        if widgetReloadCounter % 40 == 0 {
            WidgetCenter.shared.reloadAllTimelines()
        }
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            let resp = FanClient.status()
            if let r = resp, r["ok"] as? Bool == true {
                DispatchQueue.main.async {
                    self.refreshing = false
                    self.applyDaemonStatus(r)
                }
            } else {
                if self.directReader == nil { self.directReader = DirectReader() }
                let reader = self.directReader
                let temps = reader?.temps() ?? []
                let fans = reader?.fans() ?? []
                DispatchQueue.main.async {
                    self.refreshing = false
                    self.applyDirect(temps: temps, fans: fans)
                }
            }
        }
    }

    // MARK: 状态解析

    private func applyDaemonStatus(_ resp: [String: Any]) {
        daemonOnline = true
        if resp["starting"] as? Bool == true {
            starting = true
            controlled = false
            return
        }
        starting = false
        controlled = resp["controlled"] as? Bool ?? false
        controlTemp = resp["controlTemp"] as? Double ?? 0
        onAC = resp["onAC"] as? Bool ?? true
        nightActive = resp["nightActive"] as? Bool ?? false

        fans = ((resp["fans"] as? [[String: Any]]) ?? []).map {
            FanRow(id: $0["index"] as? Int ?? 0,
                   index: $0["index"] as? Int ?? 0,
                   rpm: $0["rpm"] as? Double ?? 0,
                   min: $0["min"] as? Double ?? 0,
                   max: $0["max"] as? Double ?? 0,
                   target: $0["written"] as? Double ?? ($0["target"] as? Double ?? 0),
                   written: $0["written"] as? Double ?? 0)
        }

        var rows = [SensorRow]()
        if let temps = resp["temps"] as? [String: Double] {
            rows = temps.map { SensorRow(id: $0.key, key: $0.key, value: $0.value) }
                .sorted { $0.value > $1.value }
        }
        sensors = rows
        selectedSensors = Set((resp["sensorsSelected"] as? [String]) ?? [])

        if let c = resp["config"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: c),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            config = cfg
            if selectedSensors.isEmpty {
                selectedSensors = Set(SMC.defaultControlSensors(for: rows.map(\.key)))
            }
        }
        appendHistory(temp: controlTemp, cpu: sys?.cpuUsage ?? 0, rpm: fans.map(\.rpm).max() ?? 0)
        checkAlarm()
        checkFanHealth()
    }

    // MARK: 风扇异常告警(转速骤降为 0 且目标不为 0,持续约 5 秒即通知,1 小时冷却)

    private var fanStallTicks: [Int: Int] = [:]
    private var lastFanAlertAt = Date.distantPast

    private func checkFanHealth() {
        guard controlled, !fans.isEmpty else {
            fanStallTicks.removeAll()
            return
        }
        for f in fans {
            let stalled = f.rpm < max(400, f.min * 0.3) && max(f.target, f.written) > 1000
            fanStallTicks[f.index, default: 0] = stalled ? fanStallTicks[f.index, default: 0] + 1 : 0
        }
        let bad = fanStallTicks.filter { $0.value >= 3 }.keys.sorted()
        if !bad.isEmpty, Date().timeIntervalSince(lastFanAlertAt) > 3600 {
            lastFanAlertAt = Date()
            let which = bad.map { String($0 + 1) }.joined(separator: "、")
            notify(L.t("风扇可能故障", "Possible fan failure"),
                   L.t("风扇 \(which) 转速接近 0,但目标转速不为 0;若持续出现建议送修检查。",
                       "Fan \(which) RPM near 0 while target is high. Consider a hardware check."))
        }
    }

    private func applyDirect(temps: [SensorReading], fans: [FanInfo]) {
        daemonOnline = false
        controlled = false
        starting = false
        sensors = temps.map { SensorRow(id: $0.key, key: $0.key, value: $0.value) }
            .sorted { $0.value > $1.value }
        selectedSensors = Set(SMC.defaultControlSensors(for: temps.map(\.key)))
        controlTemp = Self.controlTemp(temps: temps, selected: selectedSensors)
        self.fans = fans.map {
            FanRow(id: $0.index, index: $0.index, rpm: $0.rpm, min: $0.min,
                   max: $0.max, target: $0.target, written: $0.target)
        }
        appendHistory(temp: controlTemp, cpu: sys?.cpuUsage ?? 0, rpm: self.fans.map(\.rpm).max() ?? 0)
        checkAlarm()
    }

    private func appendHistory(temp: Double, cpu: Double, rpm: Double) {
        // 轻量采样期 GPU 为 nil,沿用上次值,曲线不断崖
        if let g = sys?.gpuUsage { lastKnownGPU = Double(g) }
        history.append(HistPoint(t: Date(), temp: temp, cpu: cpu * 100, gpu: lastKnownGPU, rpm: rpm))
        if history.count > 600 { history.removeFirst(history.count - 600) }   // 1.5s × 600 ≈ 15 分钟
        updateDayStats(temp: temp, cpu: cpu * 100)
        updateHourlyTrend(temp: temp, cpu: cpu * 100, gpu: lastKnownGPU, fanRPM: rpm)
        histSaveCounter += 1
        if histSaveCounter % 20 == 0 { persistHistoryAndTrend() }
    }

    private var lastKnownGPU = 0.0

    // MARK: 历史与 7 天逐小时趋势持久化(跨重启连续)

    private var histSaveCounter = 0
    private static var historyFile: String { userSupportDir + "/history.json" }
    private static var trendFile: String { userSupportDir + "/trends.json" }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.historyFile)),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[Double]] else { return }
        let cutoff = Date().addingTimeInterval(-930)
        history = arr.compactMap { row in
            guard row.count >= 4 else { return nil }
            let t = Date(timeIntervalSince1970: row[0])
            guard t > cutoff else { return nil }
            return HistPoint(t: t, temp: row[1], cpu: row[2],
                             gpu: row.count > 4 ? row[4] : 0, rpm: row[3])
        }
    }

    private func persistHistoryAndTrend() {
        let rows = history.map { [$0.t.timeIntervalSince1970, $0.temp, $0.cpu, $0.rpm, $0.gpu] }
        if let d = try? JSONSerialization.data(withJSONObject: rows) {
            try? d.write(to: URL(fileURLWithPath: Self.historyFile))
        }
        if let d = try? JSONSerialization.data(withJSONObject: hourlyTrend) {
            try? d.write(to: URL(fileURLWithPath: Self.trendFile))
        }
    }

    @Published var hourlyTrend: [[String: Any]] = []   // [{h, min, max, sum, cnt, fan, cpuSum, gpuSum}]
    private var lastTrendHour = -1

    private func loadTrend() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.trendFile)),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        let cutoff = Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970
        hourlyTrend = arr.filter { ($0["h"] as? Double ?? 0) > cutoff }
        lastTrendHour = Int(hourlyTrend.last?["h"] as? Double ?? 0) / 3600
    }

    private func updateHourlyTrend(temp: Double, cpu: Double, gpu: Double, fanRPM: Double) {
        let hourTS = Int(Date().timeIntervalSince1970 / 3600) * 3600
        if lastTrendHour != hourTS / 3600 {
            lastTrendHour = hourTS / 3600
        }
        if var bucket = hourlyTrend.last, (bucket["h"] as? Double) == Double(hourTS) {
            hourlyTrend.removeLast()
            bucket["min"] = min(bucket["min"] as? Double ?? temp, temp)
            bucket["max"] = max(bucket["max"] as? Double ?? temp, temp)
            bucket["sum"] = (bucket["sum"] as? Double ?? 0) + temp
            bucket["cnt"] = (bucket["cnt"] as? Double ?? 0) + 1
            bucket["fan"] = max(bucket["fan"] as? Double ?? 0, fanRPM)
            bucket["cpuSum"] = (bucket["cpuSum"] as? Double ?? 0) + cpu
            bucket["gpuSum"] = (bucket["gpuSum"] as? Double ?? 0) + gpu
            hourlyTrend.append(bucket)
        } else {
            hourlyTrend.append(["h": Double(hourTS), "min": temp, "max": temp,
                                "sum": temp, "cnt": 1.0, "fan": fanRPM,
                                "cpuSum": cpu, "gpuSum": gpu])
        }
        if hourlyTrend.count > 7 * 24 { hourlyTrend.removeFirst(hourlyTrend.count - 7 * 24) }
    }

    // MARK: 快捷操作(右键菜单用)

    /// 应急:全部风扇拉满
    func boostAllFans() {
        config.mode = "manual"
        for f in fans { config.manualRPM["\(f.index)"] = f.max }
        send(patch: ["mode": "manual", "manualRPM": config.manualRPM])
    }

    /// 单个风扇全速
    func boostFan(_ index: Int) {
        guard fans.contains(where: { $0.index == index }) else { return }
        config.mode = "manual"
        if let f = fans.first(where: { $0.index == index }) {
            config.manualRPM["\(index)"] = f.max
        }
        send(patch: ["mode": "manual", "manualRPM": config.manualRPM])
    }

    /// 恢复自动曲线
    func restoreAutoCurve() {
        config.mode = "auto"
        send(patch: ["mode": "auto"])
    }

    /// 复制当前状态一行文本
    func copyStatus() {
        var parts = [String(format: "温度 %.1f°C", controlTemp)]
        if let s = sys {
            parts.append(String(format: "CPU %.0f%%", s.cpuUsage * 100))
            parts.append(String(format: "内存 %.0f%%", s.memPercent * 100))
            parts.append("网 ↓\(SystemStats.Snapshot.speed(s.netIn)) ↑\(SystemStats.Snapshot.speed(s.netOut))")
        }
        for f in fans { parts.append(String(format: "风扇%d %.0frpm", f.index + 1, f.rpm)) }
        let text = parts.joined(separator: " · ")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        message = "已复制状态"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.message = nil }
    }

    // MARK: 电池充电提醒(充到 80% 提醒一次;拔电或降到 60% 以下重新武装,避免快充跨窗口漏报)

    private var chargeAlertArmed = true
    private var lastLowNotify = Date.distantPast

    private func checkBattery(_ b: SystemStats.BatteryInfo) {
        guard b.present else { return }
        if !b.charging || b.percent < 60 { chargeAlertArmed = true }
        if b.charging && chargeAlertArmed && b.percent >= 80 {
            chargeAlertArmed = false
            notify(L.t("⚡ 已充到 \(Int(b.percent))%", "⚡ Charged to \(Int(b.percent))%"),
                   L.t("长时间插电建议拔掉电源,保护电池健康", "Unplug to protect battery health for long sessions"))
        }
        if !b.onAC && b.percent <= 20 && Date().timeIntervalSince(lastLowNotify) > 1800 {
            lastLowNotify = Date()
            notify(L.t("🔋 电量 \(Int(b.percent))%", "🔋 Battery \(Int(b.percent))%"),
                   L.t("电量不足,请尽快连接电源", "Low battery — connect power soon"))
        }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: "battery-\(Int(Date().timeIntervalSince1970))",
                                       content: content, trigger: nil))
    }

    // MARK: 诊断导出(一键收集日志与配置,便于反馈问题)

    func exportDiagnostics() {
        var text = "MacFanControl 诊断包 \(Date())\n系统: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        text += "\n===== 守护进程状态 =====\n"
        if let resp = FanClient.status(),
           let data = try? JSONSerialization.data(withJSONObject: resp, options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            text += s
        } else {
            text += "(守护进程未运行)"
        }
        text += "\n\n===== 守护进程日志(末 150 行)=====\n"
        if let log = try? String(contentsOfFile: Paths.logFile, encoding: .utf8) {
            text += log.split(separator: "\n").suffix(150).joined(separator: "\n")
        } else {
            text += "(无)"
        }
        text += "\n\n===== 守护进程配置 =====\n"
        text += (try? String(contentsOfFile: Paths.configFile, encoding: .utf8)) ?? "(无)"
        text += "\n\n===== GUI 生命周期日志 =====\n"
        let lifeLog = NSHomeDirectory() + "/Library/Logs/macfancontrol-fanbar.log"
        text += (try? String(contentsOfFile: lifeLog, encoding: .utf8)) ?? "(无)"

        let name = "MacFanControl-诊断-\(Int(Date().timeIntervalSince1970)).txt"
        let path = NSHomeDirectory() + "/Desktop/" + name
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            message = "诊断包已导出到桌面: \(name)"
        } catch {
            message = "导出失败: \(error.localizedDescription)"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.message = nil }
    }

    // MARK: 数据导出 CSV(近 15 分钟明细 + 7 天小时均值 + 今日统计)

    func exportCSV() {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines: [String] = []
        lines.append("# MacFanControl 数据导出 \(f.string(from: Date()))")
        lines.append("#")
        lines.append("# 今日统计: 最高 \(String(format: "%.1f", day.high))°C / 最低 \(String(format: "%.1f", day.low))°C / CPU峰值 \(Int(day.maxCPU))% / 放电峰值 \(String(format: "%.1f", day.maxPower))W / 用电 \(String(format: "%.1f", day.whOut))Wh / 充入 \(String(format: "%.1f", day.whIn))Wh")
        lines.append("# 今日流量: ↓\(SystemStats.Snapshot.trafficSize(todayIn)) ↑\(SystemStats.Snapshot.trafficSize(todayOut))")
        lines.append("时间,温度°C,CPU%,GPU%,风扇RPM,来源")
        for p in history {
            lines.append("\(f.string(from: p.t)),\(String(format: "%.1f", p.temp)),\(String(format: "%.0f", p.cpu)),\(String(format: "%.0f", p.gpu)),\(String(format: "%.0f", p.rpm)),实时")
        }
        let hf = DateFormatter()
        hf.dateFormat = "MM-dd HH:00"
        for b in hourlyTrend {
            guard let h = b["h"] as? Double else { continue }
            let cnt = max(1.0, b["cnt"] as? Double ?? 1)
            let avg = (b["sum"] as? Double ?? 0) / cnt
            let cpu = (b["cpuSum"] as? Double ?? 0) / cnt
            let gpu = (b["gpuSum"] as? Double ?? 0) / cnt
            lines.append("\(hf.string(from: Date(timeIntervalSince1970: h))),\(String(format: "%.1f", avg)),\(String(format: "%.0f", cpu)),\(String(format: "%.0f", gpu)),\(String(format: "%.0f", b["fan"] as? Double ?? 0)),小时均值")
        }
        let name = "MacFanControl-数据-\(Int(Date().timeIntervalSince1970)).csv"
        let path = NSHomeDirectory() + "/Desktop/" + name
        do {
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            message = "数据已导出到桌面: \(name)"
        } catch {
            message = "导出失败: \(error.localizedDescription)"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.message = nil }
    }

    // MARK: 进程管理(右击 Top 进程可结束)

    func terminateProcess(_ p: SystemStats.ProcUsage, force: Bool) {
        let signalNum: Int32 = force ? SIGKILL : SIGTERM
        if kill(p.pid, signalNum) == 0 {
            message = force ? "已强杀 \(p.name)" : "已发送退出信号给 \(p.name)"
        } else {
            message = "结束 \(p.name) 失败:\(errno == EPERM ? "权限不足(系统进程)" : String(cString: strerror(errno)))"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.message = nil
            self?.refresh()
        }
    }

    // MARK: 今日流量(按网卡累计字节差值累加,跨天清零,定期落盘)

    private static var userSupportDir: String {
        NSHomeDirectory() + "/Library/Application Support/MacFanControl"
    }
    private static var trafficFile: String { userSupportDir + "/traffic.json" }
    private static var trafficPathDate: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func loadTraffic() {
        trafficDay = Self.trafficPathDate
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.trafficFile)),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["date"] as? String == trafficDay else { return }
        todayIn = (obj["in"] as? NSNumber)?.uint64Value ?? 0
        todayOut = (obj["out"] as? NSNumber)?.uint64Value ?? 0
    }

    private func accumulateTraffic(_ snap: SystemStats.Snapshot) {
        let day = Self.trafficPathDate
        if day != trafficDay {
            trafficDay = day
            todayIn = 0
            todayOut = 0
        }
        if let li = lastTrafficIn, let lo = lastTrafficOut {
            if snap.netInTotal >= li { todayIn += snap.netInTotal - li }
            if snap.netOutTotal >= lo { todayOut += snap.netOutTotal - lo }
        }
        lastTrafficIn = snap.netInTotal
        lastTrafficOut = snap.netOutTotal
        trafficSaveCounter += 1
        if trafficSaveCounter % 20 == 0 { saveTraffic() }
    }

    private func saveTraffic() {
        let obj: [String: Any] = ["date": trafficDay, "in": todayIn, "out": todayOut]
        try? FileManager.default.createDirectory(atPath: Self.userSupportDir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: obj) {
            try? d.write(to: URL(fileURLWithPath: Self.trafficFile))
        }
    }

    // MARK: 高温报警(10 分钟冷却,避免轰炸)

    private func checkAlarm() {
        guard alarmEnabled, controlTemp >= alarmTemp else { return }
        guard Date().timeIntervalSince(lastAlarmAt) > 600 else { return }
        lastAlarmAt = Date()
        let content = UNMutableNotificationContent()
        content.title = L.t("温度过高", "High temperature")
        content.body = String(format: L.t("控制温度已达 %.0f°C(报警阈值 %.0f°C),风扇正按曲线散热",
                                          "Control temp %.0f°C (alert at %.0f°C), fans ramping per curve"),
                              controlTemp, alarmTemp)
        content.sound = .default
        let request = UNNotificationRequest(identifier: "temp-\(Int(Date().timeIntervalSince1970))",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func controlTemp(temps: [SensorReading], selected: Set<String>) -> Double {
        temps.filter { selected.contains($0.key) }.map(\.value).max() ?? 0
    }

    // MARK: 配置下发

    private var pendingSend: DispatchWorkItem?

    /// 防抖下发(拖动滑条时避免每帧一次请求)
    func send(patch: [String: Any]) {
        pendingSend?.cancel()
        busy = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let resp = FanClient.set(config: patch)
            DispatchQueue.main.async {
                self.busy = false
                if let resp = resp, resp["ok"] as? Bool == true {
                    self.applyDaemonStatus(resp)
                    self.message = nil
                } else {
                    self.message = "下发失败:守护进程未响应"
                }
            }
        }
        pendingSend = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func setEnabled(_ on: Bool) {
        config.enabled = on
        send(patch: ["enabled": on])
    }

    func setMode(_ manual: Bool) {
        config.mode = manual ? "manual" : "auto"
        send(patch: ["mode": manual ? "manual" : "auto"])
    }

    func applyPreset(start: Double, full: Double) {
        config.mode = "auto"
        config.tempStart = start
        config.tempFull = full
        config.curves = [:]   // 预设回到两点直线
        send(patch: ["mode": "auto", "tempStart": start, "tempFull": full, "curves": [String: [[Double]]]()])
    }

    // MARK: 多点曲线(插电/电池两套)

    /// 取某风扇当前曲线;battery=true 取电池曲线(未设置返回空,界面提示"沿用插电")
    func curvePoints(fanIndex: Int?, battery: Bool = false) -> [CurvePoint] {
        let store = battery ? config.batteryCurves : config.curves
        if let i = fanIndex {
            if let pts = store[String(i)], pts.count >= 2 {
                return pts.sorted { $0.temp < $1.temp }
            }
            if battery { return [] }
            if let f = fans.first(where: { $0.index == i }) {
                return [CurvePoint(temp: config.tempStart, rpm: f.min),
                        CurvePoint(temp: config.tempFull, rpm: f.max)]
            }
        }
        if let pts = store[""], pts.count >= 2 { return pts.sorted { $0.temp < $1.temp } }
        if battery { return [] }
        let lo = fans.map(\.min).max() ?? 1500
        let hi = fans.map(\.max).max() ?? 5500
        return [CurvePoint(temp: config.tempStart, rpm: lo),
                CurvePoint(temp: config.tempFull, rpm: hi)]
    }

    /// 写曲线(fanIndex=nil 写到全部风扇)
    func setCurvePoints(_ pts: [CurvePoint], fanIndex: Int?, battery: Bool = false) {
        let keys = fanIndex.map { [String($0)] } ?? fans.map { String($0.index) }
        let sorted = pts.count >= 2 ? pts.sorted { $0.temp < $1.temp } : []
        if battery {
            var curves = config.batteryCurves
            for k in keys { curves[k] = sorted }
            config.batteryCurves = curves
            send(patch: ["batteryCurves": curves.mapValues { $0.map { [$0.temp, $0.rpm] } }])
        } else {
            var curves = config.curves
            for k in keys { curves[k] = sorted }
            config.curves = curves
            send(patch: ["curves": curves.mapValues { $0.map { [$0.temp, $0.rpm] } }])
        }
    }

    /// 把插电曲线复制为电池曲线(起点)
    func copyCurvesToBattery() {
        config.batteryCurves = config.curves
        send(patch: ["batteryCurves": config.batteryCurves.mapValues { $0.map { [$0.temp, $0.rpm] } }])
    }

    func clearBatteryCurves() {
        config.batteryCurves = [:]
        send(patch: ["batteryCurves": [String: [[Double]]]()])
    }

    // MARK: 夜间模式

    func setNightMode(_ nm: NightMode) {
        config.nightMode = nm
        send(patch: ["nightMode": ["enabled": nm.enabled, "start": nm.start,
                                   "end": nm.end, "preset": nm.preset]])
    }

    func setCurve(start: Double, full: Double) {
        config.tempStart = start
        config.tempFull = full
        send(patch: ["tempStart": start, "tempFull": full])
    }

    func setManualRPM(_ rpm: Double, fan: Int) {
        config.manualRPM["\(fan)"] = rpm
        send(patch: ["manualRPM": config.manualRPM])
    }

    func setMinRPM(_ rpm: Double, fan: Int) {
        config.minRPM["\(fan)"] = rpm
        send(patch: ["minRPM": config.minRPM])
    }

    func toggleSensor(_ key: String, on: Bool) {
        if on { selectedSensors.insert(key) } else { selectedSensors.remove(key) }
        if selectedSensors.count == 0 { selectedSensors.insert(key) ; return }
        config.sensors = Array(selectedSensors)
        send(patch: ["sensors": Array(selectedSensors).sorted()])
    }

    func restore() {
        config.enabled = false
        controlled = false
        send(patch: ["enabled": false])
        FanClient.request(FanProtocol.makeRequest(cmd: "restore"))
        refresh()
    }

    // MARK: 守护进程安装

    static func fanctlPath() -> String? {
        if let bundled = Bundle.main.url(forResource: "fanctl", withExtension: nil) {
            return bundled.path
        }
        if FileManager.default.fileExists(atPath: Paths.daemonBinary) {
            return Paths.daemonBinary
        }
        // 开发模式:App 与 .build 同级目录
        let dev = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("mac-fan-control/.build/release/fanctl").path
        if FileManager.default.fileExists(atPath: dev) { return dev }
        let dev2 = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(".build/release/fanctl").path
        if FileManager.default.fileExists(atPath: dev2) { return dev2 }
        return nil
    }

    func installDaemon() {
        guard let path = Self.fanctlPath() else {
            message = "找不到 fanctl 可执行文件(请用 build.sh 打包)"
            return
        }
        busy = true
        message = "等待管理员授权…"
        let script = "do shell script \"\\\"\(path)\\\" install\" with administrator privileges with prompt \"安装 MacFanControl 风扇守护进程\""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = Self.runOSA(script)
            DispatchQueue.main.async {
                self?.busy = false
                self?.message = ok ? nil : "安装失败或已取消"
                self?.refresh()
            }
        }
    }

    func uninstallDaemon() {
        let path = Self.fanctlPath() ?? Paths.daemonBinary
        guard FileManager.default.fileExists(atPath: path) else {
            message = "找不到 fanctl"
            return
        }
        busy = true
        message = "等待管理员授权…"
        let script = "do shell script \"\\\"\(path)\\\" uninstall\" with administrator privileges with prompt \"卸载 MacFanControl 风扇守护进程\""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = Self.runOSA(script)
            DispatchQueue.main.async {
                self?.busy = false
                self?.message = ok ? "已卸载" : "卸载失败或已取消"
                self?.refresh()
            }
        }
    }

    @discardableResult
    static func runOSA(_ script: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch { return false }
    }
}

/// 守护进程离线时的直读(缓存键列表,避免每次全量枚举)
final class DirectReader {
    private let smc: SMC
    private let tempKeys: [SMCKey]

    init?() {
        guard let s = try? SMC() else { return nil }
        smc = s
        tempKeys = s.allKeys().filter { $0.description.hasPrefix("T") }
    }

    func temps() -> [SensorReading] {
        smc.readTemperatures(cachedKeys: tempKeys)
    }

    func fans() -> [FanInfo]? {
        try? smc.readFans()
    }
}

/// 开机自启 + 崩溃自动拉起(用户级 LaunchAgent,无需 root;
/// 正常"退出"不会复活,只有崩溃/被杀才会)
enum AutoStart {
    static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/com.macfancontrol.fanbar.plist"
    }
    static var installed: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    static func install() {
        let fm = FileManager.default
        let dir = (plistPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let binary = Bundle.main.bundlePath + "/Contents/MacOS/FanBar"
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.macfancontrol.fanbar</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binary)</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key><false/>
                <key>Crashed</key><true/>
            </dict>
            <key>ProcessType</key><string>Interactive</string>
        </dict>
        </plist>
        """
        do {
            try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plistPath)
            _ = runLaunchctl(["bootout", "gui/\(getuid())", plistPath])
            _ = runLaunchctl(["bootstrap", "gui/\(getuid())", plistPath])
        } catch {
            NSLog("AutoStart install failed: \(error)")
        }
    }

    static func uninstall() {
        _ = runLaunchctl(["bootout", "gui/\(getuid())", plistPath])
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    @discardableResult
    static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}

// MARK: - 界面

/// 用 NSStatusItem + NSPopover 自绘菜单栏(SwiftUI MenuBarExtra 的标题刷新/面板行为不可控,弃用)
@main
struct FanBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

var body: some Scene {
    // Settings 场景内容在启动时就会被实例化并订阅模型更新——绝不能放 PanelView
    // (面板/图表窗口全部按需创建、关闭即释放,见 AppDelegate)
    Settings { EmptyView() }
}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = FanModel()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var sensorWindow: NSWindow?
    private var trendWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        NSApplication.shared.setActivationPolicy(.accessory)
        appendLifeLog("启动 pid=\(getpid())")

        let host = NSHostingController(rootView: PanelView().environmentObject(model))
        let popover = NSPopover()
        popover.behavior = .transient          // 点外部自动关闭
        popover.delegate = self                // 关闭时卸下 SwiftUI 视图树(否则常驻布局刷新白耗 CPU)
        popover.contentViewController = host
        self.popover = popover

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        // 必须显式声明监听右键,否则 NSStatusBarButton 默认只响应左键
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp, .otherMouseUp])
        item.button?.image = NSImage(systemSymbolName: "thermometer.medium",
                                     accessibilityDescription: "温度")
        statusItem = item

        model.openSensors = { [weak self] in self?.openSensorWindow() }
        model.openTrend = { [weak self] in self?.openTrendWindow() }
        model.uiVisible = { [weak self] in
            guard let self else { return true }
            return self.uiVisible
        }

        Publishers.CombineLatest4(model.$sys, model.$controlTemp, model.$daemonOnline, model.$titleItems)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in self?.updateTitle() }
            .store(in: &cancellables)
        updateTitle()

        // 截图模式:FANBAR_SHOT=popover|settings|sensors|menu 启动 2 秒后自动打开对应界面(README 用)
        if let shot = ProcessInfo.processInfo.environment["FANBAR_SHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                switch shot {
                case "popover": self?.togglePopover()
                case "settings": self?.openSettingsWindow()
                case "sensors": self?.openSensorWindow()
                case "menu": self?.showStatusMenu()
                default: break
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { [weak self] in
                guard let self else { return }
                var winid = 0
                switch shot {
                case "popover":
                    winid = self.popover?.contentViewController?.view.window?.windowNumber ?? 0
                case "settings":
                    winid = NSApp.keyWindow?.windowNumber
                        ?? NSApp.windows.first { $0.isVisible }?.windowNumber ?? 0
                case "sensors":
                    winid = self.sensorWindow?.windowNumber ?? 0
                case "menu":
                    // 菜单窗口:从 CG 窗口表里找自己进程的、贴顶的中小窗口
                    winid = 0
                    if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] {
                        for info in list {
                            guard (info[kCGWindowOwnerPID as String] as? Int32) == getpid(),
                                  let wid = info[kCGWindowNumber as String] as? Int,
                                  let b = info[kCGWindowBounds as String] as? [String: Any],
                                  let y = b["Y"] as? Double, let w = b["Width"] as? Double,
                                  let h = b["Height"] as? Double else { continue }
                            if y < 60, w > 100, w < 460, h > 100, h < 520 {
                                winid = wid
                                break
                            }
                        }
                    }
                default:
                    winid = 0
                }
                var lines = ["winid=\(winid)"]
                if let btn = self.statusItem?.button, let f = btn.window?.frame,
                   let screenH = NSScreen.screens.first?.frame.height {
                    lines.append("barx=\(Int(f.minX))")
                    lines.append("bary=\(Int(screenH - f.maxY))")
                    lines.append("barw=\(Int(f.width))")
                }
                try? lines.joined(separator: "\n")
                    .write(toFile: "/tmp/fanbar-shot-info", atomically: true, encoding: .utf8)
            }
        }
    }

    private var uiVisible: Bool {
        popover?.isShown == true
            || sensorWindow?.isVisible == true
            || trendWindow?.isVisible == true
            || settingsWindow?.isVisible == true
    }

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        // 文本没变就不重设(省一次状态栏重排/CA 提交)
        let text = model.statusText
        if button.title != text {
            button.attributedTitle = NSAttributedString(
                string: text,
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)])
        }
        // 高温时换用高温计图标作提示(两张图缓存复用,不每拍重建)
        let hot = model.controlTemp >= (model.alarmEnabled ? model.alarmTemp : 95)
        let name = hot ? "thermometer.high" : "thermometer.medium"
        if titleIconName != name {
            titleIconName = name
            button.image = NSImage(systemSymbolName: name, accessibilityDescription: "温度")
        }
    }

    private var titleIconName: String?

    @objc private func togglePopover() {
        if let ev = NSApp.currentEvent, ev.type == .rightMouseUp {
            showStatusMenu()
            return
        }
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // 每次打开重建内容(popover 关闭期间视图树被卸下,模型刷新不再驱动隐藏布局)
        let host = NSHostingController(rootView: PanelView().environmentObject(model))
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 菜单栏图标右键快菜单

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let statusLine: String
        if let s = model.sys {
            statusLine = String(format: "🌡 %.0f°C · CPU %.0f%% · 内存 %.0f%%",
                                model.controlTemp, s.cpuUsage * 100, s.memPercent * 100)
        } else {
            statusLine = String(format: "🌡 %.0f°C", model.controlTemp)
        }
        menu.addItem(withTitle: statusLine, action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let boost = menu.addItem(withTitle: L.t("风扇全速(应急)", "Fans full speed (emergency)"), action: #selector(quickBoost), keyEquivalent: "")
        boost.target = self
        let restore = menu.addItem(withTitle: L.t("恢复自动曲线", "Restore auto curve"), action: #selector(quickRestore), keyEquivalent: "")
        restore.target = self
        menu.addItem(.separator())
        for (name, start, full) in [(L.t("曲线:安静", "Curve: Quiet"), 80.0, 100.0), (L.t("曲线:均衡", "Curve: Balanced"), 70.0, 95.0), (L.t("曲线:强力", "Curve: Turbo"), 55.0, 85.0)] {
            let item = menu.addItem(withTitle: name, action: #selector(quickPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["start": start, "full": full]
        }
        menu.addItem(.separator())
        let copy = menu.addItem(withTitle: L.t("复制状态", "Copy status"), action: #selector(quickCopy), keyEquivalent: "C")
        copy.target = self
        let csv = menu.addItem(withTitle: L.t("导出数据 CSV…", "Export data CSV…"), action: #selector(quickCSV), keyEquivalent: "")
        csv.target = self
        let settings = menu.addItem(withTitle: L.t("打开设置…", "Settings…"), action: #selector(openSettingsWindow), keyEquivalent: ",")
        settings.target = self
        let sensors = menu.addItem(withTitle: "全部传感器…", action: #selector(openSensorWindow), keyEquivalent: "")
        sensors.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: L.t("退出 FanBar", "Quit FanBar"), action: #selector(quitApp), keyEquivalent: "Q")
        quit.target = self

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
    }

    @objc private func quickBoost() { model.boostAllFans() }
    @objc private func quickRestore() { model.restoreAutoCurve() }
    @objc private func quickPreset(_ sender: NSMenuItem) {
        guard let obj = sender.representedObject as? [String: Double],
              let start = obj["start"], let full = obj["full"] else { return }
        model.applyPreset(start: start, full: full)
    }
    @objc private func quickCopy() { model.copyStatus() }
    @objc private func quickCSV() { model.exportCSV() }
    @objc private func openSettingsWindow() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: ScrollView {
                PanelView().environmentObject(model).padding(.vertical, 6)
            })
            let window = NSWindow(contentViewController: host)
            window.title = "MacFanControl 设置"
            window.styleMask.insert(.resizable)
            window.contentMinSize = NSSize(width: 372, height: 460)
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func openSensorWindow() {
        if sensorWindow == nil {
            let host = NSHostingController(rootView: SensorWindowView().environmentObject(model))
            let window = NSWindow(contentViewController: host)
            window.title = "全部传感器"
            window.styleMask.insert(.resizable)
            window.contentMinSize = NSSize(width: 440, height: 400)
            window.isReleasedWhenClosed = false
            window.delegate = self
            sensorWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        sensorWindow?.makeKeyAndOrderFront(nil)
    }

    private func openTrendWindow() {
        if trendWindow == nil {
            let host = NSHostingController(rootView: TrendWindowView().environmentObject(model))
            let window = NSWindow(contentViewController: host)
            window.title = "温度趋势(近 7 天)"
            window.styleMask.insert(.resizable)
            window.contentMinSize = NSSize(width: 720, height: 380)
            window.isReleasedWhenClosed = false
            window.delegate = self
            trendWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        trendWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: NSWindowDelegate(窗口关闭即释放 SwiftUI 视图树,避免隐藏窗口继续吃布局开销)

    func applicationWillTerminate(_ notification: Notification) {
        appendLifeLog("退出(用户或系统终止)")
    }
    /// 生命周期日志(排查"无声退出")
    private func appendLifeLog(_ msg: String) {
        let path = NSHomeDirectory() + "/Library/Logs/macfancontrol-fanbar.log"
        let line = "\(Date()) \(msg)\n"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        if !fm.createFile(atPath: path, contents: Data(line.utf8)) {
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            }
        }
    }
}

extension AppDelegate: NSPopoverDelegate {
    /// 关闭即卸下 SwiftUI 视图树:面板不可见时模型每 1.5s 的发布不再触发隐藏布局
    func popoverDidClose(_ notification: Notification) {
        popover?.contentViewController = NSHostingController(rootView: Color.clear.frame(width: 340, height: 100))
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        let win = notification.object as? NSWindow
        if win === sensorWindow { sensorWindow = nil }
        if win === trendWindow { trendWindow = nil }
        if win === settingsWindow { settingsWindow = nil }
    }
}

extension AppDelegate: NSMenuDelegate {
    /// 右键菜单关闭后立刻卸下,恢复左键开面板
    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
    }
}
/// 全部传感器列表窗口:查看所有传感器,勾选参与风扇控制的(取最大值)
struct SensorWindowView: View {
    @EnvironmentObject var model: FanModel
    @State private var searchText = ""

    private var filtered: [SensorRow] {
        guard !searchText.isEmpty else { return model.sensors }
        let q = searchText.lowercased()
        return model.sensors.filter {
            $0.key.lowercased().contains(q) || $0.label.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.t("全部传感器(\(filtered.count) 个,按温度排序)",
                         "All sensors (\(filtered.count))"))
                    .font(.headline)
                Spacer()
                TextField(L.t("搜索键名/名称", "Search"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
            }
            .padding(10)
            Divider()
            List(filtered) { s in
                HStack {
                    Toggle("", isOn: sensorBinding(s.key))
                        .labelsHidden()
                        .disabled(!model.daemonOnline)
                    Text(s.label).frame(width: 130, alignment: .leading)
                    Text(s.key).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
                    Spacer()
                    Text(String(format: "%.1f °C", s.value)).monospacedDigit()
                }
                .contextMenu {
                    Button("复制键名 \(s.key)") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(s.key, forType: .string)
                    }
                    Button("复制 \(s.label) 温度") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(String(format: "%.1f°C", s.value), forType: .string)
                    }
                }
            }
            .listStyle(.plain)
        }
        .frame(minWidth: 440, minHeight: 500)
    }

    private func sensorBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { model.selectedSensors.contains(key) },
            set: { model.toggleSensor(key, on: $0) })
    }
}

struct PanelView: View {
    @EnvironmentObject var model: FanModel
    @State private var sensorsExpanded = false
    @State private var procByMem = false

    private func memText(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1fG", mb / 1024) : String(format: "%.0fM", mb)
    }

    private func openSensorWindow() {
        NSApp.activate(ignoringOtherApps: true)
        model.openSensors?()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            statsSection
            historySection
            Divider()
            if model.daemonOnline {
                controlPanel
            } else {
                offlinePanel
            }
            if let msg = model.message {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
            if let v = model.updateAvailable {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text(L.t("发现新版本 \(v)", "New version \(v) available")).font(.caption)
                    Spacer()
                    Button(L.t("查看", "View")) {
                        if let url = URL(string: "https://github.com/skydeadpeng/MacFanControl/releases/latest") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { model.refresh() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.1f °C", model.controlTemp))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("控制温度" + (model.selectedSensors.isEmpty ? "" : " · \(model.selectedSensors.count) 个传感器取最大"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if model.starting {
                    Text(L.t("守护进程启动中…", "Daemon starting…")).font(.caption).foregroundStyle(.secondary)
                } else if model.daemonOnline {
                    Text(model.controlled ? "● 已接管" : "○ 系统控制")
                        .font(.caption).foregroundStyle(model.controlled ? Color.green : Color.orange)
                    if model.nightActive {
                        Text(L.t("🌙 夜间模式", "🌙 Night mode")).font(.caption2).foregroundStyle(.indigo)
                    } else if !model.onAC, !model.config.batteryCurves.isEmpty {
                        Text(L.t("电池曲线生效中", "Battery curve active")).font(.caption2).foregroundStyle(.orange)
                    }
                } else {
                    Text(L.t("守护进程未运行", "Daemon not running")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .contextMenu {
            Button("复制状态") { model.copyStatus() }
        }
    }

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sys = model.sys {
                HStack {
                    Text(L.t("系统", "System")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("↓ \(SystemStats.Snapshot.speed(sys.netIn))   ↑ \(SystemStats.Snapshot.speed(sys.netOut))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("CPU").font(.caption).frame(width: 34, alignment: .leading)
                    Text(String(format: "%.0f%%", sys.cpuUsage * 100))
                        .font(.caption).monospacedDigit().frame(width: 36, alignment: .trailing)
                    HStack(spacing: 2) {
                        ForEach(Array(sys.coreUsages.enumerated()), id: \.offset) { _, u in
                            coreBar(u)
                        }
                    }
                    Spacer()
                }
                if !sys.topProcs.isEmpty || !sys.topMemProcs.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array((procByMem ? sys.topMemProcs : sys.topProcs).enumerated()), id: \.offset) { _, p in
                            HStack {
                                Text(p.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 6)
                                if !procByMem {
                                    Text(String(format: "%.0f%%", p.percent)).monospacedDigit()
                                }
                                Text(memText(p.memMB)).monospacedDigit().foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button(L.t("结束进程(\(p.name))", "Quit \(p.name)")) {
                                    model.terminateProcess(p, force: false)
                                }
                                Button(L.t("强制退出(不可恢复)", "Force quit"), role: .destructive) {
                                    model.terminateProcess(p, force: true)
                                }
                            }
                        }
                        HStack {
                            Text(L.t("右击进程名可将其结束", "Right-click a process to quit it")).foregroundStyle(.tertiary)
                            Spacer()
                            Button(procByMem ? "按CPU" : "按内存") { procByMem.toggle() }
                        }
                        .font(.caption2)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 86)
                }
                if let gpu = sys.gpuUsage {
                    HStack(spacing: 8) {
                        Text("GPU").font(.caption).frame(width: 34, alignment: .leading)
                        Text("\(gpu)%").font(.caption).monospacedDigit().frame(width: 36, alignment: .trailing)
                        Text(gpu > 85 ? "高负载" : (gpu > 50 ? "中等" : "空闲"))
                            .font(.caption2).foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
                HStack(spacing: 8) {
                    Text(L.t("内存", "Memory")).font(.caption).frame(width: 34, alignment: .leading)
                    Text(String(format: "%.0f%%", sys.memPercent * 100))
                        .font(.caption).monospacedDigit().frame(width: 36, alignment: .trailing)
                    Text("\(SystemStats.Snapshot.size(sys.memUsed)) / \(SystemStats.Snapshot.size(sys.memTotal))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    if sys.memFreePercent < 0.10 {
                        Text(L.t("压力高", "High pressure")).font(.caption2).foregroundStyle(.red)
                    } else if sys.memFreePercent < 0.20 {
                        Text(L.t("压力中", "Med pressure")).font(.caption2).foregroundStyle(.orange)
                    }
                    Spacer()
                    if sys.swapUsed > 0 {
                        Text("Swap \(SystemStats.Snapshot.size(sys.swapUsed))")
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(sys.swapUsed > 2_147_483_648 ? Color.red : Color.secondary)
                    }
                }
                if sys.battery.present {
                    HStack(spacing: 8) {
                        Text(L.t("电池", "Battery")).font(.caption).frame(width: 34, alignment: .leading)
                        Text(String(format: "%.0f%%", sys.battery.percent))
                            .font(.caption).monospacedDigit().frame(width: 36, alignment: .trailing)
                            .foregroundStyle(sys.battery.percent < 20 && !sys.battery.onAC ? Color.red : Color.primary)
                        Text(batteryDetail(sys.battery))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer()
                    }
                }
                HStack(spacing: 8) {
                    Text(L.t("硬盘", "Disk")).font(.caption).frame(width: 34, alignment: .leading)
                    Text(String(format: "%.0f%%", sys.diskPercent * 100))
                        .font(.caption).monospacedDigit().frame(width: 36, alignment: .trailing)
                        .foregroundStyle(sys.diskPercent > 0.9 ? Color.red : Color.primary)
                    Text("\(SystemStats.Snapshot.diskSize(sys.diskUsed)) / \(SystemStats.Snapshot.diskSize(sys.diskTotal))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Text("读 \(SystemStats.Snapshot.speed(sys.diskRead))  写 \(SystemStats.Snapshot.speed(sys.diskWrite))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }
                HStack(spacing: 8) {
                    Text(L.t("流量", "Traffic")).font(.caption).frame(width: 34, alignment: .leading)
                    Text("今日 ↓\(SystemStats.Snapshot.trafficSize(model.todayIn))  ↑\(SystemStats.Snapshot.trafficSize(model.todayOut))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                }
                if model.day.high > 0 {
                    HStack(spacing: 8) {
                        Text(L.t("今日峰值", "Today's peak")).font(.caption).frame(width: 34, alignment: .leading)
                        Text(L.t(String(format: "%.0f°C · CPU %d%%", model.day.high, Int(model.day.maxCPU)),
                                 String(format: "%.0f°C · CPU %d%%", model.day.high, Int(model.day.maxCPU))))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        if model.day.maxPower > 0.5 {
                            Text(String(format: " · %.1fW", model.day.maxPower))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        if model.day.whOut > 0.5 {
                            Text(String(format: " · 用电 %.1fWh", model.day.whOut))
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                HStack(spacing: 8) {
                    Toggle(isOn: $model.alarmEnabled) {
                        Text(L.t("高温报警", "High-temp alert")).font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    if model.alarmEnabled {
                        Slider(value: $model.alarmTemp, in: 70...105, step: 1)
                        Text("\(Int(model.alarmTemp))°C")
                            .font(.caption).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                barSection
            } else {
                Text(L.t("正在读取系统信息…", "Reading system info…")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func coreBar(_ usage: Double) -> some View {
        ZStack(alignment: .bottom) {
            Capsule().fill(Color.primary.opacity(0.12))
            Capsule().fill(usage > 0.85 ? Color.red : (usage > 0.6 ? Color.orange : Color.accentColor))
                .frame(height: max(2, 16 * usage))
        }
        .frame(width: 4, height: 16)
    }

    // MARK: 菜单栏显示内容(可任选组合)

    @State private var barExpanded = false
    static let titleOptions: [(String, String)] = [
        ("temp", "温度"), ("cpu", "CPU"), ("gpu", "GPU"), ("mem", "内存"),
        ("net", "网速"), ("battery", "电池"), ("power", "功率"),
    ]

    private var barSection: some View {
        DisclosureGroup(isExpanded: $barExpanded) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 66))], alignment: .leading, spacing: 4) {
                ForEach(Self.titleOptions, id: \.0) { key, label in
                    Toggle(label, isOn: Binding(
                        get: { model.titleItems.contains(key) },
                        set: { on in
                            var items = model.titleItems
                            if on {
                                if !items.contains(key) { items.append(key) }
                            } else {
                                items.removeAll { $0 == key }
                                if items.isEmpty { items = ["temp"] }
                            }
                            model.titleItems = items
                        }))
                    .toggleStyle(.checkbox)
                    .controlSize(.mini)
                    .font(.caption)
                }
            }
            .padding(.top, 3)
        } label: {
            Text(L.t("菜单栏显示内容", "Menu bar items")).font(.caption)
        }
    }

    // MARK: 历史曲线(近 3 分钟)

    private var historySection: some View {
        Group {
            if model.history.count > 3 {
                VStack(alignment: .leading, spacing: 3) {
                    Chart {
                        ForEach(model.history) { p in
                            LineMark(x: .value("时间", p.t), y: .value("温度", p.temp))
                                .foregroundStyle(Color.red.opacity(0.85))
                            LineMark(x: .value("时间", p.t), y: .value("CPU", p.cpu))
                                .foregroundStyle(Color.blue.opacity(0.65))
                            LineMark(x: .value("时间", p.t), y: .value("GPU", p.gpu))
                                .foregroundStyle(Color.purple.opacity(0.6))
                        }
                    }
                    .chartYScale(domain: 0...110)
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 52)
                    Chart(model.history) { p in
                        LineMark(x: .value("时间", p.t), y: .value("转速", p.rpm))
                            .foregroundStyle(Color.green.opacity(0.8))
                    }
                    .chartYScale(domain: 1000...6200)
                    .chartXAxis(.hidden)
                    .chartYAxis(.hidden)
                    .frame(height: 26)
                    HStack(spacing: 10) {
                        Text("— 温度°C").foregroundStyle(.red)
                        Text("— CPU%").foregroundStyle(.blue)
                        Text("— GPU%").foregroundStyle(.purple)
                        Text("— 风扇RPM").foregroundStyle(.green)
                        Spacer()
                        if model.day.high > 0 {
                            Text(String(format: "近15分钟 · 今日 %.0f–%.0f°C", model.day.low, model.day.high))
                        } else {
                            Text("近 15 分钟")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
                }
            }
        }
    }

    private func batteryDetail(_ b: SystemStats.BatteryInfo) -> String {
        var parts: [String] = [b.onAC ? (b.charging ? "充电中" : "外接电源") : "使用电池"]
        if b.cycleCount > 0 { parts.append("循环 \(b.cycleCount)") }
        if b.health > 0 { parts.append("健康 \(Int(b.health * 100))%") }
        if b.watts > 0.5 {
            parts.append((b.chargeIn ? "充入 " : "放出 ") + String(format: "%.1fW", b.watts))
        }
        if model.day.whOut > 0.5 {
            parts.append(String(format: "今日用电 %.1fWh", model.day.whOut))
        }
        return parts.joined(separator: " · ")
    }

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { model.config.enabled }, set: model.setEnabled)) {
                Text(L.t("启用风扇控制", "Enable fan control")).font(.headline)
            }

            if model.config.enabled {
                Picker("模式", selection: Binding(
                    get: { model.config.mode == "manual" },
                    set: model.setMode)) {
                    Text(L.t("自动曲线", "Auto curve")).tag(false)
                    Text(L.t("手动转速", "Manual RPM")).tag(true)
                }
                .pickerStyle(.segmented)

                if model.config.mode == "manual" {
                    ForEach(model.fans) { fan in
                        manualSlider(fan: fan)
                    }
                } else {
                    HStack(spacing: 6) {
                        presetButton(L.t("安静", "Quiet"), 80, 100)
                        presetButton(L.t("均衡", "Balanced"), 70, 95)
                        presetButton(L.t("强力", "Turbo"), 55, 85)
                        Spacer()
                    }
                    curveEditor
                    nightSection
                }

                Divider()
                ForEach(model.fans) { fan in
                    HStack {
                        Text(fan.id == 0 ? "风扇 1" : "风扇 \(fan.id + 1)").font(.subheadline)
                        Spacer()
                        Text(String(format: "%.0f RPM", fan.rpm)).monospacedDigit()
                        Text(String(format: "(目标 %.0f)", fan.target))
                            .foregroundStyle(.secondary).font(.caption)
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("此风扇全速") { model.boostFan(fan.index) }
                        Button("恢复自动曲线") { model.restoreAutoCurve() }
                        Button("全部风扇全速") { model.boostAllFans() }
                    }
                }

                DisclosureGroup(isExpanded: $sensorsExpanded) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.sensors.prefix(16)) { s in
                            Toggle(isOn: sensorBinding(s.key)) {
                                Text(String(format: "%@ · %.0f°  %@", s.label, s.value, s.key))
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text(L.t("控制传感器", "Control sensors")).font(.subheadline)
                }
                Toggle(isOn: $model.autoStart) {
                    Text(L.t("开机自启(崩溃自动恢复)", "Launch at login (auto-restart)")).font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            HStack {
                Button(L.t("恢复系统控制", "Restore system control")) { model.restore() }
                Button(L.t("全部传感器…", "All sensors…")) { openSensorWindow() }
                Button(L.t("趋势…", "Trends…")) { model.openTrend?() }
                Button(L.t("诊断包", "Diagnostics")) { model.exportDiagnostics() }
                Spacer()
                Button(L.t("卸载守护进程…", "Uninstall daemon…")) { model.uninstallDaemon() }
                    .foregroundStyle(.secondary)
                Button("退出") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    // MARK: 定时夜间模式(时间窗内改用预设曲线,夜间降噪)

    @State private var nightExpanded = false

    private var nightSection: some View {
        let nm = model.config.nightMode ?? NightMode()
        let statusKey: String
        if !nm.enabled {
            statusKey = "状态:未启用"
        } else if model.nightActive {
            statusKey = "状态:🌙 生效中(\(nm.timeText),预设已接管)"
        } else {
            statusKey = "状态:未到时间窗(\(nm.timeText))"
        }
        return DisclosureGroup(isExpanded: $nightExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(
                    get: { nm.enabled },
                    set: { on in var c = nm; c.enabled = on; model.setNightMode(c) })) {
                    Text(L.t("启用(时间窗内忽略曲线,改用所选预设)", "Enable (preset within window)")).font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                HStack(spacing: 10) {
                    DatePicker(L.t("开始", "Start"), selection: nightDateBinding(\.start, nm),
                               displayedComponents: .hourAndMinute)
                    DatePicker(L.t("结束", "End"), selection: nightDateBinding(\.end, nm),
                               displayedComponents: .hourAndMinute)
                }
                .labelsHidden()
                .datePickerStyle(.field)
                Picker(L.t("预设", "Preset"), selection: Binding(
                    get: { nm.preset },
                    set: { p in var c = nm; c.preset = p; model.setNightMode(c) })) {
                    Text(L.t("安静", "Quiet")).tag("quiet")
                    Text(L.t("均衡", "Balanced")).tag("balanced")
                    Text(L.t("强力", "Turbo")).tag("turbo")
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                Text(statusKey)
                    .font(.caption2).foregroundStyle(model.nightActive ? Color.indigo : Color.secondary)
            }
            .padding(.top, 3)
        } label: {
            HStack(spacing: 4) {
                Text(L.t("定时夜间模式", "Night schedule")).font(.subheadline)
                if model.nightActive {
                    Text("🌙").font(.caption2)
                }
            }
        }
    }

    private func nightDateBinding(_ keyPath: WritableKeyPath<NightMode, Int>, _ nm: NightMode) -> Binding<Date> {
        Binding(
            get: {
                let m = nm[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: (m / 60) % 24, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                let minutes = ((c.hour ?? 0) * 60 + (c.minute ?? 0)) % (24 * 60)
                var copy = model.config.nightMode ?? NightMode()
                copy[keyPath: keyPath] = minutes
                model.setNightMode(copy)
            })
    }

    private func presetButton(_ name: String, _ start: Double, _ full: Double) -> some View {
        Button(name) {
            model.applyPreset(start: start, full: full)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }

    private func manualSlider(fan: FanRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("风扇 \(fan.index + 1) 转速").font(.subheadline)
                Spacer()
                Text(String(format: "%.0f RPM", model.config.manualRPM["\(fan.index)"] ?? fan.min))
                    .monospacedDigit().font(.subheadline)
            }
            Slider(value: Binding(
                get: { model.config.manualRPM["\(fan.index)"] ?? fan.min },
                set: { model.config.manualRPM["\(fan.index)"] = $0 }),
                   in: 500...max(fan.max, 5000), step: 50,
                   onEditingChanged: { editing in
                       if !editing, let v = model.config.manualRPM["\(fan.index)"] {
                           model.setManualRPM(v, fan: fan.index)
                       }
                   })
        }
    }

    // MARK: 多点曲线编辑器(插电/电池两套)

    @State private var curveFan = -1        // -1 = 全部风扇
    @State private var curveOnBattery = false

    private var curveEditor: some View {
        let fanKey = curveFan >= 0 ? curveFan : nil
        let pts = model.curvePoints(fanIndex: fanKey, battery: curveOnBattery).sorted { $0.temp < $1.temp }
        // 转速范围按风扇实际(全部风扇模式取并集)
        let rpmRange: ClosedRange<Double> = {
            if let i = fanKey, let f = model.fans.first(where: { $0.index == i }) {
                return max(500, f.min - 200)...f.max + 200
            }
            let lo = model.fans.map(\.min).min() ?? 1200
            let hi = model.fans.map(\.max).max() ?? 6000
            return max(500, lo - 200)...hi + 200
        }()
        return VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $curveFan) {
                Text(L.t("全部风扇", "All fans")).tag(-1)
                ForEach(model.fans) { f in
                    Text(L.t("风扇 \(f.index + 1)", "Fan \(f.index + 1)")).tag(f.index)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            if curveOnBattery {
                if pts.count >= 2 {
                    curveBody(pts: pts, fanKey: fanKey, rpmRange: rpmRange, battery: true)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L.t("电池曲线未设置,当前沿用插电曲线", "No battery curve; using AC curve"))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(L.t("复制插电曲线", "Copy AC curve")) {
                                model.copyCurvesToBattery()
                            }
                            Button(L.t("清除电池曲线", "Clear")) { model.clearBatteryCurves() }
                                .disabled(true)
                            Spacer()
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
            } else {
                curveBody(pts: pts, fanKey: fanKey, rpmRange: rpmRange, battery: false)
            }
        }
    }

    /// 电源页签(插电/电池)+ 曲线画布与控制点行
    private func curveBody(pts: [CurvePoint], fanKey: Int?, rpmRange: ClosedRange<Double>, battery: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("", selection: $curveOnBattery) {
                    Text(L.t("插电曲线", "AC")).tag(false)
                    Text(L.t("电池曲线", "Battery")).tag(true)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 150)
                if battery && !model.onAC {
                    Text(L.t("● 正在用电池", "● on battery")).font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                if model.nightActive {
                    Text(L.t("🌙 夜间模式生效中", "🌙 night mode")).font(.caption2).foregroundStyle(.indigo)
                }
            }

            CurveCanvas(points: pts, tempRange: 40...105, rpmRange: rpmRange,
                        currentTemp: model.controlTemp) { idx, newPoint in
                var arr = pts
                guard idx < arr.count else { return }
                arr[idx] = newPoint
                arr.sort { $0.temp < $1.temp }
                model.setCurvePoints(arr, fanIndex: fanKey, battery: battery)
            }
            .frame(height: 96)

            ForEach(Array(pts.enumerated()), id: \.offset) { idx, _ in
                pointRow(idx: idx, pts: pts, fanKey: fanKey, rpmRange: rpmRange, battery: battery)
            }
            HStack {
                Button("添加控制点") { addPoint(pts, fanKey: fanKey, battery: battery) }
                Button(battery ? "清除电池曲线" : "恢复直线") {
                    model.setCurvePoints([], fanIndex: fanKey, battery: battery)
                }
                if battery {
                    Button(L.t("复制插电曲线", "Copy AC")) { model.copyCurvesToBattery() }
                }
                Spacer()
                Text("降温有 1.5°C 回滞防抖").foregroundStyle(.tertiary)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private func pointRow(idx: Int, pts: [CurvePoint], fanKey: Int?, rpmRange: ClosedRange<Double>, battery: Bool) -> some View {
        HStack(spacing: 6) {
            Text(String(format: "%.0f°C", pts[idx].temp))
                .monospacedDigit().frame(width: 42)
            Slider(value: pointBinding(idx: idx, pts: pts, fanKey: fanKey, isTemp: true, battery: battery),
                   in: 40...105, step: 1)
            Text(String(format: "%.0f转", pts[idx].rpm))
                .monospacedDigit().frame(width: 44)
            Slider(value: pointBinding(idx: idx, pts: pts, fanKey: fanKey, isTemp: false, battery: battery),
                   in: rpmRange, step: 50)
            Button {
                removePoint(idx: idx, fanKey: fanKey, battery: battery)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.link)
        }
    }

    private func pointBinding(idx: Int, pts: [CurvePoint], fanKey: Int?, isTemp: Bool, battery: Bool) -> Binding<Double> {
        Binding(
            get: { isTemp ? pts[idx].temp : pts[idx].rpm },
            set: { v in
                var arr = pts
                if isTemp { arr[idx].temp = v.rounded() } else { arr[idx].rpm = (v / 50).rounded() * 50 }
                arr.sort { $0.temp < $1.temp }
                model.setCurvePoints(arr, fanIndex: fanKey, battery: battery)
            })
    }

    private func addPoint(_ pts: [CurvePoint], fanKey: Int?, battery: Bool) {
        var arr = pts.sorted { $0.temp < $1.temp }
        guard arr.count >= 2 else { return }
        var bestI = 0
        var bestGap = -1.0
        for i in 1..<arr.count where arr[i].temp - arr[i - 1].temp > bestGap {
            bestGap = arr[i].temp - arr[i - 1].temp
            bestI = i
        }
        arr.insert(CurvePoint(temp: ((arr[bestI - 1].temp + arr[bestI].temp) / 2).rounded(),
                              rpm: (arr[bestI - 1].rpm + arr[bestI].rpm) / 2), at: bestI)
        model.setCurvePoints(arr, fanIndex: fanKey, battery: battery)
    }

    private func removePoint(idx: Int, fanKey: Int?, battery: Bool) {
        var arr = model.curvePoints(fanIndex: fanKey, battery: battery).sorted { $0.temp < $1.temp }
        guard arr.count > 2, idx < arr.count else { return }
        arr.remove(at: idx)
        model.setCurvePoints(arr, fanIndex: fanKey, battery: battery)
    }

    private func sensorBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { model.selectedSensors.contains(key) },
            set: { model.toggleSensor(key, on: $0) })
    }

    private var daemonInstalled: Bool {
        FileManager.default.fileExists(atPath: Paths.launchdPlist)
    }

    private var offlinePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if daemonInstalled {
                Label("守护进程已安装,正在启动…(开机后前几秒属正常,会自动连上,无需重装)", systemImage: "hourglass")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("风扇控制需要 root 守护进程(用于写入 SMC)。")
                    .font(.subheadline)
                Button {
                    model.installDaemon()
                } label: {
                    Label(model.busy ? "安装中…" : "安装守护进程(需要管理员密码)",
                          systemImage: "shield.checkered")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(model.busy)
            }

            Divider()
            ForEach(model.sensors.prefix(5)) { s in
                HStack {
                    Text("\(s.label) \(s.key)").font(.caption)
                    Spacer()
                    Text(String(format: "%.1f °C", s.value)).monospacedDigit().font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            ForEach(model.fans) { f in
                HStack {
                    Text(L.t("风扇 \(f.index + 1)", "Fan \(f.index + 1)")).font(.caption)
                    Spacer()
                    Text(String(format: "%.0f RPM", f.rpm)).monospacedDigit().font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            HStack {
                Button("刷新") { model.refresh() }
                Button("全部传感器…") { openSensorWindow() }
                if daemonInstalled {
                    Button("重新安装守护进程…") { model.installDaemon() }
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }
}
