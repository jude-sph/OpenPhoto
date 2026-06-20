import SwiftUI

struct FaceMapView: View {
    @Bindable var state: AppState
    @State private var camera = FaceMapCamera()
    @State private var dragStart: FaceMapCamera?
    @State private var hovered: FaceMapPoint?
    @State private var hoverScreen: CGPoint = .zero
    @State private var selectedPerson: Int64?
    @State private var morphPath: [Int64]?        // conditional (Task 8)
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
                        }
                    overlayCanvas(viewSize: geo.size, fit: fit)
                    legend
                }
                if let h = hovered {
                    if isReassignableOutlier(h) {
                        popoverInteractive(for: h)
                    } else {
                        popover(for: h)
                    }
                }
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
            let r: CGFloat = max(1.5, CGFloat(camera.scale) * 2.2)
            for p in pts {
                let s = camera.worldToScreen(p.pos, viewSize: size, fit: fit)
                if s.x < -10 || s.y < -10 || s.x > size.width+10 || s.y > size.height+10 { continue } // cull
                let color = p.personID.map { Theme.colorForPerson($0) } ?? Theme.personColorUnassigned
                let dimmed = (p.personID == nil) ? color.opacity(0.5) : color
                ctx.fill(Path(ellipseIn: CGRect(x: s.x-r, y: s.y-r, width: r*2, height: r*2)), with: .color(dimmed))
            }
        }
        .drawingGroup() // GPU-composite the dot layer
    }

    /// Lookalike lines + typicality markers for the selected person, drawn above the dots.
    /// No-ops when nothing is selected.
    private func overlayCanvas(viewSize: CGSize, fit: Float) -> some View {
        Canvas { ctx, size in
            guard let pid = selectedPerson, let from = state.faceMap.personCentersByID[pid] else { return }
            let a = camera.worldToScreen(from, viewSize: size, fit: fit)
            // Lookalike lines: solid bold for mutual, dashed thin otherwise.
            for la in state.faceMap.lookalikes[pid] ?? [] {
                guard let cb = state.faceMap.personCentersByID[la.personID] else { continue }
                let b = camera.worldToScreen(cb, viewSize: size, fit: fit)
                var path = Path(); path.move(to: a); path.addLine(to: b)
                ctx.stroke(path, with: .color(Theme.accent.opacity(la.mutual ? 0.9 : 0.5)),
                           style: StrokeStyle(lineWidth: la.mutual ? 2.5 : 1.5, dash: la.mutual ? [] : [4, 3]))
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
        }.padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(10)
    }

    /// True when `p` belongs to the currently selected person AND is one of that person's outliers,
    /// i.e. the popover should expose the "Not [name]?" reassign menu (and be interactive).
    private func isReassignableOutlier(_ p: FaceMapPoint) -> Bool {
        guard let pid = p.personID, pid == selectedPerson else { return false }
        return state.faceMap.typicalityByID[pid]?.outliers.contains(p.id) == true
    }

    /// Shared popover body (thumbnail + name). The reassign control is appended only for the
    /// interactive variant so the non-interactive popover stays a pure overlay.
    @ViewBuilder private func popoverBody(for p: FaceMapPoint, interactive: Bool) -> some View {
        VStack(spacing: 4) {
            FaceCropView(state: state, faceID: p.id, hash: nil, size: 72, fill: false)
                .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
            Text(p.personID.flatMap { state.personName($0) } ?? "Unassigned")
                .font(.caption).foregroundStyle(Theme.text)
            if interactive { reassignControl(for: p) }
        }
        .padding(6).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .fixedSize().position(x: hoverScreen.x, y: max(48, hoverScreen.y - 60))
    }

    /// Plain, non-interactive popover (pointer events pass straight through to the canvas).
    private func popover(for p: FaceMapPoint) -> some View {
        popoverBody(for: p, interactive: false).allowsHitTesting(false)
    }

    /// Interactive popover used for reassignable outliers — NO `.allowsHitTesting(false)`, so the
    /// "Not [name]?" menu is clickable.
    private func popoverInteractive(for p: FaceMapPoint) -> some View {
        popoverBody(for: p, interactive: true)
    }

    /// "Not [name]?" menu: remove from this person, or move to any other person. Each action
    /// reassigns via the existing `reassignFace` and reloads so the dot recolors immediately.
    @ViewBuilder private func reassignControl(for p: FaceMapPoint) -> some View {
        if let pid = p.personID {
            Menu("Not \(state.personName(pid) ?? "this person")?") {
                Button("Remove from this person") {
                    state.reassignFace(p.id, to: nil, fromPerson: pid); state.loadFaceMap()
                }
                Divider()
                ForEach(state.people.filter { $0.id != pid }, id: \.id) { other in
                    Button("Move to \(other.name)") {
                        state.reassignFace(p.id, to: other.id, fromPerson: pid); state.loadFaceMap()
                    }
                }
            }
            .menuStyle(.borderlessButton).font(.caption2).foregroundStyle(Theme.accent)
        }
    }

    // MARK: interaction
    /// Clamp helper so every zoom path stays inside the usable range.
    private func zoom(by factor: Float) {
        camera.scale = max(0.2, min(40, camera.scale * factor))
    }

    private func magnifyGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { v in camera.scale = max(0.2, min(40, Float(v.magnification) * lastScale)) }
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
