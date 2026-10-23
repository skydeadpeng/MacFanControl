import SwiftUI
import SMCKit

/// 曲线画布:网格 + 折线 + 可拖动控制点(替代 Charts 预览,支持直接拖拽编辑)
struct CurveCanvas: View {
    let points: [CurvePoint]
    let tempRange: ClosedRange<Double>
    let rpmRange: ClosedRange<Double>
    var currentTemp: Double
    var onMove: (Int, CurvePoint) -> Void

    @State private var draggingIndex: Int?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, _ in
                drawGrid(ctx: ctx, size: size)
                drawCurrentTemp(ctx: ctx, size: size)
                drawCurve(ctx: ctx, size: size)
                drawPoints(ctx: ctx, size: size)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let loc = value.location
                        if draggingIndex == nil {
                            draggingIndex = hitTest(loc, size: size)
                        }
                        if let idx = draggingIndex, idx < points.count {
                            let t = clamp(tempAt(x: loc.x, size: size),
                                          tempRange.lowerBound, tempRange.upperBound)
                            let r = clamp(rpmAt(y: loc.y, size: size),
                                          rpmRange.lowerBound, rpmRange.upperBound)
                            let snapped = CurvePoint(temp: (t).rounded(),
                                                     rpm: (r / 50).rounded() * 50)
                            onMove(idx, snapped)
                        }
                    }
                    .onEnded { _ in draggingIndex = nil }
            )
        }
    }

    // MARK: 绘制

    private func drawGrid(ctx: GraphicsContext, size: CGSize) {
        var grid = Path()
        for t in stride(from: tempRange.lowerBound, through: tempRange.upperBound, by: 10) {
            let x = xAt(temp: t, size: size)
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        for r in stride(from: rpmRange.lowerBound, through: rpmRange.upperBound, by: 1000) {
            let y = yAt(rpm: r, size: size)
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        ctx.stroke(grid, with: .color(.primary.opacity(0.08)), lineWidth: 0.5)
    }

    private func drawCurrentTemp(ctx: GraphicsContext, size: CGSize) {
        guard currentTemp > 0 else { return }
        var line = Path()
        let x = xAt(temp: currentTemp, size: size)
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        ctx.stroke(line, with: .color(.orange.opacity(0.7)),
                   style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    private func drawCurve(ctx: GraphicsContext, size: CGSize) {
        guard points.count >= 2 else { return }
        var path = Path()
        path.move(to: CGPoint(x: xAt(temp: points[0].temp, size: size),
                              y: yAt(rpm: points[0].rpm, size: size)))
        for p in points.dropFirst() {
            path.addLine(to: CGPoint(x: xAt(temp: p.temp, size: size),
                                     y: yAt(rpm: p.rpm, size: size)))
        }
        ctx.stroke(path, with: .color(.blue), lineWidth: 2)
    }

    private func drawPoints(ctx: GraphicsContext, size: CGSize) {
        for (i, p) in points.enumerated() {
            let center = CGPoint(x: xAt(temp: p.temp, size: size),
                                 y: yAt(rpm: p.rpm, size: size))
            let rect = CGRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11)
            ctx.fill(Path(ellipseIn: rect),
                     with: .color(i == draggingIndex ? .orange : .white))
            ctx.stroke(Path(ellipseIn: rect), with: .color(.blue), lineWidth: 2)
        }
    }

    // MARK: 坐标换算(留出右侧 6pt、上下 4pt 内边距)

    private func xAt(temp: Double, size: CGSize) -> CGFloat {
        let f = (temp - tempRange.lowerBound) / max(1, tempRange.upperBound - tempRange.lowerBound)
        return CGFloat(f) * (size.width - 12) + 6
    }

    private func yAt(rpm: Double, size: CGSize) -> CGFloat {
        let f = (rpm - rpmRange.lowerBound) / max(1, rpmRange.upperBound - rpmRange.lowerBound)
        return size.height - 8 - CGFloat(f) * (size.height - 16)
    }

    private func tempAt(x: CGFloat, size: CGSize) -> Double {
        let f = Double((x - 6) / max(1, size.width - 12))
        return tempRange.lowerBound + f * (tempRange.upperBound - tempRange.lowerBound)
    }

    private func rpmAt(y: CGFloat, size: CGSize) -> Double {
        let f = Double((size.height - 8 - y) / max(1, size.height - 16))
        return rpmRange.lowerBound + f * (rpmRange.upperBound - rpmRange.lowerBound)
    }

    private func hitTest(_ loc: CGPoint, size: CGSize) -> Int? {
        var best: (idx: Int, dist: CGFloat)?
        for (i, p) in points.enumerated() {
            let c = CGPoint(x: xAt(temp: p.temp, size: size), y: yAt(rpm: p.rpm, size: size))
            let d = hypot(c.x - loc.x, c.y - loc.y)
            if d < 20 && (best == nil || d < best!.dist) {
                best = (i, d)
            }
        }
        return best?.idx
    }

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
}
