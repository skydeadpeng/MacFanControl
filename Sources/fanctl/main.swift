import Foundation
import IOKit.ps
import SMCKit

// ============================================================
// fanctl — MacFanControl 命令行工具 / 守护进程
//
//   fanctl sensors            列出温度传感器
//   fanctl fans               列出风扇状态
//   fanctl keys [前缀]        列出 SMC 键
//   fanctl status             查看控制状态(经守护进程)
//   fanctl set ...            修改控制配置(需守护进程运行)
//   fanctl restore            恢复系统自动控制
//   sudo fanctl test 风扇 转速  直接控制测试(验证写权限)
//   sudo fanctl install       安装 root 守护进程(开机自启)
//   sudo fanctl uninstall     卸载守护进程
//   fanctl daemon             前台运行守护进程(launchd 调用)
//   fanctl log [行数]          查看守护进程日志
// ============================================================

var gQuit = false

func main() {
    signal(SIGPIPE, SIG_IGN)   // 往已断开的 socket 写数据不得杀进程(否则会被轮询客户端的提前断开反复打死)
    let args = Array(CommandLine.arguments.dropFirst())
    let cmd = args.first ?? "help"

    switch cmd {
    case "sensors": cmdSensors()
    case "fans": cmdFans()
    case "keys": cmdKeys(prefix: args.count > 1 ? args[1] : nil)
    case "status": cmdStatus()
    case "set": cmdSet(args)
    case "restore": cmdRestore()
    case "test": cmdTest(args)
    case "daemon": Daemon().run()
    case "install": cmdInstall()
    case "uninstall": cmdUninstall()
    case "log": cmdLog(lines: args.count > 1 ? Int(args[1]) ?? 40 : 40)
    case "help", "-h", "--help": printHelp()
    default:
        print("未知命令: \(cmd)\n")
        printHelp()
        exit(64)
    }
}

func printHelp() {
    print("""
    MacFanControl fanctl — macOS 风扇温度自动控制

    常用命令:
      fanctl sensors                    查看温度传感器
      fanctl fans                       查看风扇状态
      fanctl status                     查看控制状态
      fanctl set enable on|off          启用/停用自动控制
      fanctl set mode auto|manual       自动曲线 / 手动转速
      fanctl set curve 60 85            设置起转温度与全速温度 (°C)
      fanctl set rpm <风扇> <转速>      手动模式下设定转速
      fanctl set min <风扇> <转速>      自动模式下的最低转速
      fanctl set sensors TC10,TG0B     指定控制传感器(留空 default 恢复默认)
      fanctl restore                    恢复系统自动控制
      fanctl log                        查看日志
      sudo fanctl test 0 3500           直接控制测试(验证写权限)
      sudo fanctl install               安装守护进程(开机自启)
      sudo fanctl uninstall             卸载守护进程
    """)
}

func openSMC() -> SMC {
    do { return try SMC() } catch {
        fputs("错误: \(error)\n", stderr)
        exit(1)
    }
}

// MARK: - 只读命令

func cmdSensors() {
    let smc = openSMC()
    let temps = smc.readTemperatures()
    guard !temps.isEmpty else { print("未读到温度传感器"); return }
    print(String(format: "%-16@ %-6@ %@", "传感器", "键", "温度"))
    let defaultKeys = Set(SMC.defaultControlSensors(for: temps.map(\.key)))
    for t in temps {
        let mark = defaultKeys.contains(t.key) ? " *" : ""
        print(String(format: "%-16@ %-6@ %5.1f°C%@", t.label, t.key, t.value, mark))
    }
    print("\n(* 为默认控制传感器,取其中的最大值)")
}

func cmdFans() {
    let smc = openSMC()
    guard let fans = try? smc.readFans(), !fans.isEmpty else {
        print("未检测到风扇(无风扇机型如 MacBook Air 不适用)")
        return
    }
    for f in fans {
        let modeName = ["自动", "手动", "?", "系统"][max(0, min(3, f.mode))]
        print(String(format: "%@  当前 %5.0f RPM  范围 %.0f–%.0f  目标 %.0f  模式:%@",
                     f.name, f.rpm, f.min, f.max, f.target, modeName))
    }
}

