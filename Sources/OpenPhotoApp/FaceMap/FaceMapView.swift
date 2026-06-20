import SwiftUI
import OpenPhotoCore
import Accelerate

struct FaceMapView: View {
    @Bindable var state: AppState
    @State private var camera = FaceMapCamera()
    @State private var dragStart: FaceMapCamera?
    @State private var hovered: FaceMapPoint?
    @State private var hoverScreen: CGPoint = .zero
    @State private var selectedPerson: Int64?
    @State private var selectedFace: FaceMapPoint?  // clicked dot → pinned inspector (reassign lives here)
    @State private var inspectorShowFaces = true     // Face/Photo toggle in the inspector (mirrors People)
    @State private var lastScale: Float = 1        // magnify-gesture anchor
    @State private var lensOn = false               // similarity lens: recolor galaxy by similarity to hovered face
    @State private var lensSims: [Float]?           // per-point cosine similarity to the hovered face (nil = off)

    var body: some View {
        GeometryReader { geo in
            let fit = FaceMapCamera.fit(for: geo.size)
            ZStack(alignment: .topLeading) {
                Theme.windowBG
                if state.faceMapLoading && state.faceMap.points.isEmpty {
                    ProgressView("Building face map…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    canvas(geo: geo, fit: fit)
                        .gesture(panGesture(viewSize: geo.size, fit: fit))
                        .gesture(magnifyGesture())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let pt):
                                hoverScreen = pt
                                let idx = nearestIndex(to: pt, viewSize: geo.size, fit: fit)
                                hovered = idx.map { state.faceMap.points[$0] }
                                lensSims = lensOn ? idx.flatMap(computeLensSims) : nil
                            case .ended:
                                hovered = nil; lensSims = nil
                            }
                        }
                        .onTapGesture(coordinateSpace: .local) { pt in
                            let p = nearestPoint(to: pt, viewSize: geo.size, fit: fit)
                            selectedPerson = p?.personID
                            selectedFace = p          // nil when clicking empty space → closes inspector
                        }
                    overlayCanvas(viewSize: geo.size, fit: fit)
                    legend
                }
                if let h = hovered { popover(for: h) }          // hover = info only, mouse-following
                if let f = selectedFace { faceInspector(for: f) } // click = pinned, interactive
            }
            .focusable().focusEffectDisabled()
            .onKeyPress(.init("=")) { zoom(by: 1.25); return .handled }
            .onKeyPress(.init("+")) { zoom(by: 1.25); return .handled }
            .onKeyPress(.init("-")) { zoom(by: 1 / 1.25); return .handled }
            .onKeyPress(.init("_")) { zoom(by: 1 / 1.25); return .handled }
            .onKeyPress(.init("l")) { lensOn.toggle(); if !lensOn { lensSims = nil }; return .handled }
        }
        .task { if state.faceMap.points.isEmpty { state.loadFaceMap() } }
        .navigationTitle("Face Map")
    }

    // MARK: drawing
    private func canvas(geo: GeometryProxy, fit: Float) -> some View {
        Canvas { ctx, size in
            let pts = state.faceMap.points
            // Near-constant screen-size dots: radius barely grows with zoom, so zooming in SEPARATES
            // clumped dots instead of inflating them. Capped so dense clusters stay legible.
            let z = CGFloat(camera.scale)
            let rNamed: CGFloat = min(4.0, 2.1 + z * 0.045)
            let rFaint: CGFloat = min(2.6, 1.3 + z * 0.03)
            func onScreen(_ s: CGPoint) -> Bool {
                s.x >= -10 && s.y >= -10 && s.x <= size.width + 10 && s.y <= size.height + 10
            }
            @inline(__always) func dot(_ s: CGPoint, _ r: CGFloat, _ c: Color) {
                ctx.fill(Path(ellipseIn: CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2)), with: .color(c))
            }
            if lensOn, let sims = lensSims, sims.count == pts.count {
                // Similarity lens: each dot's brightness/size tracks cosine similarity to the hovered
                // face — similar faces blaze (in their person colour, white-hot at the very top), the
                // rest recede to near-black. Two passes so the bright ones land on top.
                let lo: Float = 0.10, hi: Float = 0.55
                func tval(_ i: Int) -> Double { Double(max(0, min(1, (sims[i] - lo) / (hi - lo)))) }
                for i in pts.indices where tval(i) < 0.4 {        // dim background
                    let s = camera.worldToScreen(pts[i].pos, viewSize: size, fit: fit)
                    if !onScreen(s) { continue }
                    let base = pts[i].personID.map { Theme.colorForPerson($0) } ?? Theme.personColorUnassigned
                    dot(s, rFaint, base.opacity(0.05 + 0.35 * tval(i)))
                }
                for i in pts.indices where tval(i) >= 0.4 {       // similar faces, bright + larger
                    let s = camera.worldToScreen(pts[i].pos, viewSize: size, fit: fit)
                    if !onScreen(s) { continue }
                    let t = tval(i)
                    let base = pts[i].personID.map { Theme.colorForPerson($0) } ?? Theme.personColorUnassigned
                    dot(s, rFaint + (rNamed - rFaint + 2) * CGFloat(t), base.opacity(0.25 + 0.75 * t))
                    if t > 0.85 { dot(s, rNamed * 0.6, .white.opacity((t - 0.85) / 0.15)) }
                }
            } else {
                // Pass 1 — unassigned faces: a faint background haze (still hover-detected; hit-testing
                // is independent of draw order). Drawn first so named people sit on top.
                let faint = Theme.personColorUnassigned.opacity(0.3)
                for p in pts where p.personID == nil {
                    let s = camera.worldToScreen(p.pos, viewSize: size, fit: fit)
                    if onScreen(s) { dot(s, rFaint, faint) }
                }
                // Pass 2 — named faces: full colour, on top.
                for p in pts {
                    guard let pid = p.personID else { continue }
                    let s = camera.worldToScreen(p.pos, viewSize: size, fit: fit)
                    if onScreen(s) { dot(s, rNamed, Theme.colorForPerson(pid)) }
                }
            }
        }
        .drawingGroup() // GPU-composite the dot layer
    }

    /// Lookalike lines + typicality markers for the selected person, drawn above the dots.
    /// No-ops when nothing is selected.
    private func overlayCanvas(viewSize: CGSize, fit: Float) -> some View {
        Canvas { ctx, size in
            guard let pid = selectedPerson,
                  let fromW = state.faceMap.personAnchorByID[pid] ?? state.faceMap.personCentersByID[pid] else { return }
            let a = camera.worldToScreen(fromW, viewSize: size, fit: fit)
            // Ring the selected person's own island anchor.
            ctx.stroke(Path(ellipseIn: CGRect(x: a.x - 8, y: a.y - 8, width: 16, height: 16)),
                       with: .color(.white.opacity(0.85)), lineWidth: 2)
            // Lookalike lines: coloured by the TARGET, ending ON their island with a ringed endpoint and
            // a "Name · 0.42" label, so it's obvious who each line reaches (mutual = solid, else dashed).
            for la in state.faceMap.lookalikes[pid] ?? [] {
                guard let toW = state.faceMap.personAnchorByID[la.personID] ?? state.faceMap.personCentersByID[la.personID] else { continue }
                let b = camera.worldToScreen(toW, viewSize: size, fit: fit)
                let col = Theme.colorForPerson(la.personID)
                var path = Path(); path.move(to: a); path.addLine(to: b)
                ctx.stroke(path, with: .color(col.opacity(la.mutual ? 0.95 : 0.6)),
                           style: StrokeStyle(lineWidth: la.mutual ? 2.5 : 1.5, dash: la.mutual ? [] : [5, 4]))
                ctx.fill(Path(ellipseIn: CGRect(x: b.x - 4, y: b.y - 4, width: 8, height: 8)), with: .color(col))
                ctx.stroke(Path(ellipseIn: CGRect(x: b.x - 7.5, y: b.y - 7.5, width: 15, height: 15)),
                           with: .color(col), lineWidth: 2)
                let name = state.personName(la.personID) ?? "?"
                let label = (la.mutual ? "↔ " : "") + name + String(format: "  %.2f", la.sim)
                let resolved = ctx.resolve(Text(label).font(.caption2.bold()).foregroundColor(Theme.text))
                let tsize = resolved.measure(in: size)
                let ly = b.y - 15
                let pill = CGRect(x: b.x - tsize.width / 2 - 5, y: ly - tsize.height / 2 - 2,
                                  width: tsize.width + 10, height: tsize.height + 4)
                ctx.fill(Path(roundedRect: pill, cornerRadius: 5), with: .color(Theme.windowBG.opacity(0.85)))
                ctx.draw(resolved, at: CGPoint(x: b.x, y: ly))
            }
            // Typicality: ring the medoid (green), mark outliers (amber).
            if let typ = state.faceMap.typicalityByID[pid] {
                if let m = typ.medoid, let mp = state.faceMap.points.first(where: { $0.id == m }) {
                    let s = camera.worldToScreen(mp.pos, viewSize: size, fit: fit)
                    ctx.stroke(Path(ellipseIn: CGRect(x: s.x - 9, y: s.y - 9, width: 18, height: 18)),
                               with: .color(Theme.green), lineWidth: 2.5)
                }
                for oid in typ.outliers {
                    guard let op = state.faceMap.points.first(where: { $0.id == oid }) else { continue }
                    let s = camera.worldToScreen(op.pos, viewSize: size, fit: fit)
                    ctx.stroke(Path(ellipseIn: CGRect(x: s.x - 7, y: s.y - 7, width: 14, height: 14)),
                               with: .color(Theme.amber), lineWidth: 2)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var legend: some View {
        let top = state.people.sorted { $0.faceCount > $1.faceCount }.prefix(10)
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(state.faceMap.points.count) faces").font(.caption2).foregroundStyle(Theme.textDim)
            ForEach(Array(top), id: \.id) { p in
                HStack(spacing: 5) {
                    Circle().fill(Theme.colorForPerson(p.id)).frame(width: 8, height: 8)
                    Text(p.name).font(.caption2).foregroundStyle(Theme.text)
                }
            }
            Divider().padding(.vertical, 1)
            Toggle(isOn: $lensOn) {
                Label("Similarity lens", systemImage: "scope").font(.caption2)
            }
            .toggleStyle(.switch).controlSize(.mini).tint(Theme.accent)
            .onChange(of: lensOn) { _, on in if !on { lensSims = nil } }
            if lensOn {
                Text("hover a face — the galaxy glows by resemblance")
                    .font(.system(size: 9)).foregroundStyle(Theme.textDim).frame(width: 150, alignment: .leading)
            }
        }.padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(10)
    }

    /// True when `p` belongs to the currently selected person AND is one of that person's outliers,
    /// i.e. the popover should expose the "Not [name]?" reassign menu (and be interactive).
    private func isReassignableOutlier(_ p: FaceMapPoint) -> Bool {
        guard let pid = p.personID, pid == selectedPerson else { return false }
        return state.faceMap.typicalityByID[pid]?.outliers.contains(p.id) == true
    }

    /// Hover preview: thumbnail + name, follows the pointer, never interactive (events pass through).
    private func popover(for p: FaceMapPoint) -> some View {
        VStack(spacing: 4) {
            FaceCropView(state: state, faceID: p.id, hash: nil, size: 72, fill: false)
                .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
            Text(p.personID.flatMap { state.personName($0) } ?? "Unassigned")
                .font(.caption).foregroundStyle(Theme.text)
        }
        .padding(6).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .fixedSize().position(x: hoverScreen.x, y: max(48, hoverScreen.y - 60))
        .allowsHitTesting(false)
    }

    /// Pinned inspector for the clicked dot: stays put (top-trailing) so its reassign menu is reachable
    /// — the hover popover followed the pointer, which made the menu impossible to click.
    private func faceInspector(for p: FaceMapPoint) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(p.personID.flatMap { state.personName($0) } ?? "Unassigned")
                    .font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                Button { selectedFace = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textDim)
            }
            // Face vs whole-photo — mirrors the People screen's Faces/Photos toggle.
            FaceCropView(state: state, faceID: p.id, hash: nil, size: 150, fill: false,
                         cropToFace: inspectorShowFaces)
                .frame(width: 150, height: 150).clipShape(RoundedRectangle(cornerRadius: 8))
            Picker("", selection: $inspectorShowFaces) {
                Text("Face").tag(true)
                Text("Photo").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden()
            if isReassignableOutlier(p) {
                Text("looks unlike this person").font(.caption2).foregroundStyle(Theme.amber)
            }
            if p.personID != nil { reassignControl(for: p) }
        }
        .padding(10).frame(width: 170)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .transition(.opacity)
    }

    /// "Not [name]?" menu: remove from this person, or move to any other person. Each action
    /// reassigns via the existing `reassignFace`, which reloads the map after the write commits so the
    /// dot recolors (no explicit reload here — that would race the write).
    @ViewBuilder private func reassignControl(for p: FaceMapPoint) -> some View {
        if let pid = p.personID {
            Menu("Not \(state.personName(pid) ?? "this person")?") {
                Button("Remove from this person") {
                    state.reassignFace(p.id, to: nil, fromPerson: pid); selectedFace = nil
                }
                Divider()
                ForEach(state.people.filter { $0.id != pid }, id: \.id) { other in
                    Button("Move to \(other.name)") {
                        state.reassignFace(p.id, to: other.id, fromPerson: pid); selectedFace = nil
                    }
                }
            }
            .menuStyle(.borderlessButton).font(.caption2).foregroundStyle(Theme.accent)
        }
    }

    // MARK: interaction
    /// Clamp helper so every zoom path stays inside the usable range.
    private static let minZoom: Float = 0.1, maxZoom: Float = 300
    private func zoom(by factor: Float) {
        camera.scale = max(Self.minZoom, min(Self.maxZoom, camera.scale * factor))
    }

    private func magnifyGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { v in camera.scale = max(Self.minZoom, min(Self.maxZoom, Float(v.magnification) * lastScale)) }
            .onEnded { _ in lastScale = camera.scale }
    }

    private func panGesture(viewSize: CGSize, fit: Float) -> some Gesture {
        DragGesture()
            .onChanged { v in
                if dragStart == nil { dragStart = camera }
                let s = camera.scale * fit
                camera.center = (dragStart ?? camera).center - SIMD2(Float(v.translation.width)/s, Float(v.translation.height)/s)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func nearestIndex(to pt: CGPoint, viewSize: CGSize, fit: Float) -> Int? {
        var best: Int?; var bestD = CGFloat(18*18) // 18pt pick radius
        let pts = state.faceMap.points
        for i in pts.indices {
            let s = camera.worldToScreen(pts[i].pos, viewSize: viewSize, fit: fit)
            let d = (s.x-pt.x)*(s.x-pt.x) + (s.y-pt.y)*(s.y-pt.y)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    private func nearestPoint(to pt: CGPoint, viewSize: CGSize, fit: Float) -> FaceMapPoint? {
        nearestIndex(to: pt, viewSize: viewSize, fit: fit).map { state.faceMap.points[$0] }
    }

    /// Cosine similarity (== dot, vectors are unit) from face `idx` to every face, via Accelerate.
    private func computeLensSims(_ idx: Int) -> [Float]? {
        let data = state.faceMap
        let n = data.points.count, dim = data.dim
        guard idx < n, data.vectors.count == n * dim else { return nil }
        var sims = [Float](repeating: 0, count: n)
        data.vectors.withUnsafeBufferPointer { mb in
            guard let m = mb.baseAddress else { return }
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(n), Int32(dim),
                        1, m, Int32(dim), m + idx * dim, 1, 0, &sims, 1)
        }
        return sims
    }
}
