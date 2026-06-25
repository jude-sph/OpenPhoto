import SwiftUI
import OpenPhotoCore

/// "Compare terms" chart: up to 5 text terms, each scored (cosine) against the whole image corpus.
/// We draw a **complementary-CDF** ("matches above threshold") chart — for each term, how many photos
/// score ≥ a given cosine similarity — on a **log Y axis**, with a draggable vertical threshold line
/// and live per-term counts. Density curves were the wrong tool: real matches are ~0.2% of the corpus,
/// so as area they vanished and every term looked identical. As a count-above-threshold the terms
/// finally separate. See `AppState+Compare.swift` for the compute.
struct CompareTermsView: View {
    @Bindable var state: AppState
    @State private var draft = ""
    /// Current threshold cosine (nil = use the model's default ~75% across the x-range). Set by drag.
    @State private var threshold: Float?

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

    // Plot geometry shared between the Canvas and the drag gesture so x↔value maps consistently.
    fileprivate static let leftPad: CGFloat = 8
    fileprivate static let rightPad: CGFloat = 38   // room for the right-edge log labels (1, 10, …, 10k)
    fileprivate static let topPad: CGFloat = 16     // room for the threshold value label at the top
    fileprivate static let axisH: CGFloat = 22      // space for the x-axis labels

    fileprivate static func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: leftPad, y: topPad,
               width: max(1, size.width - leftPad - rightPad),
               height: max(1, size.height - topPad - axisH))
    }

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

    /// The effective threshold cosine: the dragged value, or the model's default when untouched.
    private func effectiveThreshold(_ model: CCDFModel) -> Float {
        min(model.hi, max(model.lo, threshold ?? model.defaultThreshold))
    }

    private var chartArea: some View {
        let model = CCDFModel(terms: state.compareTerms)
        let thr = effectiveThreshold(model)
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                GeometryReader { geo in
                    CCDFCanvas(model: model, threshold: thr)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { v in
                                    let plot = Self.plotRect(in: geo.size)
                                    let clampedX = min(plot.maxX, max(plot.minX, v.location.x))
                                    let frac = plot.width > 0 ? Float((clampedX - plot.minX) / plot.width) : 0
                                    threshold = model.lo + (model.hi - model.lo) * frac
                                }
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                legend(threshold: thr)
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            Text("Photos at least this similar (log scale). Drag to set the threshold.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
                .padding(.vertical, 10)
        }
    }

    /// Legend = LIVE counts at the threshold (the payoff). Updates as the user drags.
    private func legend(threshold thr: Float) -> some View {
        let corpus = state.compareTerms.map(\.scores.count).max() ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            Text("Photos ≥ \(String(format: "%.2f", thr))")
                .font(.caption2).foregroundStyle(Theme.textDim)
            ForEach(state.compareTerms) { term in
                let count = term.scores.lazy.filter { $0 >= thr }.count
                let pct = corpus > 0 ? Double(count) / Double(corpus) * 100 : 0
                HStack(spacing: 7) {
                    Circle().fill(Self.color(for: term)).frame(width: 9, height: 9)
                    Text(term.text)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        Text("\(count)")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Self.color(for: term))
                        Text(String(format: "(%.1f%%)", pct))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Theme.textFaint)
                    }
                }
            }
        }
        .frame(width: 200, alignment: .leading)
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
        .help("How many photos score at or above the threshold cosine similarity for each term. Drag the line to change the threshold.")
    }
}

// MARK: — Chart model (pure: per-term complementary-CDF over a shared, tail-focused x-range)

/// Precomputed CCDF curves: for each term, how many photos score ≥ x, sampled at `SAMPLES` evenly
/// spaced thresholds across a tail-focused [lo, hi] cosine range.
private struct CCDFModel {
    static let SAMPLES = 96

    /// One drawable curve: its color slot, `SAMPLES` counts (photos ≥ that x), and total area (for
    /// draw-ordering so steep-dropping curves land on top of broad ones).
    struct Curve {
        let colorIndex: Int
        let counts: [Int]   // count == SAMPLES
        let total: Int      // Σ counts — proxy for area, for draw ordering
    }
    let lo: Float
    let hi: Float
    let maxCount: Int       // largest single-term scores.count (≈ N)
    let curves: [Curve]

    /// Default threshold: ~75% of the way across [lo, hi] (well into the interesting tail).
    var defaultThreshold: Float { lo + (hi - lo) * 0.75 }