func cmdKeys(prefix: String?) {
    let smc = openSMC()
    for k in smc.allKeys() {
        if let p = prefix, !k.description.hasPrefix(p) { continue }
        guard let info = try? smc.keyInfo(k) else { continue }
        let d = (try? smc.read(k)) ?? Data()
        let v = SMCValue.decode(d, typeName: info.typeName)
        let shown: String
        if let dv = v.doubleValue { shown = String(format: "%.2f", dv) }
        else { shown = d.prefix(8).map { String(format: "%02x", Int($0)) }.joined() }
        print(String(format: "%-5@ %-5@ sz=%-3d %@", k.description, info.typeName, info.dataSize, shown))
    }
}

// MARK: - 状态 / 配置

func cmdStatus() {
    if let resp = FanClient.status(), resp["ok"] as? Bool == true {
        print("守护进程: 运行中")
        if let temp = resp["controlTemp"] as? Double {
            print(String(format: "控制温度: %.1f °C", temp))
        }
        if let fans = resp["fans"] as? [[String: Any]] {
            for f in fans {
                print(String(format: "风扇 %d: %.0f RPM(目标 %.0f,范围 %.0f–%.0f,写入:%@)",
                             (f["index"] as? Int ?? 0) + 1,
                             f["rpm"] as? Double ?? 0,
                             f["written"] as? Double ?? f["target"] as? Double ?? 0,
                             f["min"] as? Double ?? 0,
                             f["max"] as? Double ?? 0,
                             (f["verified"] as? Bool ?? false) ? "已生效" : "未验证"))
            }
        }
        if let cfg = resp["config"] as? [String: Any] {
            let enabled = cfg["enabled"] as? Bool ?? false
            let mode = cfg["mode"] as? String ?? "auto"
            let ts = cfg["tempStart"] as? Double ?? 0
            let tf = cfg["tempFull"] as? Double ?? 0
            print("控制: \(enabled ? "已启用" : "已停用") / \(mode == "manual" ? "手动转速" : "自动曲线 \(Int(ts))–\(Int(tf))°C")")
        }
        if let controlled = resp["controlled"] as? Bool {
            print(controlled ? "风扇控制: 已接管" : "风扇控制: 未生效(查看 fanctl log)")
        }
    } else {
        print("守护进程未运行,直接读取硬件:")
        let smc = openSMC()
        if let fans = try? smc.readFans() {
            for f in fans {
                print(String(format: "%@  当前 %.0f RPM  范围 %.0f–%.0f", f.name, f.rpm, f.min, f.max))
            }
        }
        let temps = smc.readTemperatures()
        if let hottest = temps.first {
            print(String(format: "最高温度: %@ %.1f °C", hottest.label, hottest.value))
        }
        print("\n安装守护进程:sudo fanctl install")
    }
}

func cmdSet(_ args: [String]) {
    // args[0] == "set"
    guard args.count >= 2 else { print("用法见 fanctl help"); exit(64) }
    var patch: [String: Any] = [:]
    let sub = args[1]
    func need(_ n: Int) -> [String] {
        guard args.count >= 2 + n else { print("参数不足,用法见 fanctl help"); exit(64) }
        return Array(args[2..<2 + n])
    }
    switch sub {
    case "enable":
        let v = need(1)[0]
        patch["enabled"] = (v == "on" || v == "true" || v == "1")
    case "mode":
        patch["mode"] = need(1)[0] == "manual" ? "manual" : "auto"
    case "curve":
        let a = need(2)
        patch["tempStart"] = Double(a[0])
        patch["tempFull"] = Double(a[1])
    case "rpm":
        let a = need(2)
        var m = ((FanClient.status()?["config"] as? [String: Any])?["manualRPM"] as? [String: Double]) ?? [:]
        m[a[0]] = Double(a[1])
        patch["manualRPM"] = m
    case "min":
        let a = need(2)
        var m = ((FanClient.status()?["config"] as? [String: Any])?["minRPM"] as? [String: Double]) ?? [:]
        m[a[0]] = Double(a[1])
        patch["minRPM"] = m
    case "sensors":
        let v = args.count > 2 ? args[2] : "default"
        patch["sensors"] = v == "default" ? [] : v.split(separator: ",").map(String.init)
    default:
        print("未知子命令: \(sub)"); exit(64)
    }
    if let resp = FanClient.set(config: patch), resp["ok"] as? Bool == true {
        print("已更新")
        if let err = resp["error"] as? String, !err.isEmpty { print("警告: \(err)") }
    } else {
        print("失败:守护进程未运行?请先 sudo fanctl install")
        exit(1)
    }
}

