import SwiftUI
import MapKit
import OpenPhotoCore

struct InspectorView: View {
    @Bindable var state: AppState
    let item: TimelineItem

    @State private var caption = ""
    @State private var rating = 0
    @State private var favorite = false
    @State private var tags: [String] = []
    @State private var newTag = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(Date(timeIntervalSince1970: Double(item.takenAtMs) / 1000)
                    .formatted(date: .complete, time: .shortened))
                    .font(.system(size: 13, weight: .semibold))

                section("Caption") {
                    TextField("Add a caption…", text: $caption, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .padding(8).background(Theme.elevated, in: RoundedRectangle(cornerRadius: 8))
                        .onSubmit { save() }
                }

                section("Rating") {
                    HStack(spacing: 4) {
                        ForEach(1...5, id: \.self) { i in
                            Button {
                                rating = (rating == i) ? 0 : i
                                save()
                            } label: {
                                Image(systemName: i <= rating ? "star.fill" : "star")
                                    .foregroundStyle(i <= rating ? Theme.amber : Theme.textFaint)
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                        Button {
                            favorite.toggle(); save()
                        } label: {
                            Image(systemName: favorite ? "heart.fill" : "heart")
                                .foregroundStyle(favorite ? Theme.accent : Theme.textFaint)
                        }.buttonStyle(.plain)
                    }
                }

                section("Tags") {
                    FlowLayoutLite(spacing: 6) {
                        ForEach(tags, id: \.self) { tag in
                            HStack(spacing: 4) {
                                Text(tag).font(.system(size: 12))
                                Button {
                                    tags.removeAll { $0 == tag }; save()
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.accentDim, in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(Theme.accent)
                        }
                        TextField("Add tag", text: $newTag)
                            .textFieldStyle(.plain).font(.system(size: 12)).frame(width: 70)
                            .onSubmit {
                                let t = newTag.trimmingCharacters(in: .whitespaces)
                                if !t.isEmpty, !tags.contains(t) { tags.append(t); save() }
                                newTag = ""
                            }
                    }
                }

                Divider().overlay(Theme.hairline)

                section(item.cameraModel ?? "Camera") {
                    exifGrid
                }

                if let lat = item.latitude, let lon = item.longitude {
                    section("Location") {
                        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                        Map(initialPosition: .region(MKCoordinateRegion(
                            center: coord,
                            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)))) {
                            Marker("", coordinate: coord).tint(Theme.accent)
                        }
                        .frame(height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .allowsHitTesting(false)
                        Text(String(format: "%.4f, %.4f", lat, lon))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textFaint)
                    }
                }

                Divider().overlay(Theme.hairline)

                section("Presence") {
                    HStack(spacing: 8) {
                        Image(systemName: "laptopcomputer")
                        Text("This Mac").font(.system(size: 12.5))
                        Spacer()
                        Image(systemName: "checkmark").foregroundStyle(Theme.green)
                    }
                    // Drive rows arrive in Phase 3 with the presence map UI.
                }

                section("File") {
                    Text(item.relPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textDim)
                        .textSelection(.enabled)
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: item.size,
                                                       countStyle: .file))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.textFaint)
                        Spacer()
                        Button("Reveal in Finder") {
                            if let url = state.library?.absoluteURL(for: item) {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
                        }.controlSize(.small)
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.bg2)
        .task(id: item.hash) { load() }
    }

    private var exifGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
            if let w = item.pixelWidth, let h = item.pixelHeight {
                GridRow { gLabel("Dimensions"); gValue("\(w) × \(h)") }
            }
            if let lens = item.lensModel { GridRow { gLabel("Lens"); gValue(lens) } }
            if let d = item.durationSeconds {
                GridRow { gLabel("Duration"); gValue(String(format: "%.1fs", d)) }
            }
            GridRow { gLabel("Kind"); gValue(item.livePairHash != nil ? "Live Photo" : item.kind) }
        }
    }

    private func gLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(Theme.textFaint)
    }
    private func gValue(_ s: String) -> some View {
        Text(s).font(.system(size: 12, weight: .semibold).monospacedDigit())
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold)).kerning(0.4)
                .foregroundStyle(Theme.textFaint)
            content()
        }
    }

    private func load() {
        caption = item.caption ?? ""
        rating = item.rating
        favorite = item.favorite
        tags = (try? JSONDecoder().decode([String].self,
                                          from: Data(item.tagsJSON.utf8))) ?? []
    }

    private func save() {
        guard let lib = state.library else { return }
        try? lib.updateMetadata(for: item,
                                rating: rating, favorite: favorite,
                                caption: caption.isEmpty ? nil : caption, tags: tags)
        try? state.refreshQueries()
        if let updated = try? lib.item(hash: item.hash) { state.openedItem = updated }
    }
}

/// Minimal wrapping layout for tag chips.
struct FlowLayoutLite: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