    init(terms: [AppState.CompareTerm]) {
        // 1. Tail-focused x-range. Pool a sample of all terms' scores; lo = 50th pctile of the pool
        //    (the left half is a flat plateau near N and uninteresting), hi = max across all terms +3%.
        var pooled: [Float] = []
        var maxV = -Float.greatestFiniteMagnitude
        var maxCnt = 0
        for t in terms {
            maxCnt = max(maxCnt, t.scores.count)
            for s in t.scores where s > maxV { maxV = s }
            // Sample up to ~2000 scores per term into the pool (median estimate doesn't need all 12k).
            if t.scores.isEmpty { continue }
            let stride = max(1, t.scores.count / 2000)
            var i = 0
            while i < t.scores.count { pooled.append(t.scores[i]); i += stride }
        }
        self.maxCount = max(1, maxCnt)

        var lo: Float = 0.05, hi: Float = 0.35
        if !pooled.isEmpty && maxV.isFinite {
            pooled.sort()
            let median = pooled[pooled.count / 2]
            let pad = (maxV - median) * 0.03
            lo = median
            hi = maxV + pad
        }
        if !(lo.isFinite && hi.isFinite) || hi <= lo { lo = 0.05; hi = 0.35 }
        self.lo = lo
        self.hi = hi

        // 2. Per term, count(scores >= x) at SAMPLES thresholds. Sort once, then binary-search each
        //    threshold — O(SAMPLES·log N) per term instead of O(SAMPLES·N).
        let xs: [Float] = (0..<Self.SAMPLES).map { i in
            lo + (hi - lo) * Float(i) / Float(Self.SAMPLES - 1)
        }
        var built: [Curve] = []
        for t in terms {
            let sorted = t.scores.sorted()
            var counts = [Int](repeating: 0, count: Self.SAMPLES)
            var total = 0
            for (j, x) in xs.enumerated() {
                // First index with sorted[idx] >= x → all from there to the end are ≥ x.
                let idx = Self.lowerBound(sorted, x)
                let c = sorted.count - idx
                counts[j] = c
                total += c
            }
            built.append(Curve(colorIndex: t.colorIndex, counts: counts, total: total))
        }
        // Draw biggest-area (broadest) first so steep-dropping curves land on top and stay visible.
        self.curves = built.sorted { $0.total > $1.total }
    }