func cmdRestore() {
    if let resp = FanClient.request(FanProtocol.makeRequest(cmd: "restore")),
       resp["ok"] as? Bool == true {
        print("已恢复系统自动控制(配置保留,可随时 set enable on 重新启用)")
    } else {
        print("守护进程未运行,无需恢复")
    }
}

func cmdLog(lines: Int) {
    let path = Paths.logFile
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("暂无日志(\(path))")
        return
    }
    let all = content.split(separator: "\n")
    for l in all.suffix(lines) { print(l) }
}

// MARK: - 写入测试

func cmdTest(_ args: [String]) {
    guard FanAccess.isRoot else {
        print("需要 root:sudo fanctl test 0 3500")
        exit(1)
    }
    let fanIdx = args.count > 1 ? Int(args[1]) ?? 0 : 0
    let rpm = args.count > 2 ? Double(args[2]) ?? 3500 : 3500
    let smc = openSMC()
    guard let fans = try? smc.readFans(), fans.indices.contains(fanIdx) else {
        print("无此风扇"); exit(1)
    }
    let f = fans[fanIdx]
    let clamped = min(max(rpm, 500), f.max)
    print(String(format: "风扇 %d 当前 %.0f RPM,范围 %.0f–%.0f,尝试设定 %.0f RPM…",
                 fanIdx + 1, f.rpm, f.min, f.max, clamped))
    let writer = FanWriter(smc: smc)
    do {
        try writer.hold(fanIdx)
        defer { writer.release(fanIdx) }
        for i in 0..<10 {
            try writer.writeTarget(fanIdx, rpm: clamped)
            let now = (try? smc.readFans()) ?? fans
            print(String(format: "%2ds  目标 %.0f  实际 %.0f RPM",
                         i, clamped, now[fanIdx].rpm))
            Thread.sleep(forTimeInterval: 1)
        }
        print("完成,已恢复自动模式")
    } catch {
        print("写入失败: \(error)")
        exit(1)
    }
}

// MARK: - 安装/卸载

