import SwiftUI
import AppKit
import Charts
import Combine
import UserNotifications
import SMCKit

// MARK: - 数据模型

/// 历史曲线点(温度°C、CPU%、风扇RPM,保留约 3 分钟)
struct HistPoint: Identifiable {
    let id = UUID()
    let t: Date
    let temp: Double
    let cpu: Double
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
    @Published var todayHigh: Double = 0
    @Published var todayLow: Double = 0
    @Published var autoStart: Bool = AutoStart.installed {
        didSet {
            if autoStart { AutoStart.install() } else { AutoStart.uninstall() }
        }
    }
    /// 打开"全部传感器"窗口(由 AppDelegate 注入实现)
    var openSensors: (() -> Void)?

    // 高温报警(UserDefaults 持久化)
    @Published var alarmEnabled: Bool = UserDefaults.standard.object(forKey: "alarmEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(alarmEnabled, forKey: "alarmEnabled") }
    }
    @Published var alarmTemp: Double = UserDefaults.standard.object(forKey: "alarmTemp") as? Double ?? 90 {
        didSet { UserDefaults.standard.set(alarmTemp, forKey: "alarmTemp") }
    }
    private var lastAlarmAt = Date.distantPast

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

    /// 菜单栏标题(温度 + CPU%,由 AppDelegate 的 NSStatusItem 渲染)
    var statusText: String {
        let t = daemonOnline ? controlTemp : (sensors.first?.value ?? 0)
        var s = t > 0 ? String(format: "%.0f°", t) : "--°"
        if let sys = sys { s += String(format: "  %.0f%%", sys.cpuUsage * 100) }
        return s
    }

    var hasFans: Bool { !fans.isEmpty }

