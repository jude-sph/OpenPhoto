import SwiftUI
import OpenPhotoCore

/// Native macOS Settings window (Cmd-,): General hosts the Finder-tag sync opt-in;
/// About surfaces on-device-analysis credits + the required GeoNames attribution.
struct SettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            about
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 460, height: 280)
        .tint(Theme.accent)
    }

    private var general: some View {
        Form {
            Toggle("Sync tags with Finder", isOn: $state.finderTagSyncEnabled)
            Text("Mirrors your tags to macOS Finder tags on this Mac's files, two-way. Off by default; turning it on writes Finder tags to your originals (non-destructive).")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Button("Sync Finder tags now") { state.syncFinderTagsNow() }
                .disabled(!state.finderTagSyncEnabled)
        }
        .padding()
    }

    private var about: some View {
        VStack(spacing: 10) {
            Text("OpenPhoto")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.text)
            Text("Your photos stay yours — the library is just files.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
            Spacer().frame(height: 6)
            Text("On-device analysis uses Apple Vision + Core ML (MobileCLIP).")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textDim)
            Link("Place data © GeoNames (geonames.org), CC BY 4.0.",
                 destination: URL(string: "https://www.geonames.org")!)
                .font(.system(size: 12))
        }
        .multilineTextAlignment(.center)
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
