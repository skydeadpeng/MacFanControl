import XCTest
@testable import SMCKit

final class FanCurveTests: XCTestCase {

    func testTwoPointLine() {
        // 经典两点直线:60°C 起转 1500,85°C 全速 5350
        let v = FanCurve.target(temp: 72.5, tempStart: 60, tempFull: 85, lo: 1500, hi: 5350)
        XCTAssertEqual(v, 3425, accuracy: 0.001)
    }

    func testTwoPointClamp() {
        XCTAssertEqual(FanCurve.target(temp: 30, tempStart: 60, tempFull: 85, lo: 1500, hi: 5350), 1500)
        XCTAssertEqual(FanCurve.target(temp: 99, tempStart: 60, tempFull: 85, lo: 1500, hi: 5350), 5350)
    }

    func testMultiPointInterpolation() {
        let pts = [CurvePoint(temp: 50, rpm: 1200),
                   CurvePoint(temp: 70, rpm: 2000),
                   CurvePoint(temp: 90, rpm: 5000)]
        // 60°C 在第一段中点 → 1600
        XCTAssertEqual(FanCurve.target(points: pts, temp: 60), 1600, accuracy: 0.001)
        // 80°C 在第二段中点 → 3500
        XCTAssertEqual(FanCurve.target(points: pts, temp: 80), 3500, accuracy: 0.001)
        // 首尾钳制
        XCTAssertEqual(FanCurve.target(points: pts, temp: 20), 1200)
        XCTAssertEqual(FanCurve.target(points: pts, temp: 120), 5000)
    }

    func testMultiPointUnsortedInput() {
        // 乱序输入应与排序输入等价
        let sorted = [CurvePoint(temp: 40, rpm: 1000), CurvePoint(temp: 80, rpm: 4000)]
        let shuffled = Array(sorted.reversed())
        XCTAssertEqual(FanCurve.target(points: shuffled, temp: 60),
                       FanCurve.target(points: sorted, temp: 60))
    }

    func testEmptyPoints() {
        XCTAssertEqual(FanCurve.target(points: [], temp: 60), 0)
    }
}

final class ConfigTests: XCTestCase {

    func testDecodeLegacyJSONWithoutCurves() throws {
        // 旧版配置(无 curves 字段)必须能解析,不能丢用户设置
        let json = """
        {"enabled": true, "mode": "manual", "tempStart": 63, "tempFull": 86,
         "minRPM": {"0": 1300}, "manualRPM": {"0": 4200}, "interval": 2}
        """
        let cfg = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertTrue(cfg.enabled)
        XCTAssertEqual(cfg.mode, "manual")
        XCTAssertEqual(cfg.tempStart, 63)
        XCTAssertEqual(cfg.curves, [:])
        XCTAssertEqual(cfg.manualRPM["0"], 4200)
    }

    func testCurvesRoundTrip() throws {
        var cfg = Config()
        cfg.curves = ["0": [CurvePoint(temp: 55, rpm: 1500), CurvePoint(temp: 90, rpm: 5000)]]
        let data = try JSONEncoder().encode(cfg)
        let back = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(back.curves["0"]?.first?.rpm, 1500)
    }

    func testPatchCurvesParsing() {
        let patch = ConfigPatch(from: ["curves": ["1": [[60.0, 1500.0], [95.0, 5700.0]]]])
        XCTAssertEqual(patch.curves?["1"]?.count, 2)
        XCTAssertEqual(patch.curves?["1"]?.last?.rpm, 5700)
    }
}

final class NightAndPowerTests: XCTestCase {

    /// 指定日期时刻的便捷构造
    private func at(_ h: Int, _ m: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 23; c.hour = h; c.minute = m
        return Calendar.current.date(from: c)!
    }

    func testNightWindowAcrossMidnight() {
        var nm = NightMode()
        nm.enabled = true
        nm.start = 23 * 60   // 23:00
        nm.end = 7 * 60      // 07:00
        XCTAssertTrue(nm.windowActive(now: at(23, 59)), "23:59 应在窗口内")
        XCTAssertTrue(nm.windowActive(now: at(0, 30)), "00:30 应在窗口内")
        XCTAssertTrue(nm.windowActive(now: at(6, 59)), "06:59 应在窗口内")
        XCTAssertFalse(nm.windowActive(now: at(7, 0)), "07:00 应离开窗口")
        XCTAssertFalse(nm.windowActive(now: at(12, 0)), "中午不在窗口")
        XCTAssertFalse(nm.windowActive(now: at(22, 59)), "22:59 还没进窗口")
    }

