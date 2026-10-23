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
