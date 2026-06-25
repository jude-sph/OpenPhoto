import SwiftUI
import OpenPhotoCore

/// "Compare terms" chart: up to 5 text terms, each drawing its cosine-similarity distribution over
/// the whole image corpus as a smooth filled density curve (Google-Trends-style overlay). No
/// threshold — just curves, a legend, and axes. See `AppState+Compare.swift` for the compute.
struct CompareTermsView: View {
    @Bindable var state: AppState
    @State private var draft = ""
    // Plot σ above each term's own average (removes CLIP's per-term baseline so the tails compare
    // fairly). Default on — raw cosine piles every term up around the same ~0.1 background.
    @AppStorage("compareStandardized") private var standardized = true

    // 5 pretty, distinct overlay colors. Index a term via `palette[term.colorIndex % count]`.
    static let palette: [Color] = [
        Color(red: 0.30, green: 0.66, blue: 1.00),   // blue
        Color(red: 1.00, green: 0.62, blue: 0.20),   // amber
        Color(red: 0.40, green: 0.82, blue: 0.45),   // green
        Color(red: 0.86, green: 0.44, blue: 0.84),   // magenta
        Color(red: 0.36, green: 0.82, blue: 0.80),   // teal
    ]
    static func color(for term: AppState.CompareTerm) -> Color {
        palette[term.colorIndex % palette.count]
    }

    private static let BINS = 64

