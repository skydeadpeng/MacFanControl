import Foundation
import WidgetKit
import SwiftUI

// ============================================================
// FanBar 桌面小组件(macOS 14+)
//   - 小部件:温度 + 风扇转速 + CPU
//   - 中部件:温度/风扇/CPU/内存/网速/电池 概览
// 数据源:优先连守护进程 socket(/var/run/macfanctl.sock);
//        守护进程离线时直读 SMC(编译进本扩展的 SMCKit 源码)。
// 刷新:系统策略 5 分钟兜底;FanBar 运行时每约 1 分钟主动 reload。
// ============================================================

enum WL {
    static let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
    static func t(_ zh: String, _ en: String) -> String { isChinese ? zh : en }
}

/// 数据读取(进程内单例:跨刷新保留差值状态与 SMC 连接)
final class WidgetReader {
    struct Reading {
        var temp = 0.0
        var rpm = 0.0
        var hasFans = false
        var cpu = 0.0
        var memPercent = 0.0
        var netIn = 0.0
        var netOut = 0.0
        var batteryPercent = 0.0
        var batteryWatts = 0.0
        var batteryCharging = false
        var hasBattery = false
        var daemonOnline = false
    }

    static let shared = WidgetReader()
    private let stats = SystemStats()
    private var smc: SMC?
    private var tempKeys: [SMCKey] = []

    func read() -> Reading {
        var r = Reading()
        let snap = stats.sample()
        r.cpu = snap.cpuUsage * 100
        r.memPercent = snap.memPercent * 100
        r.netIn = snap.netIn
        r.netOut = snap.netOut
        if snap.battery.present {
            r.hasBattery = true
            r.batteryPercent = snap.battery.percent
            r.batteryWatts = snap.battery.watts
            r.batteryCharging = snap.battery.chargeIn
        }
        if let resp = FanClient.status(), resp["ok"] as? Bool == true,
           resp["starting"] as? Bool != true {
            r.daemonOnline = true
            r.temp = resp["controlTemp"] as? Double ?? 0
            if let fans = resp["fans"] as? [[String: Any]], !fans.isEmpty {
                r.hasFans = true
                r.rpm = fans.compactMap { $0["rpm"] as? Double }.max() ?? 0
            }
        } else {
            // 直读 SMC(首次枚举全部键约 1-2 秒,之后复用)
            if smc == nil {
                if let s = try? SMC() {
                    smc = s
                    tempKeys = s.allKeys().filter { $0.description.hasPrefix("T") }
                }
            }
            if let s = smc {
                let temps = s.readTemperatures(cachedKeys: tempKeys)
                let defaults = Set(SMC.defaultControlSensors(for: temps.map(\.key)))
                r.temp = temps.filter { defaults.contains($0.key) }.map(\.value).max() ?? 0
                if let fans = try? s.readFans(), !fans.isEmpty {
                    r.hasFans = true
                    r.rpm = fans.map(\.rpm).max() ?? 0
                }
            }
        }
        return r
    }
}

// MARK: - 时间线

struct FanWidgetEntry: TimelineEntry {
    let date: Date
    let reading: WidgetReader.Reading

    static let sample = FanWidgetEntry(date: Date(),
                                       reading: {
                                           var r = WidgetReader.Reading()
                                           r.temp = 67; r.rpm = 2950; r.hasFans = true
                                           r.cpu = 34; r.memPercent = 71
                                           r.netIn = 1.2 * 1024 * 1024; r.netOut = 260 * 1024
                                           r.hasBattery = true; r.batteryPercent = 85
                                           r.batteryWatts = 8.4
                                           return r
                                       }())
}

struct FanProvider: TimelineProvider {
    func placeholder(in context: Context) -> FanWidgetEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (FanWidgetEntry) -> Void) {
        completion(FanWidgetEntry(date: Date(), reading: WidgetReader.shared.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FanWidgetEntry>) -> Void) {
        let entry = FanWidgetEntry(date: Date(), reading: WidgetReader.shared.read())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(300))))
    }
}

// MARK: - 视图

private func speedText(_ b: Double) -> String {
    if b >= 1_048_576 { return String(format: "%.1fM", b / 1_048_576) }
    if b >= 1024 { return String(format: "%.0fK", b / 1024) }
    return String(format: "%.0f", max(0, b))
}

private func tempColor(_ t: Double) -> Color {
    switch t {
    case ..<60: return .blue
    case ..<80: return .green
    case ..<92: return .orange
    default: return .red
    }
}

