import SwiftUI
import OpenPhotoCore

struct SyncPlanSheet: View {
    @Bindable var state: AppState
    let drive: Vault
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack { Text("Sync (placeholder)"); Button("Close") { dismiss() } }
            .frame(width: 540, height: 360).padding()
    }
}
