import SwiftUI
import Charts

/// 7 天逐小时趋势窗口(温度/CPU/GPU 多指标切换)
struct TrendWindowView: View {
    @EnvironmentObject var model: FanModel
    @State private var metric = "temp"

    private struct HourPoint: Identifiable {
        let id = UUID()
        let t: Date
        let avg: Double
        let min: Double
        let max: Double
        let fan: Double
    }

    private var points: [HourPoint] {
        model.hourlyTrend.compactMap { b in
            guard let h = b["h"] as? Double,
                  let min = b["min"] as? Double,
                  let max = b["max"] as? Double,
                  let cnt = b["cnt"] as? Double, cnt > 0,
                  let sum = b["sum"] as? Double else { return nil }
            let avg: Double
            switch metric {
            case "cpu": avg = (b["cpuSum"] as? Double ?? 0) / cnt
            case "gpu": avg = (b["gpuSum"] as? Double ?? 0) / cnt
            default: avg = sum / cnt
            }
            return HourPoint(t: Date(timeIntervalSince1970: h), avg: avg,
                             min: min, max: max, fan: b["fan"] as? Double ?? 0)
        }
    }

    /// 指标对应的曲线主色与 Y 轴上限(CPU/GPU 无 min-max 带,只画均值线)
    private var mainColor: Color { metric == "temp" ? .red : (metric == "cpu" ? .blue : .purple) }
    private var yMax: Double { metric == "temp" ? 110 : 100 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.t("趋势(近 7 天,逐小时)", "Trends (7 days, hourly)"))
                    .font(.headline)
                Picker("", selection: $metric) {
                    Text(L.t("温度", "Temp")).tag("temp")
                    Text("CPU").tag("cpu")
                    Text("GPU").tag("gpu")
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 180)
                Spacer()
                Button(L.t("导出 CSV…", "Export CSV…")) { model.exportCSV() }
                    .controlSize(.small)
                if let msg = model.message {
                    Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding([.top, .horizontal])

            if points.count < 2 {
                Spacer()
                Text(L.t("数据还不够,运行一段时间后再看(每小时记一个点)",
                         "Not enough data yet — check back after running for a while"))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                Chart(points) { p in
                    if metric == "temp" {
                        AreaMark(x: .value("时间", p.t), yStart: .value("最低", p.min), yEnd: .value("最高", p.max))
                            .foregroundStyle(mainColor.opacity(0.12))
                    }
                    LineMark(x: .value("时间", p.t), y: .value("平均", p.avg))
                        .foregroundStyle(mainColor)
                    LineMark(x: .value("时间", p.t), y: .value("风扇", p.fan / 60))
                        .foregroundStyle(Color.green.opacity(0.7))
                }
                .chartYScale(domain: 0...yMax)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 1)) { v in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month().day())
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal)

                HStack(spacing: 12) {
                    if metric == "temp" {
                        Text("— 小时均温°C").foregroundStyle(mainColor)
                        Text("— 小时最低~最高").foregroundStyle(mainColor.opacity(0.4))
                    } else {
                        Text(metric == "cpu" ? "— 小时平均 CPU%" : "— 小时平均 GPU%")
                            .foregroundStyle(mainColor)
                    }
                    Text("— 风扇RPM(÷60)").foregroundStyle(.green)
                    Spacer()
                }
                .font(.caption2)
                .padding([.horizontal, .bottom])
            }
        }
        .frame(minWidth: 720, minHeight: 380)
    }
}
