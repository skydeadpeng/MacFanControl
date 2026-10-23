import SwiftUI
import Charts

/// 7 天逐小时温度/风扇趋势窗口
struct TrendWindowView: View {
    @EnvironmentObject var model: FanModel

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
            return HourPoint(t: Date(timeIntervalSince1970: h), avg: sum / cnt,
                             min: min, max: max, fan: b["fan"] as? Double ?? 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.t("温度趋势(近 7 天,逐小时)", "Temperature trend (7 days, hourly)"))
                    .font(.headline)
                Spacer()
                Text(L.t("数据随后台运行持续积累", "Data accumulates while running"))
                    .font(.caption).foregroundStyle(.secondary)
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
                    AreaMark(x: .value("时间", p.t), yStart: .value("最低", p.min), yEnd: .value("最高", p.max))
                        .foregroundStyle(Color.red.opacity(0.12))
                    LineMark(x: .value("时间", p.t), y: .value("平均", p.avg))
                        .foregroundStyle(Color.red)
                    LineMark(x: .value("时间", p.t), y: .value("风扇", p.fan / 60))
                        .foregroundStyle(Color.green.opacity(0.7))
                }
                .chartYScale(domain: 0...110)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 1)) { v in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month().day())
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal)

                HStack(spacing: 12) {
                    Text("— 小时均温°C").foregroundStyle(.red)
                    Text("— 小时最低~最高").foregroundStyle(.red.opacity(0.4))
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
