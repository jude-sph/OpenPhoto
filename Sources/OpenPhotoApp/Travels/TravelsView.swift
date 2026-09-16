import SwiftUI
import OpenPhotoCore

/// The Travels section: toolbar (summary line, Travels-folder picker, New trip, hints), the ring, an
/// inspector on the right while editing, and the trip page over everything when a trip is opened.
struct TravelsView: View {
    @Bindable var state: AppState
    @State private var showTravelsFolderPicker = false
    @State private var showNewTripPicker = false

    private var summaryLine: String {
        let t = state.travels; guard !t.isEmpty else { return "" }
        let photos = t.reduce(0) { $0 + $1.count }
        let years = t.compactMap(\.year)
        let span = years.isEmpty ? "" : " · \(years.min()!)–\(years.max()!)"
        return "\(t.count) travel\(t.count == 1 ? "" : "s") · \(photos.formatted()) photos\(span)"
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().overlay(Theme.hairline)
            HStack(spacing: 0) {
                ZStack {
                    TravelRingView(state: state)
                    if let id = state.openedTravelID, let trip = state.travels.first(where: { $0.id == id }) {
                        TravelDetailView(state: state, trip: trip)
                    }
                }
                if state.travelEditing, let id = state.selectedTravelID, let trip = state.travels.first(where: { $0.id == id }) {
                    Divider().overlay(Theme.hairline)
                    TravelInspector(state: state, trip: trip)          // Task 8 (placeholder until then)
                        .frame(width: Theme.inspectorWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.easeOut(duration: 0.25), value: state.travelEditing)
        }
        .sheet(isPresented: $showTravelsFolderPicker) {
            FolderPickerSheet(state: state, mode: .travelsFolder) { path, auto in state.setTravelsFolder(path, auto: auto) }
        }
        .sheet(isPresented: $showNewTripPicker) {
            FolderPickerSheet(state: state, mode: .newTrip) { path, _ in
                if state.createTravel(folder: path) != nil { state.travelEditing = true }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Travels").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
            Text(summaryLine).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textFaint)
            Spacer()
            Button {
                showTravelsFolderPicker = true
            } label: {
                let name = state.travelSettings.travelsFolder.map { ($0 as NSString).lastPathComponent }
                Label(state.travelSettings.autoDiscover && name != nil ? "Travels folder: \(name!)" : "No Travels folder",
                      systemImage: "folder")
            }
            .help("Every folder directly inside the Travels folder becomes a trip automatically")
            Button { showNewTripPicker = true } label: { Label("New trip", systemImage: "plus") }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            Text("Scroll, drag or ← → spin · ↩ opens · E edits").font(.system(size: 11.5)).foregroundStyle(Theme.textFaint)
        }
        .controlSize(.small)
        .padding(.horizontal, 16).frame(height: Theme.toolbarHeight)
    }
}