    func testNightWindowSameDay() {
        var nm = NightMode()
        nm.enabled = true
        nm.start = 13 * 60   // 13:00
        nm.end = 15 * 60     // 15:00
        XCTAssertTrue(nm.windowActive(now: at(13, 0)))
        XCTAssertTrue(nm.windowActive(now: at(14, 30)))
        XCTAssertFalse(nm.windowActive(now: at(12, 59)))
        XCTAssertFalse(nm.windowActive(now: at(15, 0)))
    }

    func testNightWindowDisabled() {
        var nm = NightMode()
        nm.enabled = false
        nm.start = 0
        nm.end = 24 * 60 - 1
        XCTAssertFalse(nm.windowActive(now: at(12, 0)), "未启用时任何时刻都不生效")
    }

    func testPresetRange() {
        XCTAssertEqual(Config.presetRange("quiet").start, 80)
        XCTAssertEqual(Config.presetRange("quiet").full, 100)
        XCTAssertEqual(Config.presetRange("turbo").full, 85)
        XCTAssertEqual(Config.presetRange("unknown").full, 95, "未知预设回落到均衡")
    }

    func testEffectiveCurvesBatterySwitch() {
        var cfg = Config()
        cfg.curves = ["0": [CurvePoint(temp: 55, rpm: 1500), CurvePoint(temp: 95, rpm: 5700)]]
        cfg.batteryCurves = ["0": [CurvePoint(temp: 75, rpm: 1500), CurvePoint(temp: 105, rpm: 5700)]]
        let noon = at(12, 0)
        // 插电:用常规曲线
        XCTAssertEqual(cfg.effectiveCurves(onAC: true, now: noon), cfg.curves)
        // 电池:切换到电池曲线
        XCTAssertEqual(cfg.effectiveCurves(onAC: false, now: noon), cfg.batteryCurves)
    }

    func testEffectiveCurvesBatteryEmptyFallsBack() {
        var cfg = Config()
        cfg.curves = ["0": [CurvePoint(temp: 55, rpm: 1500), CurvePoint(temp: 95, rpm: 5700)]]
        XCTAssertEqual(cfg.effectiveCurves(onAC: false), cfg.curves, "电池曲线未设置沿用常规曲线")
    }

    func testEffectiveCurvesNightOverridesAll() {
        var cfg = Config()
        cfg.curves = ["0": [CurvePoint(temp: 55, rpm: 1500), CurvePoint(temp: 95, rpm: 5700)]]
        cfg.batteryCurves = ["0": [CurvePoint(temp: 75, rpm: 1500), CurvePoint(temp: 105, rpm: 5700)]]
        var nm = NightMode()
        nm.enabled = true
        nm.start = 0
        nm.end = 23 * 60 + 59
        cfg.nightMode = nm
        // 夜间窗口内:忽略两套曲线(走预设两点),无论插不插电
        XCTAssertEqual(cfg.effectiveCurves(onAC: true, now: at(12, 0)), [:])
        XCTAssertEqual(cfg.effectiveCurves(onAC: false, now: at(12, 0)), [:])
        XCTAssertTrue(cfg.nightActive(now: at(12, 0)))
    }

    func testNightModeDecodeLegacyAndPatch() throws {
        // 旧配置无 nightMode 字段
        let legacy = try JSONDecoder().decode(Config.self,
                                              from: Data("{\"enabled\":true}".utf8))
        XCTAssertNil(legacy.nightMode)

        // 补丁解析
        let patch = ConfigPatch(from: ["nightMode": ["enabled": true, "start": 1380, "end": 420, "preset": "turbo"]])
        XCTAssertEqual(patch.nightMode?.start, 1380)
        XCTAssertEqual(patch.nightMode?.preset, "turbo")

        // 应用补丁 + 编解码往返
        var cfg = Config()
        cfg.apply(patch: patch)
        XCTAssertEqual(cfg.nightMode?.end, 420)
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(back.nightMode?.preset, "turbo")
    }

    func testBatteryCurvesPatchAndRoundTrip() throws {
        let patch = ConfigPatch(from: ["batteryCurves": ["0": [[75.0, 1500.0], [105.0, 5700.0]]]])
        var cfg = Config()
        cfg.apply(patch: patch)
        XCTAssertEqual(cfg.batteryCurves["0"]?.count, 2)
        let back = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(back.batteryCurves["0"]?.first?.temp, 75)
    }
}