    var body: some View {
        VStack(spacing: 0) {
            termInputRow
            Divider().overlay(Theme.hairline)
            if state.compareTerms.isEmpty {
                emptyHint
            } else {
                chartArea
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg2)
    }

    // MARK: — Term input row (chips + add field)

    private var termInputRow: some View {
        HStack(spacing: 8) {
            ForEach(state.compareTerms) { term in
                HStack(spacing: 6) {
                    Circle().fill(Self.color(for: term)).frame(width: 9, height: 9)
                    Text(term.text)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.text)
                    Button { state.removeCompareTerm(term.id) } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textFaint)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Theme.elevated, in: Capsule())
                .overlay(Capsule().stroke(Theme.hairline))
            }

            if state.compareTerms.count < 5 {
                TextField("Add a term…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(maxWidth: 180)
                    .onSubmit {
                        state.addCompareTerm(draft)
                        draft = ""
                    }
            }

            if state.compareComputing {
                ProgressView().controlSize(.small)
            }

            Spacer(minLength: 0)

            if !state.compareTerms.isEmpty {
                Toggle(isOn: $standardized) { Text("Standardize").font(.system(size: 11)) }
                    .toggleStyle(.switch).controlSize(.mini)
                    .help("Plot σ above each term's own average — removes CLIP's per-term baseline so the tails (real matches) compare fairly.")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.toolbarHeight)
    }

    // MARK: — Empty state

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 36))
                .foregroundStyle(Theme.textFaint)
            Text("Compare terms")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text("Add up to 5 terms to compare how strongly each concept appears across your photos.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    // MARK: — Chart + legend + caption

    private var chartArea: some View {
        let model = ChartModel(terms: state.compareTerms, bins: Self.BINS, standardized: standardized)
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                ChartCanvas(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                legend
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            Text(standardized
                 ? "σ above each term's average — a fatter right tail means more standout matches."
                 : "Raw cosine. Every term shares a ~0.1 baseline; the real signal is the right tail.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
                .padding(.vertical, 10)
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Strong matches").font(.caption2).foregroundStyle(Theme.textDim)
            ForEach(state.compareTerms) { term in
                HStack(spacing: 7) {
                    Circle().fill(Self.color(for: term)).frame(width: 9, height: 9)
                    Text(term.text)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text("\(term.strongCount)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Self.color(for: term))
                }
            }
        }
        .frame(width: 178, alignment: .leading)
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
        .help("Photos more than 3σ above each term's own average similarity — its standout matches.")
    }
}

// MARK: — Chart model (pure: binning + Gaussian smoothing + global normalization)

/// Precomputed curves for the overlay, derived from the terms' raw score vectors.
private struct ChartModel {
    /// One drawable curve: its color slot, 64 normalized heights in 0...1, and its filled area (for
    /// draw-ordering so small curves aren't hidden behind big ones).
    struct Curve {
        let colorIndex: Int
        let heights: [Float]   // count == bins, each 0...1
        let area: Float
    }
    let lo: Float
    let hi: Float
    let curves: [Curve]
    let standardized: Bool

    init(terms: [AppState.CompareTerm], bins: Int, standardized: Bool) {
        self.standardized = standardized
        // Per-term value vectors: raw cosine, or z-scores (s−μ)/σ when standardizing — the latter
        // aligns every term's baseline so only the tails (real matches) differ.
        let values: [[Float]] = terms.map { t in
            guard standardized else { return t.scores }
            let m = t.mean, sd = t.std
            guard sd > 1e-6 else { return Array(repeating: 0, count: t.scores.count) }
            return t.scores.map { ($0 - m) / sd }
        }

        // 1. Shared x-range across all terms, padded ~3%. Fall back to a sane window if degenerate.
        var minV = Float.greatestFiniteMagnitude, maxV = -Float.greatestFiniteMagnitude
        for vv in values {
            for s in vv {
                if s < minV { minV = s }
                if s > maxV { maxV = s }
            }
        }
        if !(minV.isFinite && maxV.isFinite) || maxV <= minV {
            if standardized { minV = -3; maxV = 6 } else { minV = 0; maxV = 0.4 }
        }
        let pad = (maxV - minV) * 0.03
        let lo = minV - pad, hi = maxV + pad
        self.lo = lo
        self.hi = hi

        // 2. Histogram each term into `bins`, then Gaussian-smooth (±3 bins, sigma ≈ 1.5).
        let kernel = Self.gaussianKernel(radius: 3, sigma: 1.5)
        var smoothed: [[Float]] = []
        var globalMax: Float = 0
        for vv in values {
            let hist = Self.histogram(vv, lo: lo, hi: hi, bins: bins)
            let sm = Self.convolve(hist, kernel: kernel)
            globalMax = max(globalMax, sm.max() ?? 0)
            smoothed.append(sm)
        }

        // 3. Normalize ALL curves by the single global max bin (relative heights stay honest).
        let scale = globalMax > 0 ? globalMax : 1
        var built: [Curve] = []
        for (i, sm) in smoothed.enumerated() {
            let heights = sm.map { $0 / scale }
            let area = heights.reduce(0, +)
            built.append(Curve(colorIndex: terms[i].colorIndex, heights: heights, area: area))
        }
        // Draw biggest-area first so small, tall curves land on top and stay visible.
        self.curves = built.sorted { $0.area > $1.area }
    }

    private static func histogram(_ values: [Float], lo: Float, hi: Float, bins: Int) -> [Float] {
        var h = [Float](repeating: 0, count: bins)
        let span = hi - lo
        guard span > 0 else { return h }
        let scale = Float(bins) / span
        for v in values {
            var idx = Int((v - lo) * scale)
            if idx < 0 { idx = 0 }
            if idx >= bins { idx = bins - 1 }
            h[idx] += 1
        }
        return h
    }

    private static func gaussianKernel(radius: Int, sigma: Float) -> [Float] {
        var k = [Float](); k.reserveCapacity(2 * radius + 1)
        var sum: Float = 0
        for i in -radius...radius {
            let x = Float(i)
            let w = expf(-(x * x) / (2 * sigma * sigma))
            k.append(w); sum += w
        }
        return sum > 0 ? k.map { $0 / sum } : k
    }

    private static func convolve(_ input: [Float], kernel: [Float]) -> [Float] {
        let n = input.count, r = kernel.count / 2
        guard n > 0 else { return input }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var acc: Float = 0
            for (j, w) in kernel.enumerated() {
                let idx = min(n - 1, max(0, i + j - r))   // clamp at edges
                acc += input[idx] * w
            }
            out[i] = acc
        }
        return out
    }
}

// MARK: — Canvas: gridlines, axis ticks, smooth filled curves

private struct ChartCanvas: View {
    let model: ChartModel

    var body: some View {
        Canvas { ctx, size in
            let leftPad: CGFloat = 8
            let rightPad: CGFloat = 8
            let topPad: CGFloat = 8
            let axisH: CGFloat = 22          // space for x-axis labels
            let plot = CGRect(x: leftPad, y: topPad,
                              width: max(1, size.width - leftPad - rightPad),
                              height: max(1, size.height - topPad - axisH))

            drawGrid(ctx, plot: plot)
            drawCurves(ctx, plot: plot)
            drawAxis(ctx, plot: plot, size: size)
        }
        .drawingGroup()
    }

    // Faint horizontal gridlines.
    private func drawGrid(_ ctx: GraphicsContext, plot: CGRect) {
        let rows = 4
        for i in 0...rows {
            let y = plot.minY + plot.height * CGFloat(i) / CGFloat(rows)
            var p = Path()
            p.move(to: CGPoint(x: plot.minX, y: y))
            p.addLine(to: CGPoint(x: plot.maxX, y: y))
            ctx.stroke(p, with: .color(Theme.hairline), lineWidth: i == rows ? 1 : 0.5)
        }
    }

    // X-axis with ~5 cosine-similarity tick labels (2 decimals).
    private func drawAxis(_ ctx: GraphicsContext, plot: CGRect, size: CGSize) {
        let ticks = 5
        for i in 0..<ticks {
            let frac = CGFloat(i) / CGFloat(ticks - 1)
            let x = plot.minX + plot.width * frac
            let value = model.lo + (model.hi - model.lo) * Float(frac)
            // small tick mark
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: plot.maxY))
            tick.addLine(to: CGPoint(x: x, y: plot.maxY + 4))
            ctx.stroke(tick, with: .color(Theme.hairline), lineWidth: 1)
            let label = model.standardized
                ? (abs(value) < 0.5 ? "0" : String(format: "%.0fσ", value))
                : String(format: "%.2f", value)
            let text = ctx.resolve(
                Text(label)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(Theme.textDim))
            let tsize = text.measure(in: size)
            var tx = x
            if i == 0 { tx = x + tsize.width / 2 }
            else if i == ticks - 1 { tx = x - tsize.width / 2 }
            ctx.draw(text, at: CGPoint(x: tx, y: plot.maxY + 4 + tsize.height / 2 + 2))
        }
    }

    // Smooth filled overlaid density curves (Catmull-Rom → Bezier).
    private func drawCurves(_ ctx: GraphicsContext, plot: CGRect) {
        for curve in model.curves {
            let color = CompareTermsView.palette[curve.colorIndex % CompareTermsView.palette.count]
            let pts = points(for: curve.heights, in: plot)
            guard pts.count >= 2 else { continue }

            // Filled area: smooth top from left baseline → curve → right baseline, closed.
            var fill = Path()
            fill.move(to: CGPoint(x: pts.first!.x, y: plot.maxY))
            fill.addLine(to: pts.first!)
            appendSmooth(&fill, points: pts)
            fill.addLine(to: CGPoint(x: pts.last!.x, y: plot.maxY))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(color.opacity(0.18)))

            // Stroked top outline.
            var line = Path()
            line.move(to: pts.first!)
            appendSmooth(&line, points: pts)
            ctx.stroke(line, with: .color(color.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    private func points(for heights: [Float], in plot: CGRect) -> [CGPoint] {
        let n = heights.count
        guard n > 1 else { return [] }
        return heights.enumerated().map { i, h in
            let x = plot.minX + plot.width * CGFloat(i) / CGFloat(n - 1)
            let y = plot.maxY - plot.height * CGFloat(max(0, min(1, h)))
            return CGPoint(x: x, y: y)
        }
    }

    /// Append a Catmull-Rom spline through `points` (converted to cubic Bezier segments) to `path`,
    /// assuming `path` is already positioned at `points[0]`.
    private func appendSmooth(_ path: inout Path, points: [CGPoint]) {
        guard points.count > 2 else {
            for p in points.dropFirst() { path.addLine(to: p) }
            return
        }
        for i in 0..<(points.count - 1) {
            let p0 = points[max(0, i - 1)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(points.count - 1, i + 2)]
            // Catmull-Rom → Bezier control points (tension = 1/6).
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
    }
}