    /// First index `i` in sorted `a` with `a[i] >= value` (== a.count if none). Standard lower_bound.
    private static func lowerBound(_ a: [Float], _ value: Float) -> Int {
        var lo = 0, hi = a.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if a[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

// MARK: — Canvas: log-Y gridlines, smooth CCDF curves, x-axis ticks, draggable threshold line

private struct CCDFCanvas: View {
    let model: CCDFModel
    let threshold: Float

    var body: some View {
        Canvas { ctx, size in
            let plot = CompareTermsView.plotRect(in: size)
            drawGrid(ctx, plot: plot, size: size)
            drawCurves(ctx, plot: plot)
            drawAxis(ctx, plot: plot, size: size)
            drawThreshold(ctx, plot: plot, size: size)
        }
        .drawingGroup()
    }

    // Map a count → y using a log scale from 1…maxCount.
    private func yFor(count c: Int, plot: CGRect) -> CGFloat {
        let denom = log10(Double(model.maxCount) + 1)
        let frac = c <= 0 || denom <= 0 ? 0 : log10(Double(c) + 1) / denom
        return plot.maxY - plot.height * CGFloat(frac)
    }

    // Faint horizontal gridlines + right-edge labels at the log decades within range.
    private func drawGrid(_ ctx: GraphicsContext, plot: CGRect, size: CGSize) {
        // Bottom & top frame lines.
        var frame = Path()
        frame.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        frame.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        ctx.stroke(frame, with: .color(Theme.hairline), lineWidth: 1)

        // Decades that fall in [1, maxCount], plus maxCount itself.
        var decades: [Int] = []
        var d = 1
        while d <= model.maxCount { decades.append(d); d *= 10 }
        if decades.last != model.maxCount { decades.append(model.maxCount) }

        for c in decades {
            let y = yFor(count: c, plot: plot)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            ctx.stroke(line, with: .color(Theme.hairline.opacity(0.7)), lineWidth: 0.5)

            let label = Self.shortCount(c)
            let text = ctx.resolve(
                Text(label)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundColor(Theme.textFaint))
            let tsize = text.measure(in: size)
            ctx.draw(text, at: CGPoint(x: plot.maxX + 4 + tsize.width / 2,
                                       y: min(plot.maxY, max(plot.minY, y))))
        }
    }

    // X-axis with ~5 cosine-similarity tick labels (2 decimals).
    private func drawAxis(_ ctx: GraphicsContext, plot: CGRect, size: CGSize) {
        let ticks = 5
        for i in 0..<ticks {
            let frac = CGFloat(i) / CGFloat(ticks - 1)
            let x = plot.minX + plot.width * frac
            let value = model.lo + (model.hi - model.lo) * Float(frac)
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: plot.maxY))
            tick.addLine(to: CGPoint(x: x, y: plot.maxY + 4))
            ctx.stroke(tick, with: .color(Theme.hairline), lineWidth: 1)
            let text = ctx.resolve(
                Text(String(format: "%.2f", value))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundColor(Theme.textDim))
            let tsize = text.measure(in: size)
            var tx = x
            if i == 0 { tx = x + tsize.width / 2 }
            else if i == ticks - 1 { tx = x - tsize.width / 2 }
            ctx.draw(text, at: CGPoint(x: tx, y: plot.maxY + 4 + tsize.height / 2 + 2))
        }
    }

    // Smooth CCDF lines (Catmull-Rom → Bezier), a light fill under each so overlaps read.
    private func drawCurves(_ ctx: GraphicsContext, plot: CGRect) {
        for curve in model.curves {
            let color = CompareTermsView.palette[curve.colorIndex % CompareTermsView.palette.count]
            let pts = points(for: curve.counts, in: plot)
            guard pts.count >= 2 else { continue }

            // Very light fill under the line so overlaps read.
            var fill = Path()
            fill.move(to: CGPoint(x: pts.first!.x, y: plot.maxY))
            fill.addLine(to: pts.first!)
            appendSmooth(&fill, points: pts)
            fill.addLine(to: CGPoint(x: pts.last!.x, y: plot.maxY))
            fill.closeSubpath()
            ctx.fill(fill, with: .color(color.opacity(0.08)))

            // Stroked top line.
            var line = Path()
            line.move(to: pts.first!)
            appendSmooth(&line, points: pts)
            ctx.stroke(line, with: .color(color.opacity(0.95)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    // Vertical draggable threshold line: dashed accent line + value label + top grabber handle.
    private func drawThreshold(_ ctx: GraphicsContext, plot: CGRect, size: CGSize) {
        let span = model.hi - model.lo
        guard span > 0 else { return }
        let frac = CGFloat((threshold - model.lo) / span)
        let x = plot.minX + plot.width * min(1, max(0, frac))

        var line = Path()
        line.move(to: CGPoint(x: x, y: plot.minY))
        line.addLine(to: CGPoint(x: x, y: plot.maxY))
        ctx.stroke(line, with: .color(Theme.accent.opacity(0.9)),
                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))

        // Value label at the top, in a small pill.
        let label = "≥ \(String(format: "%.2f", threshold))"
        let text = ctx.resolve(
            Text(label).font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundColor(.white))
        let tsize = text.measure(in: size)
        var lx = x
        if lx - tsize.width / 2 - 5 < plot.minX { lx = plot.minX + tsize.width / 2 + 5 }
        if lx + tsize.width / 2 + 5 > plot.maxX { lx = plot.maxX - tsize.width / 2 - 5 }
        let pill = CGRect(x: lx - tsize.width / 2 - 5, y: plot.minY - 14,
                          width: tsize.width + 10, height: 15)
        ctx.fill(Path(roundedRect: pill, cornerRadius: 5), with: .color(Theme.accent))
        ctx.draw(text, at: CGPoint(x: lx, y: plot.minY - 14 + 7.5))

        // Grabber handle on the line to signal it's draggable.
        let handle = CGRect(x: x - 3.5, y: plot.minY + 2, width: 7, height: 16)
        ctx.fill(Path(roundedRect: handle, cornerRadius: 3.5), with: .color(Theme.accent))
        ctx.stroke(Path(roundedRect: handle, cornerRadius: 3.5),
                   with: .color(.white.opacity(0.7)), lineWidth: 0.75)
    }

    private func points(for counts: [Int], in plot: CGRect) -> [CGPoint] {
        let n = counts.count
        guard n > 1 else { return [] }
        return counts.enumerated().map { i, c in
            let x = plot.minX + plot.width * CGFloat(i) / CGFloat(n - 1)
            return CGPoint(x: x, y: yFor(count: c, plot: plot))
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

    /// Compact count labels for the log axis: 1, 10, 100, 1k, 10k.
    private static func shortCount(_ c: Int) -> String {
        if c >= 1000 {
            let k = Double(c) / 1000
            return k == k.rounded() ? "\(Int(k))k" : String(format: "%.1fk", k)
        }
        return "\(c)"
    }
}