    init() {
        loadTraffic()
        loadTodayStats()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        checkForUpdate()
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

    // MARK: 今日温度统计

    private func loadTodayStats() {
        guard let dict = UserDefaults.standard.dictionary(forKey: "dayStats"),
              (dict["date"] as? String) == Self.dayString else { return }
        todayHigh = dict["high"] as? Double ?? 0
        todayLow = dict["low"] as? Double ?? 0
    }

    private func updateTodayStats(_ t: Double) {
        guard t > 1 else { return }
        if todayHigh == 0 || t > todayHigh { todayHigh = t }
        if todayLow == 0 || t < todayLow { todayLow = t }
        UserDefaults.standard.set(["date": Self.dayString, "high": todayHigh, "low": todayLow],
                                  forKey: "dayStats")
    }

    private static var dayString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    func refresh() {
        let s = stats.sample()
        sys = s
        accumulateTraffic(s)
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
        history.append(HistPoint(t: Date(), temp: temp, cpu: cpu * 100, rpm: rpm))
        if history.count > 600 { history.removeFirst(history.count - 600) }   // 1.5s × 600 ≈ 15 分钟
        updateTodayStats(temp)
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
        content.title = "温度过高"
        content.body = String(format: "控制温度已达 %.0f°C(报警阈值 %.0f°C),风扇正按曲线散热", controlTemp, alarmTemp)
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
        send(patch: ["mode": "auto", "tempStart": start, "tempFull": full])
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
    Settings {
        ScrollView {
            PanelView()
                .environmentObject(appDelegate.model)
                .padding(.vertical, 6)
        }
        .navigationTitle("MacFanControl 设置")
        .frame(minWidth: 372, minHeight: 460)
    }
}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = FanModel()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var sensorWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        NSApplication.shared.setActivationPolicy(.accessory)
        appendLifeLog("启动 pid=\(getpid())")

        let host = NSHostingController(rootView: PanelView().environmentObject(model))
        let popover = NSPopover()
        popover.behavior = .transient          // 点外部自动关闭
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

        Publishers.CombineLatest3(model.$sys, model.$controlTemp, model.$daemonOnline)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.updateTitle() }
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

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        let text = model.statusText
        button.title = text
        // 高温时换用高温计图标作提示
        let hot = model.controlTemp >= (model.alarmEnabled ? model.alarmTemp : 95)
        let symbol = hot ? "thermometer.high" : "thermometer.medium"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "温度")
    }

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
        // 每次打开前按当前内容自适应高度
        if let host = popover.contentViewController {
            popover.contentSize = host.view.fittingSize
        }
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

        let boost = menu.addItem(withTitle: "风扇全速(应急)", action: #selector(quickBoost), keyEquivalent: "")
        boost.target = self
        let restore = menu.addItem(withTitle: "恢复自动曲线", action: #selector(quickRestore), keyEquivalent: "")
        restore.target = self
        menu.addItem(.separator())
        for (name, start, full) in [("曲线:安静", 80.0, 100.0), ("曲线:均衡", 70.0, 95.0), ("曲线:强力", 55.0, 85.0)] {
            let item = menu.addItem(withTitle: name, action: #selector(quickPreset(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["start": start, "full": full]
        }
        menu.addItem(.separator())
        let copy = menu.addItem(withTitle: "复制状态", action: #selector(quickCopy), keyEquivalent: "C")
        copy.target = self
        let settings = menu.addItem(withTitle: "打开设置…", action: #selector(openSettingsWindow), keyEquivalent: ",")
        settings.target = self
        let sensors = menu.addItem(withTitle: "全部传感器…", action: #selector(openSensorWindow), keyEquivalent: "")
        sensors.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "退出 FanBar", action: #selector(quitApp), keyEquivalent: "Q")
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
    @objc private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
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
            sensorWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        sensorWindow?.makeKeyAndOrderFront(nil)
    }

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

extension AppDelegate: NSMenuDelegate {
    /// 右键菜单关闭后立刻卸下,恢复左键开面板
    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
    }
}
/// 全部传感器列表窗口:查看所有传感器,勾选参与风扇控制的(取最大值)
struct SensorWindowView: View {
    @EnvironmentObject var model: FanModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("全部传感器(\(model.sensors.count) 个,按温度排序)")
                    .font(.headline)
                Spacer()
                Text(model.daemonOnline ? "勾选参与风扇控制(取最大值)" : "守护进程未运行,仅查看")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            List(model.sensors) { s in
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
                    Text("发现新版本 \(v)").font(.caption)
                    Spacer()
                    Button("查看") {
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
                    Text("守护进程启动中…").font(.caption).foregroundStyle(.secondary)
                } else if model.daemonOnline {
                    Text(model.controlled ? "● 已接管" : "○ 系统控制")
                        .font(.caption).foregroundStyle(model.controlled ? Color.green : Color.orange)
                } else {
                    Text("守护进程未运行").font(.caption).foregroundStyle(.secondary)
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
                    Text("系统").font(.caption).foregroundStyle(.secondary)
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
                                Button("结束进程(\(p.name))") {
                                    model.terminateProcess(p, force: false)
                                }
                                Button("强制退出(不可恢复)", role: .destructive) {
                                    model.terminateProcess(p, force: true)
                                }
                            }
                        }
                        HStack {
                            Text("右击进程名可将其结束").foregroundStyle(.tertiary)
                            Spacer()
                            Button(procByMem ? "按CPU" : "按内存") { procByMem.toggle() }
                        }
                        .font(.caption2)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 86)
                }
                HStack(spacing: 8) {
                    Text("内存").font(.caption).frame(width: 34, alignment: .leading)
                    Text(String(format: "%.0f%%", sys.memPercent * 100))
                        .font(.caption).monospacedDigit().frame(width: 36, alignment: .trailing)
                    Text("\(SystemStats.Snapshot.size(sys.memUsed)) / \(SystemStats.Snapshot.size(sys.memTotal))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                }
                if sys.battery.present {
                    HStack(spacing: 8) {
                        Text("电池").font(.caption).frame(width: 34, alignment: .leading)
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
                    Text("硬盘").font(.caption).frame(width: 34, alignment: .leading)
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
                    Text("流量").font(.caption).frame(width: 34, alignment: .leading)
                    Text("今日 ↓\(SystemStats.Snapshot.trafficSize(model.todayIn))  ↑\(SystemStats.Snapshot.trafficSize(model.todayOut))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Toggle(isOn: $model.alarmEnabled) {
                        Text("高温报警").font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    if model.alarmEnabled {
                        Slider(value: $model.alarmTemp, in: 70...105, step: 1)
                        Text("\(Int(model.alarmTemp))°C")
                            .font(.caption).monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            } else {
                Text("正在读取系统信息…").font(.caption).foregroundStyle(.secondary)
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
                        Text("— 风扇RPM").foregroundStyle(.green)
                        Spacer()
                        if model.todayHigh > 0 {
                            Text(String(format: "近15分钟 · 今日 %.0f–%.0f°C", model.todayLow, model.todayHigh))
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
        if b.watts > 0.5 { parts.append(String(format: "%.1fW", b.watts)) }
        return parts.joined(separator: " · ")
    }

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { model.config.enabled }, set: model.setEnabled)) {
                Text("启用风扇控制").font(.headline)
            }

            if model.config.enabled {
                Picker("模式", selection: Binding(
                    get: { model.config.mode == "manual" },
                    set: model.setMode)) {
                    Text("自动曲线").tag(false)
                    Text("手动转速").tag(true)
                }
                .pickerStyle(.segmented)

                if model.config.mode == "manual" {
                    ForEach(model.fans) { fan in
                        manualSlider(fan: fan)
                    }
                } else {
                    HStack(spacing: 6) {
                        presetButton("安静", 80, 100)
                        presetButton("均衡", 70, 95)
                        presetButton("强力", 55, 85)
                        Spacer()
                    }
                    curveSlider(title: "起转温度", value: model.config.tempStart, range: 40...75,
                                format: "%.0f °C 开始升速") { v in
                        model.setCurve(start: v, full: max(v + 5, model.config.tempFull))
                    }
                    curveSlider(title: "全速温度", value: model.config.tempFull, range: 75...100,
                                format: "%.0f °C 满转速") { v in
                        model.setCurve(start: min(model.config.tempStart, v - 5), full: v)
                    }
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
                    Text("控制传感器").font(.subheadline)
                }
                Toggle(isOn: $model.autoStart) {
                    Text("开机自启(崩溃自动恢复)").font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            HStack {
                Button("恢复系统控制") { model.restore() }
                Button("全部传感器…") { openSensorWindow() }
                Spacer()
                Button("卸载守护进程…") { model.uninstallDaemon() }
                    .foregroundStyle(.secondary)
                Button("退出") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
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

    private func curveSlider(title: String, value: Double, range: ClosedRange<Double>,
                             format: String, commit: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(String(format: format, value)).monospacedDigit().font(.subheadline)
            }
            Slider(value: Binding(get: { value }, set: { commit($0.rounded()) }),
                   in: range, step: 1)
        }
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
                    Text("风扇 \(f.index + 1)").font(.caption)
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
