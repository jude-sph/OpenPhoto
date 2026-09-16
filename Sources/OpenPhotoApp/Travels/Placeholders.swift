import SwiftUI
import OpenPhotoCore

// Temporary stubs so TravelsView (Task 7) compiles ahead of the inspector (Task 8) and the trip
// page (Task 9). Task 8 deletes this file.

struct TravelInspector: View {
    let state: AppState
    let trip: TravelSummary
    var body: some View { EmptyView() }
}

struct TravelDetailView: View {
    let state: AppState
    let trip: TravelSummary
    var body: some View { EmptyView() }
}

struct FolderPickerSheet: View {
    enum Mode { case travelsFolder, newTrip, addFolder(exclude: [String]) }
    let state: AppState
    let mode: Mode
    let onPick: (String, Bool) -> Void
    init(state: AppState, mode: Mode, onPick: @escaping (String, Bool) -> Void) {
        self.state = state; self.mode = mode; self.onPick = onPick
    }
    var body: some View { EmptyView() }
}
