import SwiftUI
import OpenPhotoCore

struct CleanupView: View {
    @Bindable var state: AppState
    var body: some View {
        Color.clear.onAppear { state.loadCullGroups() }
    }
}
