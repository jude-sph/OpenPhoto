import SwiftUI
import OpenPhotoCore

struct FaceMapView: View {
    @Bindable var state: AppState
    @State private var camera = FaceMapCamera()
    @State private var dragStart: FaceMapCamera?
    @State private var hovered: FaceMapPoint?
    @State private var hoverScreen: CGPoint = .zero
    @State private var selectedPerson: Int64?
    @State private var selectedFace: FaceMapPoint?  // clicked dot → pinned inspector (reassign lives here)
    @State private var morphPath: [Int64]?        // conditional (Task 8)
    @State private var morphFrom: Int64?          // pending first shift-click endpoint
    @State private var morphPhase: CGFloat = 0    // animated dash offset for the lit path
    @State private var morphMiss = false          // brief "no clear resemblance path" hint
    @State private var lastScale: Float = 1        // magnify-gesture anchor

    var body: some View {
        GeometryReader { geo in
            let fit = FaceMapCamera.fit(for: geo.size)
            ZStack(alignment: .topLeading) {
                Theme.windowBG
                if state.faceMapLoading && state.faceMap.points.isEmpty {
                    ProgressView("Building face map…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    canvas(geo: geo, fit: fit)
                        // Shift-click drives the resemblance-path morph; it must take priority over
                        // the plain tap (which would otherwise consume the click and just select).
                        .gesture(shiftTapGesture(viewSize: geo.size, fit: fit))
                        .gesture(panGesture(viewSize: geo.size, fit: fit))
                        .gesture(magnifyGesture())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let pt): hovered = nearestPoint(to: pt, viewSize: geo.size, fit: fit); hoverScreen = pt
                            case .ended: hovered = nil
                            }
                        }
                        .onTapGesture(coordinateSpace: .local) { pt in
                            let p = nearestPoint(to: pt, viewSize: geo.size, fit: fit)
                            selectedPerson = p?.personID
                            selectedFace = p          // nil when clicking empty space → closes inspector
                        }
                    overlayCanvas(viewSize: geo.size, fit: fit)
                    morphCanvas(viewSize: geo.size, fit: fit)
                    legend
                    morphCaption
                }
                if let h = hovered { popover(for: h) }          // hover = info only, mouse-following
                if let f = selectedFace { faceInspector(for: f) } // click = pinned, interactive
            }
            .focusable().focusEffectDisabled()
            .onKeyPress(.init("=")) { zoom(by: 1.25); return .handled }
            .onKeyPress(.init("+")) { zoom(by: 1.25); return .handled }
            .onKeyPress(.init("-")) { zoom(by: 1 / 1.25); return .handled }
            .onKeyPress(.init("_")) { zoom(by: 1 / 1.25); return .handled }
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
            // Pass 1 — unassigned faces: a faint background haze (still hover-detected; hit-testing is
            // independent of draw order). Drawn first so named people sit on top.
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

