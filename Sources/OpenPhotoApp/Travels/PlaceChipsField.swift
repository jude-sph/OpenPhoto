import SwiftUI
import OpenPhotoCore

/// Which inspector text field holds the keyboard. ONE shared `@FocusState` value rather than a Bool
/// per field: `state.isEditingText` is then derived from a single change, so clicking straight from
/// the name field into the place field can't land a stale `false` after the new field's `true` and
/// leave the ring stealing arrow keys mid-word.
enum TravelTextField: Hashable { case name, place }

/// Place chips + a type-to-add field with GeoNames suggestions. Return picks the highlighted
/// suggestion (map-recognised, with coordinates); with no suggestion it saves free text, shown as an
/// outlined chip titled "not on the map". Detected (non-overridden) places render as neutral chips.
struct PlaceChipsField: View {
    @Bindable var state: AppState
    let places: [TravelPlace]
    let overridden: Bool
    var focus: FocusState<TravelTextField?>.Binding
    let onChange: ([TravelPlace]) -> Void

    @State private var text = ""
    @State private var suggestions: [TravelPlace] = []
    @State private var highlighted = 0

    private var focused: Bool { focus.wrappedValue == .place }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayoutLite(spacing: 6) {
                ForEach(Array(places.enumerated()), id: \.offset) { i, p in chip(p, index: i) }
                TextField("Add place…", text: $text)
                    .textFieldStyle(.plain).font(.system(size: 12)).frame(minWidth: 90)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .overlay(Capsule().strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                    .focused(focus, equals: .place)
                    .onChange(of: text) { _, t in
                        suggestions = state.placeSearch.suggest(t, limit: 6)
                        highlighted = 0
                    }
                    .onSubmit { commit() }
                    .onKeyPress(.downArrow) {
                        highlighted = min(highlighted + 1, max(suggestions.count - 1, 0)); return .handled
                    }
                    .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
                    .onKeyPress(.escape) {
                        // Only ours to eat when there is something to dismiss.
                        guard !text.isEmpty || !suggestions.isEmpty else { return .ignored }
                        text = ""; suggestions = []; return .handled
                    }
            }
            if !suggestions.isEmpty && focused {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { i, s in
                        HStack(spacing: 6) {
                            Text(s.name).font(.system(size: 12.5, weight: .medium))
                            Text([s.region, s.country].compactMap { $0 }.joined(separator: ", "))
                                .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                            Spacer()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(i == highlighted ? Theme.accentDim : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture { highlighted = i; commit() }
                    }
                }
                .padding(4).background(Theme.elevated, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
            }
        }
    }

    private func chip(_ p: TravelPlace, index: Int) -> some View {
        HStack(spacing: 4) {
            Text(p.name).font(.system(size: 12, weight: .medium))
            Button {
                var n = places; n.remove(at: index); onChange(n)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain).opacity(0.7)
        }
        .padding(.leading, 9).padding(.trailing, 6).padding(.vertical, 3)
        .background(overridden && p.isOnMap ? Theme.accentDim : Theme.elevated, in: Capsule())
        .overlay(Capsule().strokeBorder(p.isOnMap ? Theme.hairline : Theme.amber.opacity(0.7),
                                        style: StrokeStyle(lineWidth: 1, dash: p.isOnMap ? [] : [3, 2])))
        .foregroundStyle(overridden && p.isOnMap ? Theme.accent : Theme.text)
        .help(p.isOnMap ? [p.region, p.country].compactMap { $0 }.joined(separator: ", ") : "not on the map")
    }

    /// Return (or a click) takes the highlighted suggestion — a real map place with coordinates and a
    /// GeoNames id. With nothing suggested the typed words are saved as they are.
    private func commit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let pick = suggestions.indices.contains(highlighted) ? suggestions[highlighted] : TravelPlace(name: t)
        let dupe = places.contains {
            ($0.geonameID != nil && $0.geonameID == pick.geonameID)
                || $0.name.caseInsensitiveCompare(pick.name) == .orderedSame
        }
        if !dupe { onChange(places + [pick]) }
        text = ""; suggestions = []
    }
}