private var widgetBackground: some View {
    LinearGradient(colors: [Color.red.opacity(0.16), Color.orange.opacity(0.06)],
                   startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct SmallWidgetView: View {
    let e: FanWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: e.reading.temp >= 90 ? "thermometer.high" : "thermometer.medium")
                    .foregroundStyle(tempColor(e.reading.temp))
                Text("FanBar").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if !e.reading.daemonOnline && e.reading.temp > 0 {
                    Image(systemName: "eye").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Text(e.reading.temp > 0 ? String(format: "%.0f°", e.reading.temp) : "--°")
                .font(.system(size: 42, weight: .semibold, design: .rounded))
                .foregroundStyle(tempColor(e.reading.temp))
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if e.reading.hasFans {
                    Label("\(Int(e.reading.rpm))", systemImage: "fan.below.radiators")
                        .monospacedDigit()
                } else {
                    Text(WL.t("无风扇", "No fan")).foregroundStyle(.secondary)
                }
                Spacer()
                Text("CPU \(Int(e.reading.cpu))%").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .containerBackground(for: .widget) { widgetBackground }
    }
}

struct OverviewWidgetView: View {
    let e: FanWidgetEntry

    private func cell(_ icon: String, _ title: String, _ value: String, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.medium))
                .monospacedDigit()
                .foregroundStyle(tint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: e.reading.temp >= 90 ? "thermometer.high" : "thermometer.medium")
                    .foregroundStyle(tempColor(e.reading.temp))
                Text("FanBar").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(WL.t("温度/CPU/内存/网速/电池", "Temp/CPU/Mem/Net/Battery"))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            HStack(spacing: 12) {
                cell("thermometer.medium", WL.t("温度", "Temp"),
                     e.reading.temp > 0 ? String(format: "%.1f°", e.reading.temp) : "--",
                     tint: tempColor(e.reading.temp))
                cell("cpu", "CPU", "\(Int(e.reading.cpu))%",
                     tint: e.reading.cpu > 85 ? .red : nil)
                cell("memorychip", WL.t("内存", "Mem"), "\(Int(e.reading.memPercent))%",
                     tint: e.reading.memPercent > 90 ? .red : nil)
            }
            HStack(spacing: 12) {
                if e.reading.hasFans {
                    cell("fan.below.radiators", WL.t("风扇", "Fan"), "\(Int(e.reading.rpm)) rpm")
                } else {
                    cell("gauge.with.needle", WL.t("网速", "Net"),
                         "↓\(speedText(e.reading.netIn)) ↑\(speedText(e.reading.netOut))")
                }
                if e.reading.hasFans {
                    cell("gauge.with.needle", WL.t("网速", "Net"),
                         "↓\(speedText(e.reading.netIn)) ↑\(speedText(e.reading.netOut))")
                }
                if e.reading.hasBattery {
                    cell(e.reading.batteryCharging ? "bolt.fill" : "battery.75",
                         WL.t("电池", "Battery"),
                         e.reading.batteryWatts > 0.5
                            ? String(format: "%d%% %@%.1fW", Int(e.reading.batteryPercent),
                                     e.reading.batteryCharging ? "+" : "−", e.reading.batteryWatts)
                            : "\(Int(e.reading.batteryPercent))%",
                         tint: e.reading.batteryPercent < 20 && !e.reading.batteryCharging ? .red : nil)
                }
            }
        }
        .containerBackground(for: .widget) { widgetBackground }
    }
}

// MARK: - 小组件注册

struct FanSmallWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MacFanControl.TempFan", provider: FanProvider()) { entry in
            SmallWidgetView(e: entry)
        }
        .configurationDisplayName(WL.t("温度与风扇", "Temp & Fan"))
        .description(WL.t("当前控制温度、风扇转速与 CPU 占用(需 macOS 14+)",
                          "Live temp, fan RPM and CPU (macOS 14+)"))
        .supportedFamilies([.systemSmall])
    }
}

struct FanOverviewWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MacFanControl.Overview", provider: FanProvider()) { entry in
            OverviewWidgetView(e: entry)
        }
        .configurationDisplayName(WL.t("系统概览", "System Overview"))
        .description(WL.t("温度/风扇/CPU/内存/网速/电池一屏总览(需 macOS 14+)",
                          "Temp, fan, CPU, memory, network and battery at a glance (macOS 14+)"))
        .supportedFamilies([.systemMedium])
    }
}

@main
struct FanBarWidgetBundle: WidgetBundle {
    var body: some Widget {
        FanSmallWidget()
        FanOverviewWidget()
    }
}
