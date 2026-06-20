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
                    legend
                }
                if let h = hovered { popover(for: h) }
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
