import SwiftUI

struct ImportView: View {
    @Bindable var state: AppState
    let device: ConnectedDevice
    var body: some View {
        Text("Import — Task 7").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
