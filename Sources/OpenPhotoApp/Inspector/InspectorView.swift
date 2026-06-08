import SwiftUI
import OpenPhotoCore

struct InspectorView: View {
    @Bindable var state: AppState
    let item: TimelineItem
    var body: some View { Text("Inspector — Task 21").frame(maxHeight: .infinity) }
}