    /// The conditional resemblance-path morph: a glowing underlay + an animated dashed stroke that
    /// "flows" between the two picked people through the island centers, with a per-hop name label.
    /// Draws nothing unless a good `morphPath` exists.
    private func morphCanvas(viewSize: CGSize, fit: Float) -> some View {
        Canvas { ctx, size in
            guard let path = morphPath, path.count > 1 else { return }
            let pts = path.compactMap { state.faceMap.personCentersByID[$0] }
                          .map { camera.worldToScreen($0, viewSize: size, fit: fit) }
            guard pts.count == path.count else { return }

            var line = Path(); line.move(to: pts[0]); for p in pts.dropFirst() { line.addLine(to: p) }
            // Soft glow underlay (two widths) → the line reads as "lit", not just drawn.
            ctx.stroke(line, with: .color(Theme.accent.opacity(0.18)),
                       style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round))
            ctx.stroke(line, with: .color(Theme.accent.opacity(0.30)),
                       style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            // Animated travelling dashes on a bright core.
            ctx.stroke(line, with: .color(Theme.accentHi),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round,
                                          dash: [10, 8], dashPhase: morphPhase))

            // Hop markers + name labels, sitting just above each island center.
            for (i, pid) in path.enumerated() {
                let c = pts[i]
                let isEnd = (i == 0 || i == path.count - 1)
                let dotR: CGFloat = isEnd ? 6 : 4
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - dotR, y: c.y - dotR, width: dotR * 2, height: dotR * 2)),
                         with: .color(Theme.accentHi))
                ctx.stroke(Path(ellipseIn: CGRect(x: c.x - dotR - 2, y: c.y - dotR - 2,
                                                  width: (dotR + 2) * 2, height: (dotR + 2) * 2)),
                           with: .color(Theme.accent.opacity(0.5)), lineWidth: 1.5)

                let label = state.personName(pid) ?? "?"
                let text = Text(label)
                    .font(isEnd ? .caption.bold() : .caption2.bold())
                    .foregroundColor(Theme.text)
                // Faint pill behind the label so it stays readable over dense dots.
                let resolved = ctx.resolve(text)
                let tsize = resolved.measure(in: size)
                let labelY = c.y - dotR - 12
                let pill = CGRect(x: c.x - tsize.width / 2 - 5, y: labelY - tsize.height / 2 - 2,
                                  width: tsize.width + 10, height: tsize.height + 4)
                ctx.fill(Path(roundedRect: pill, cornerRadius: 5), with: .color(Theme.windowBG.opacity(0.78)))
                ctx.draw(resolved, at: CGPoint(x: c.x, y: labelY))
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { morphPhase = -18 }
        }
    }

    /// Bottom caption strip: the resemblance chain ("Jude › Bo › Sky › Nina › Gran Gran") when a path
    /// is lit, or a brief hint when a shift-pair produced no good path.
    @ViewBuilder private var morphCaption: some View {
        if let path = morphPath, path.count > 1 {
            let chain = path.map { state.personName($0) ?? "?" }.joined(separator: "  ›  ")
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars").font(.caption2).foregroundStyle(Theme.accentHi)
                Text(chain).font(.callout.weight(.medium)).foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Theme.accent.opacity(0.35), lineWidth: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 18)
            .allowsHitTesting(false)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if morphMiss {
            Text("No clear resemblance path")
                .font(.caption).foregroundStyle(Theme.textDim)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 18)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
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
            HStack(alignment: .top, spacing: 8) {
                FaceCropView(state: state, faceID: p.id, hash: nil, size: 56, fill: false)
                    .frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.personID.flatMap { state.personName($0) } ?? "Unassigned")
                        .font(.callout.weight(.semibold)).foregroundStyle(Theme.text)
                    if isReassignableOutlier(p) {
                        Text("looks unlike this person").font(.caption2).foregroundStyle(Theme.amber)
                    }
                }
                Spacer(minLength: 0)
                Button { selectedFace = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textDim)
            }
            if p.personID != nil { reassignControl(for: p) }
        }
        .padding(10).frame(width: 230)
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

    // MARK: resemblance-path morph (Task 8)
    /// Fires only while Shift is held (so plain clicks keep selecting). Maps the tapped location to
    /// the nearest dot's person and drives `handleShiftTap`.
    private func shiftTapGesture(viewSize: CGSize, fit: Float) -> some Gesture {
        SpatialTapGesture()
            .modifiers(.shift)
            .onEnded { value in
                let p = nearestPoint(to: value.location, viewSize: viewSize, fit: fit)
                handleShiftTap(personID: p?.personID)
            }
    }

    /// First shift-click on a person arms the path's start; the second computes a "good" resemblance
    /// path to it. A click on empty space (or repeating the same person) clears the pending state.
    private func handleShiftTap(personID: Int64?) {
        morphMiss = false
        guard let pid = personID else { morphFrom = nil; morphPath = nil; return }
        if let a = morphFrom, a != pid {
            let path = FaceResemblance.resemblancePath(
                centroids: state.faceMap.centroidsByID, from: a, to: pid,
                k: 5, minEdgeSim: 0.18, minNodes: 3, maxNodes: 6)
            morphPath = path
            morphFrom = nil
            if path == nil { flashMorphMiss() }
        } else {
            morphFrom = pid
            morphPath = nil
        }
    }

    /// Briefly surface the "no clear resemblance path" hint, then auto-dismiss.
    private func flashMorphMiss() {
        morphMiss = true
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if morphPath == nil { morphMiss = false }
        }
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

    private func nearestPoint(to pt: CGPoint, viewSize: CGSize, fit: Float) -> FaceMapPoint? {
        var best: FaceMapPoint?; var bestD = CGFloat(18*18) // 18pt pick radius
        for p in state.faceMap.points {
            let s = camera.worldToScreen(p.pos, viewSize: viewSize, fit: fit)
            let d = (s.x-pt.x)*(s.x-pt.x) + (s.y-pt.y)*(s.y-pt.y)
            if d < bestD { bestD = d; best = p }
        }
        return best
    }
}
