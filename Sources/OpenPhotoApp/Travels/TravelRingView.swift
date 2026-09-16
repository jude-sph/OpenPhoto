import SwiftUI
import OpenPhotoCore

/// The ring: trips as postcards standing in a circle around you, newest at the front, spun by
/// trackpad scroll, drag, or arrow keys with inertia + snap, and a ratchet click as each card crosses
/// the front. Geometry lives in `RingGeometry` (Core, unit-tested); this view only applies it.
struct TravelRingView: View {
    @Bindable var state: AppState

    @State private var angle = 0.0            // ring rotation, degrees; card i is at i·step − angle
    @State private var velocity = 0.0
    @State private var target: Double?        // snap/step target, eased
    @State private var lastTick = Date()
    @State private var lastClickIndex = -1
    @State private var dragStartX: CGFloat?
    private let geo = RingGeometry()
    private let clock = Timer.publish(every: 1 / 60, on: .main, in: .common).autoconnect()

    private var trips: [TravelSummary] { state.travels }
    private var count: Int { trips.count }
    private var step: Double { RingGeometry.step(count: count) }
    private var focusedIndex: Int { count == 0 ? 0 : ((Int((angle / step).rounded()) % count) + count) % count }
    private var focused: TravelSummary? { trips.isEmpty ? nil : trips[focusedIndex] }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack {
                Theme.windowBG
                // Nothing of the ring is drawn while the trip page is over it — a card sliding past
                // the stage edge would otherwise show beside the page.
                if trips.isEmpty { emptyState } else if state.openedTravelID == nil {
                    ring(width: w, height: g.size.height)
                    yearNumeral
                    meta
                    yearStrip
                }
                // While the trip page covers the ring the catcher would eat its scrolling.
                if state.openedTravelID == nil {
                    ScrollWheelCatcher { dx, dy in
                        target = nil
                        let d = abs(dx) > abs(dy) ? dx : dy
                        velocity += Double(d) * 0.045
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3).onChanged { v in
                if dragStartX == nil { dragStartX = v.location.x; target = nil; velocity = 0 }
                let dx = v.location.x - (dragStartX ?? v.location.x); dragStartX = v.location.x
                angle += Double(dx) * -0.16; velocity = Double(dx) * -0.16 * 0.9
            }.onEnded { _ in dragStartX = nil })
            .onReceive(clock) { now in tick(now) }
            .onChange(of: state.selectedTravelID) { _, id in
                // Only follow selections from OUTSIDE the ring (folder context menu, etc.). While the
                // ring is spinning it publishes the selection itself, and a delivery that lands after
                // the angle has moved on would yank the physics into eased-target mode mid-flick.
                guard dragStartX == nil, velocity == 0, target == nil else { return }
                if let id, let i = trips.firstIndex(where: { $0.id == id }), i != focusedIndex { stepTo(i) }
            }
            .onChange(of: trips.map(\.id)) { _, _ in
                // The set changed (edit re-sorted it, a trip was added/removed): keep the selected trip in front.
                if let id = state.selectedTravelID, let i = trips.firstIndex(where: { $0.id == id }) {
                    angle = Double(i) * step; target = nil; velocity = 0
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.rightArrow) { guard ringTakesKeys else { return .ignored }; stepTo((focusedIndex + 1) % max(count, 1)); return .handled }
        .onKeyPress(.leftArrow) { guard ringTakesKeys else { return .ignored }; stepTo((focusedIndex - 1 + count) % max(count, 1)); return .handled }
        .onKeyPress(.return) { guard ringTakesKeys, let f = focused else { return .ignored }; state.openedTravelID = f.id; return .handled }
        .onKeyPress(.init("e")) { guard ringTakesKeys, focused != nil else { return .ignored }; state.travelEditing = true; return .handled }
        .onKeyPress(.escape) { guard ringTakesKeys, state.travelEditing else { return .ignored }; state.travelEditing = false; return .handled }
        .onKeyPress(.home) { guard ringTakesKeys else { return .ignored }; stepTo(0); return .handled }
        .onKeyPress(.end) { guard ringTakesKeys else { return .ignored }; stepTo(max(count - 1, 0)); return .handled }
    }

    // MARK: physics

    /// The ring keeps its keys (and its selection publishing) to itself while the trip page is over it.
    private var ringTakesKeys: Bool { !state.isEditingText && state.openedTravelID == nil }

    /// The ring publishes its focused trip as the app selection — unless the trip page is over it, or
    /// the selection already names that trip.
    private var wantsFocusPublish: Bool {
        state.openedTravelID == nil && focused != nil && focused?.id != state.selectedTravelID
    }

    private func tick(_ now: Date) {
        // At rest with nothing to publish: return before touching any @State. Writing `lastTick` alone
        // would invalidate the ring 60 times a second for a picture that never changes. `dt` is clamped
        // below, so the first tick after an idle spell still steps by at most ~40 ms.
        if velocity == 0, target == nil, count > 0, !wantsFocusPublish { return }
        let dt = min(40, now.timeIntervalSince(lastTick) * 1000) / 16.7; lastTick = now
        guard count > 0 else { return }
        if let t = target {
            let d = RingGeometry.wrapDelta(t - angle); angle += d * 0.12 * dt
            if abs(d) < 0.05 { angle = t; target = nil }
        } else {
            angle += velocity * dt; velocity *= pow(0.92, dt)
            if abs(velocity) < 0.08 {
                velocity = 0
                let snap = (angle / step).rounded() * step
                if abs(snap - angle) > 0.01 { target = snap }
            }
        }
        // ratchet: one click per card crossing the front while spinning
        let idx = Int((angle / step).rounded())
        if abs(velocity) > 0.3 && idx != lastClickIndex { lastClickIndex = idx; RatchetSound.shared.click() }
        // publish the focused trip
        if wantsFocusPublish, let f = focused, target == nil || abs(RingGeometry.wrapDelta((target ?? angle) - angle)) < step / 2 {
            state.selectedTravelID = f.id
        }
    }

    private func stepTo(_ i: Int) { guard count > 0 else { return }; target = angle + RingGeometry.wrapDelta(Double(i) * step - angle) }

    // MARK: ring

    private func ring(width: CGFloat, height: CGFloat) -> some View {
        let zoom = geo.zoom(forStageWidth: Double(width), count: count)
        return ZStack {
            ForEach(Array(trips.enumerated()), id: \.element.id) { i, trip in
                let p = geo.placement(index: i, count: count, angle: angle, stageWidth: Double(width))
                if !p.hidden {
                    card(trip, focused: i == focusedIndex)
                        .rotation3DEffect(.degrees(p.angle), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                        .scaleEffect(p.scale)
                        .offset(x: p.x)
                        .zIndex(1 - p.depth)
                        .onTapGesture { if i == focusedIndex { state.openedTravelID = trip.id } else { stepTo(i) } }
                }
            }
        }
        .scaleEffect(zoom)
        .frame(width: width, height: height)
        .offset(y: -height * 0.04)
        // The ring is wider than the stage by design (cards slide off the edges); without this they
        // would draw over the sidebar, the toolbar and the trip page.
        .clipped()
    }

    /// Every card is exactly `cardWidth` × `cardHeight`, whatever the cover photo's aspect: the
    /// thumbnail is given that frame and clipped INSIDE the card, so the rounded clip, the caption
    /// and the border all land on one postcard shape rather than on the image's natural rectangle.
    private func card(_ trip: TravelSummary, focused: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let lib = state.library {
                Self.coverThumbnail(for: trip, library: lib, targetPixel: 512)
                    .frame(width: geo.cardWidth, height: geo.cardHeight)
                    .clipped()
            } else {
                Theme.tile.frame(width: geo.cardWidth, height: geo.cardHeight)
            }
            LinearGradient(colors: [.black.opacity(0.72), .clear], startPoint: .bottom, endPoint: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text([trip.country, trip.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11, weight: .medium).monospacedDigit()).opacity(0.8)
            }
            .foregroundStyle(.white).padding(14)
        }
        .frame(width: geo.cardWidth, height: geo.cardHeight)
        .overlay(alignment: .topTrailing) {
            Text(trip.count.formatted()).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 2).background(.black.opacity(0.5), in: Capsule()).padding(10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? Theme.accent : .white.opacity(0.08), lineWidth: focused ? 2 : 1))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 30)
    }

    /// Cover image for a trip (its `coverHash`), by content hash from the thumbnail store.
    static func coverThumbnail(for trip: TravelSummary, library: LibraryService, targetPixel: Int) -> some View {
        let hash = trip.coverHash ?? ""
        let lib = library
        return ThumbnailImage(id: "travel-cover:" + trip.id + ":" + hash, provider: { px in
            guard !hash.isEmpty else { return nil }
            let h = ContentHash(stringValue: hash)
            if let img = await lib.thumbnails.cachedDisplayImage(for: h, maxPixel: px) { return img }
            if let item = try? lib.catalog.item(hash: hash), let url = lib.absoluteURL(for: item) {
                return try? await lib.thumbnails.displayImage(for: h, sourceURL: url, kind: MediaKind(rawValue: item.kind) ?? .photo, maxPixel: px)
            }
            return nil
        }, targetPixel: targetPixel)
    }

    // MARK: chrome

    private var yearNumeral: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(focused?.year.map(String.init) ?? "—")
                .font(.system(size: 64, weight: .ultraLight).monospacedDigit()).kerning(-2).foregroundStyle(Theme.text).opacity(0.9)
            Text("SPIN TO TRAVEL BACK").font(.system(size: 11, weight: .semibold)).kerning(0.9).foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(.top, 16).padding(.trailing, 26)
        .allowsHitTesting(false)
    }

    private var meta: some View {
        VStack(spacing: 5) {
            Text(focused?.name ?? "").font(.system(size: 26, weight: .semibold)).kerning(-0.5)
            if let f = focused {
                HStack(spacing: 6) {
                    Text(TravelFormat.span(f)).monospacedDigit()
                    if f.datesOverridden { Circle().fill(Theme.amber).frame(width: 6, height: 6).help("Dates set by hand") }
                    Text("·").foregroundStyle(Theme.textFaint)
                    Text(f.places.isEmpty ? "no places" : f.places.map(\.name).joined(separator: ", ")).lineLimit(1)
                    Text("·").foregroundStyle(Theme.textFaint)
                    Text("\(f.count.formatted()) photos").monospacedDigit()
                }
                .font(.system(size: 13.5)).foregroundStyle(Theme.textDim)
            }
            HStack(spacing: 8) {
                Button("Edit trip") { state.travelEditing = true }
                Button("Open trip") { state.openedTravelID = focused?.id }.buttonStyle(.borderedProminent).tint(Theme.accent)
            }.controlSize(.small).padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 60)
    }

    private var yearStrip: some View {
        let years = Array(Set(trips.compactMap(\.year))).sorted(by: >)
        return HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(years.enumerated()), id: \.element) { k, y in
                let on = focused?.year == y
                Button {
                    if let i = trips.firstIndex(where: { $0.year == y }) { stepTo(i) }
                } label: {
                    VStack(spacing: 5) {
                        Rectangle().fill(on ? Theme.accent : Theme.textFaint.opacity(0.6)).frame(width: 1, height: on ? 16 : 10)
                        Text(String(y)).font(.system(size: 10.5, weight: .semibold).monospacedDigit()).kerning(0.4)
                            .foregroundStyle(on ? Theme.accent : Theme.textFaint)
                    }.padding(.horizontal, 10)
                }.buttonStyle(.plain)
                if k < years.count - 1 {
                    ForEach(0..<max(0, min(y - years[k + 1], 6) - 1), id: \.self) { _ in
                        Rectangle().fill(Theme.hairline).frame(width: 1, height: 6).padding(.horizontal, 3).padding(.bottom, 15)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("No travels yet").font(.system(size: 18, weight: .semibold))
            Text("Pick a Travels folder and every trip folder inside it shows up here, or add trips one folder at a time.")
                .foregroundStyle(Theme.textDim).multilineTextAlignment(.center).frame(maxWidth: 380)
        }
    }
}

/// Human formatting shared by the ring, inspector and trip page.
enum TravelFormat {
    static func date(_ s: String) -> Date? {
        let p = s.split(separator: "-").compactMap { Int($0) }; guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
    static func days(_ t: TravelSummary) -> Int {
        guard let a = t.startDate.flatMap(date), let b = t.endDate.flatMap(date) else { return 0 }
        return (Calendar.current.dateComponents([.day], from: a, to: b).day ?? 0) + 1
    }
    /// "3 Apr – 15 Apr 2026 · 13 days"
    static func span(_ t: TravelSummary) -> String {
        guard let a = t.startDate.flatMap(date), let b = t.endDate.flatMap(date) else { return "no dates" }
        let f = Date.FormatStyle().month(.abbreviated).day()
        let ya = Calendar.current.component(.year, from: a), yb = Calendar.current.component(.year, from: b)
        let y = ya == yb ? String(yb) : "\(ya)–\(yb)"
        let n = days(t)
        return "\(a.formatted(f)) – \(b.formatted(f)) \(y) · \(n) day\(n == 1 ? "" : "s")"
    }
}