func runLaunchctl(_ arguments: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = arguments
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

func cmdInstall() {
    guard FanAccess.isRoot else {
        print("需要 root:sudo fanctl install")
        exit(1)
    }
    let fm = FileManager.default
    let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path

    do {
        try fm.createDirectory(atPath: Paths.installDir, withIntermediateDirectories: true)
        // 复制自身到安装目录(已在安装目录中运行则跳过)
        if selfPath != Paths.daemonBinary {
            if fm.fileExists(atPath: Paths.daemonBinary) {
                try fm.removeItem(atPath: Paths.daemonBinary)
            }
            try fm.copyItem(atPath: selfPath, toPath: Paths.daemonBinary)
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.daemonBinary)

        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(Paths.daemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(Paths.daemonBinary)</string>
                <string>daemon</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>ProcessType</key><string>Background</string>
        </dict>
        </plist>
        """
        try plist.write(toFile: Paths.launchdPlist, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: Paths.launchdPlist)

        // 重新启动守护进程
        _ = runLaunchctl(["bootout", "system", Paths.launchdPlist])
        Thread.sleep(forTimeInterval: 0.3)
        let r = runLaunchctl(["bootstrap", "system", Paths.launchdPlist])
        guard r == 0 else { throw SMCError.badData("launchctl bootstrap 失败 (\(r))") }
        Thread.sleep(forTimeInterval: 1)
        print("✅ 守护进程已安装并启动(开机自启)")
        print("   配置文件: \(Paths.configFile)")
        print("   日志:     \(Paths.logFile)")
        print("   状态:     fanctl status")
    } catch {
        print("安装失败: \(error)")
        exit(1)
    }
}

func cmdUninstall() {
    guard FanAccess.isRoot else {
        print("需要 root:sudo fanctl uninstall")
        exit(1)
    }
    _ = runLaunchctl(["bootout", "system", Paths.launchdPlist])
    let fm = FileManager.default
    Thread.sleep(forTimeInterval: 0.3)
    try? fm.removeItem(atPath: Paths.launchdPlist)
    try? fm.removeItem(atPath: Paths.installDir)
    print("✅ 已卸载守护进程,系统恢复默认控制")
}

// MARK: - 守护进程

final class Daemon {
    private let smc: SMC
    private var writer: FanWriter?
    private let logger = SimpleLogger()
    private var config: Config
    private var tempKeys: [SMCKey] = []
    private var defaultMin: [Int: Double] = [:]
    private let startedAt = Date()
    private let lock = NSLock()
    private var ready = false
    private var lastTickEnd = Date()   // 看门狗心跳:SMC 调用可能永久卡死,超时自杀等 launchd 拉起
    private var tempCache: [SensorReading] = []      // 全量温度(约 8 秒刷新一次,供 GUI 展示)
    private var selectedTempKeys: [SMCKey] = []      // 控制循环只读这些键
    private var sweepTick = 0

    private var controlled = false
    private var lastWritten: [Int: Double] = [:]
    private var lastWriteTime: [Int: Date] = [:]
    private var fanVerified: [Int: Bool] = [:]
    private var peakTemp: [Int: Double] = [:]        // 回滞用:触发当前转速的温度峰值
    private var controlTemp: Double = 0
    private var server: JSONLineServer?
    private var onAC = true                          // 电源状态(电池时切换 batteryCurves)
    private var lastNightActive = false

    init() {
        do {
            smc = try SMC()
        } catch {
            fputs("错误: \(error)\n", stderr)
            exit(1)
        }
        config = Config.load()
    }

    func run() {
        signal(SIGTERM) { _ in gQuit = true }
        signal(SIGINT) { _ in gQuit = true }
        signal(SIGHUP) { _ in }   // 忽略挂断

        logger.log("fanctl 守护进程启动 (root=\(FanAccess.isRoot), AppleSilicon=\(FanAccess.isAppleSilicon))")
        if !FanAccess.isRoot {
            logger.log("警告: 非 root 运行(测试模式),风扇写入将失败")
        }

        // 看门狗先行(初始化/任意 tick 卡死即退出,launchd KeepAlive 负责拉起)
        lastTickEnd = Date()
        Thread.detachNewThread { [weak self] in
            while !gQuit {
                Thread.sleep(forTimeInterval: 10)
                guard let self else { return }
                let stale = Date().timeIntervalSince(self.lastTickEnd)
                let limit = self.locked { max(self.config.interval * 3, 20) + 10 }
                if stale > limit {
                    self.logger.log(String(format: "看门狗: 心跳停摆 %.0f 秒(SMC 调用卡死),自杀重启", stale))
                    exit(1)
                }
            }
        }

        // 先把 socket 起来,让 GUI 立刻能连上(初始化期间返回 starting 状态),
        // 避免 GUI 误判"未安装"而诱导反复重装输密码
        do {
            let server = JSONLineServer(path: Paths.serverSocket) { [weak self] req in
                self?.handleRequest(req) ?? ["ok": false, "error": "daemon 不可用"]
            }
            try server.start()
            self.server = server
        } catch {
            logger.log("socket 启动失败: \(error)")
        }

        // 慢初始化:枚举全部 SMC 键(约 1-2 秒),只做一次,写入器共用结果
        let allKeys = smc.allKeys()
        tempKeys = allKeys.filter { $0.description.hasPrefix("T") }
        writer = FanWriter(smc: smc, allKeys: allKeys)
        if let fans = try? smc.readFans() {
            defaultMin = Dictionary(uniqueKeysWithValues: fans.map { ($0.index, $0.min) })
        }
        locked { ready = true }
        logger.log("初始化完成,开始控制")

        // 主循环
        while !gQuit {
            let interval: Double = locked { config.interval }
            locked { tickLocked() }
            locked { lastTickEnd = Date() }
            let deadline = Date().addingTimeInterval(interval)
            while !gQuit && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        restoreAndExit()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func tickLocked() {
        guard ready, let writer = writer else { return }
        let cfg = config
        // 全量温度扫描降频(每 4 轮一次,仅用于展示缓存);
        // 控制温度只实时读选中的传感器,SMC 调用量从 ~200 次/轮降到 ~20 次/轮
        sweepTick += 1
        if sweepTick % 4 == 0 || tempCache.isEmpty {
            tempCache = smc.readTemperatures(cachedKeys: tempKeys)
            refreshSelectedKeys(cfg: cfg)
        }
        guard let fans = try? smc.readFans() else {
            logger.log("读取风扇失败")
            return
        }
        var live = 0.0
        for k in selectedTempKeys {
            if let v = try? smc.readDouble(k), v > live { live = v }
        }
        controlTemp = live > 0 ? live : Self.controlTemperature(temps: tempCache, config: cfg)

        // 电源/夜间状态跟踪(切换时记日志,便于回查"为什么转速变了")
        let ac = Self.readACPower()
        if ac != onAC {
            onAC = ac
            logger.log(ac ? "电源:已接入电源适配器" : "电源:切换到电池\(cfg.batteryCurves.isEmpty ? "(沿用常规曲线)" : ",启用电池曲线")")
        }
        let night = cfg.nightActive()
        if night != lastNightActive {
            lastNightActive = night
            if let nm = cfg.nightMode {
                logger.log("夜间模式\(night ? "生效(\(nm.timeText) 预设 \(nm.preset))" : "结束")")
            }
        }

        // 已停用:确保释放控制,其余只上报
        guard cfg.enabled, !fans.isEmpty else {
            if writer.holdingCount > 0 {
                writer.releaseAll()
                logger.log("已释放风扇控制,交还系统")
            }
            controlled = false
            return
        }

        controlled = applyControl(writer: writer, config: cfg, fans: fans)
    }

    /// 是否使用外接电源(无电池信息时按有电处理)
    static func readACPower() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return true
        }
        for src in list {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, src)?.takeUnretainedValue()
                    as? [String: Any],
                  let state = desc[kIOPSPowerSourceStateKey as String] as? String else { continue }
            return state == kIOPSACPowerValue as String
        }
        return true
    }

    /// 计算并写入各风扇目标转速。
    /// 验证是被动式的:下一轮读回 F%dTg 与上轮写入一致即视为生效;
    /// 若被系统改写(thermalmonitord 抢写)则本轮重写。
    /// 降温方向带 1.5°C 回滞:温度未真正回落前维持转速,避免阈值附近抖动。
    private func applyControl(writer: FanWriter, config cfg: Config, fans: [FanInfo]) -> Bool {
        let force = !controlled   // 上一轮未生效则本轮强制重写
        let activeCurves = config.effectiveCurves(onAC: onAC)
        let night = config.nightActive()
        for f in fans {
            if let w = lastWritten[f.index] {
                let stuck = abs(f.target - w) < max(100, w * 0.05)
                if !stuck { lastWritten[f.index] = nil }
            }
            let floor = max(500, min(f.max, cfg.minRPM["\(f.index)"] ?? defaultMin[f.index] ?? f.min))
            var target: Double
            if cfg.mode == "manual" {
                target = min(max(cfg.manualRPM["\(f.index)"] ?? floor, 500), f.max)
            } else if night {
                // 夜间窗口:忽略自定义曲线,直接用预设两点(安静优先,温度过高仍会拉满)
                let p = Config.presetRange(cfg.nightMode?.preset ?? "quiet")
                target = FanCurve.target(temp: controlTemp, tempStart: p.start, tempFull: p.full,
                                         lo: floor, hi: f.max)
            } else if let curve = activeCurves["\(f.index)"], curve.count >= 2 {
                target = min(max(FanCurve.target(points: curve, temp: controlTemp), 500), f.max)
            } else {
                target = FanCurve.target(temp: controlTemp,
                                         tempStart: cfg.tempStart,
                                         tempFull: cfg.tempFull,
                                         lo: floor, hi: f.max)
            }
            // 回滞:目标要下降时,要求温度比峰值至少回落 1.5°C
            if let last = lastWritten[f.index], target < last - 25 {
                let peak = peakTemp[f.index] ?? controlTemp
                if controlTemp > peak - 1.5 {
                    target = last
                } else {
                    peakTemp[f.index] = controlTemp
                }
            } else {
                peakTemp[f.index] = controlTemp
            }

            let shouldWrite = force
                || lastWritten[f.index] == nil
                || abs(target - lastWritten[f.index]!) > 25
                || Date().timeIntervalSince(lastWriteTime[f.index] ?? .distantPast) > 8
            guard shouldWrite else { continue }

            do {
                try writer.hold(f.index)
                try writer.writeTarget(f.index, rpm: target)
                lastWritten[f.index] = target
                lastWriteTime[f.index] = Date()
                if fanVerified[f.index] != true {
                    logger.log(String(format: "风扇 %d 控制生效(目标 %.0f RPM)", f.index + 1, target))
                }
                fanVerified[f.index] = true
            } catch {
                if fanVerified[f.index] != false {
                    logger.log("风扇 \(f.index + 1) 写入失败: \(error)")
                }
                fanVerified[f.index] = false
                lastWritten[f.index] = nil
            }
        }
        return !fans.isEmpty && !fanVerified.values.contains(false)
    }

    /// 依据配置(或默认集合)解析控制循环要实时读取的传感器键
    private func refreshSelectedKeys(cfg: Config) {
        let allNames = tempKeys.map(\.description)
        let names = (cfg.sensors?.isEmpty == false) ? cfg.sensors! : SMC.defaultControlSensors(for: allNames)
        let nameSet = Set(names)
        selectedTempKeys = tempKeys.filter { nameSet.contains($0.description) }
    }

    static func controlTemperature(temps: [SensorReading], config cfg: Config) -> Double {
        let selected: [String]
        if let s = cfg.sensors, !s.isEmpty {
            selected = s
        } else {
            selected = SMC.defaultControlSensors(for: temps.map(\.key))
        }
        let values = temps.filter { selected.contains($0.key) }.map(\.value)
        return values.max() ?? 0
    }

    // MARK: - socket 请求

    private func handleRequest(_ req: [String: Any]) -> [String: Any] {
        locked {
            let cmd = req["cmd"] as? String ?? ""
            switch cmd {
            case "status":
                if !ready { return ["ok": true, "starting": true] }
                return buildStatusLocked()
            case "set":
                if !ready { return ["ok": false, "error": "守护进程启动中,请稍候"] }
                if let c = req["config"] as? [String: Any] {
                    let patch = ConfigPatch(from: c)
                    config.apply(patch: patch)
                    refreshSelectedKeys(cfg: config)
                    try? config.save()
                    logger.log("配置更新: \(c.keys.sorted().joined(separator: ","))")
                    return buildStatusLocked()
                }
                return ["ok": false, "error": "缺少 config"]
            case "restore":
                config.enabled = false
                try? config.save()
                writer?.releaseAll()
                logger.log("用户请求恢复系统控制")
                return ["ok": true]
            default:
                return ["ok": false, "error": "未知命令 \(cmd)"]
            }
        }
    }

    private func buildStatusLocked() -> [String: Any] {
        let cfg = config
        var fansPayload = [[String: Any]]()
        if let fans = try? smc.readFans() {
            for f in fans {
                fansPayload.append([
                    "index": f.index,
                    "rpm": f.rpm,
                    "min": f.min,
                    "max": f.max,
                    "target": f.target,
                    "mode": f.mode,
                    "written": lastWritten[f.index] ?? f.target,
                    "verified": controlled,
                ])
            }
        }
        let temps = tempCache
        var tempsDict = [String: Double]()
        for t in temps.prefix(60) { tempsDict[t.key] = t.value }

        var configDict = [String: Any]()
        if let data = try? JSONEncoder().encode(cfg),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            configDict = obj
        }
        return [
            "ok": true,
            "root": FanAccess.isRoot,
            "controlled": controlled,
            "holding": writer?.holdingCount ?? 0,
            "controlTemp": controlTemp,
            "onAC": onAC,
            "nightActive": lastNightActive,
            "temps": tempsDict,
            "sensorsSelected": Self.controlTemperature(temps: temps, config: cfg) > 0
                ? (cfg.sensors ?? SMC.defaultControlSensors(for: temps.map(\.key)))
                : [],
            "fans": fansPayload,
            "config": configDict,
            "since": startedAt.timeIntervalSince1970,
        ]
    }

    private func restoreAndExit() {
        logger.log("收到退出信号,恢复系统控制")
        writer?.releaseAll()
        server?.stop()
        exit(0)
    }
}

main()
