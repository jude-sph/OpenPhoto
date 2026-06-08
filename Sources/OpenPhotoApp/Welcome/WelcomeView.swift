import SwiftUI
import OpenPhotoCore

struct WelcomeView: View {
    @Bindable var state: AppState
    var body: some View { Text("Welcome — replaced in Task 17").frame(maxWidth: .infinity, maxHeight: .infinity) }
}
