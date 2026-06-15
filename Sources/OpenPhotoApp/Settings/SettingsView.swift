import SwiftUI
import OpenPhotoCore

/// Native macOS Settings window (Cmd-,): General hosts the Finder-tag sync opt-in;
/// About surfaces on-device-analysis credits + the required GeoNames attribution.
struct SettingsView: View {
    @Bindable var state: AppState
    @State private var libStats: (count: Int, bytes: Int64)?

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            library
                .tabItem { Label("Library", systemImage: "folder") }
            about
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        // Sized for the tallest tab (Library: folder + stats + People & Faces controls). All tabs
        // share one frame, so this is set generously so nothing clips — the shorter tabs just have
        // extra whitespace.
        .frame(width: 480, height: 560)
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

    private var library: some View {
        Form {
            Text("Library folder").font(.system(size: 12, weight: .semibold))
            HStack {
                Image(systemName: "folder").foregroundStyle(Theme.accent)
                Text(state.configuredRoot?.path ?? "No folder chosen")
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack {
                Button("Change…") { changeRootViaPanel() }
                Button("Close Library") { state.closeLibraryAndForgetRoot() }
                    .disabled(state.library == nil)
            }
            if let s = libStats {
                Divider()
                HStack {
                    Text("Indexed media").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(s.count) item\(s.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: s.bytes, countStyle: .file))")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textDim)
                }
                Text("OpenPhoto's footprint — the photos and videos it indexes. This is less than the folder's total size on disk, which also holds Photos libraries, app bundles, and other files OpenPhoto skips.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Switching forgets OpenPhoto's index of the old folder and indexes the new one. Your photo files and any edits (favorites, tags, captions, people) are never touched — they live with the files.")
                .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("People & Faces").font(.system(size: 12, weight: .semibold))
            Text("Grouping sensitivity").font(.system(size: 11)).foregroundStyle(Theme.textDim)
            HStack(spacing: 8) {
                Text("Strict").font(.system(size: 10)).foregroundStyle(Theme.textDim)
                Slider(value: $state.faceSensitivity, in: 0...1) { editing in
                    if !editing { state.reclusterForSensitivity() }   // regroup instantly, no re-derive
                }
                .disabled(state.library == nil)
                Text("Loose").font(.system(size: 10)).foregroundStyle(Theme.textDim)
            }
            Button("Rescan Faces\u{2026}") { confirmRescanFaces() }
                .disabled(state.library == nil)
            Text("Higher pulls more loose faces into groups; lower groups more cautiously. Regroups instantly when you release the slider — people you've named are never changed. Run Rescan Faces to (re)detect and embed faces across your whole library.")
                .font(.system(size: 11)).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .task(id: state.refreshToken) {
            libStats = state.library.flatMap { try? $0.catalog.librarySize() }
        }
    }

    private func confirmRescanFaces() {
        let alert = NSAlert()
        alert.messageText = "Rescan all faces?"
        alert.informativeText = "OpenPhoto will re-detect and re-group faces across your entire library using the current recognition model. People you've named are kept. This runs in the background and can take a while."
        alert.addButton(withTitle: "Rescan")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { state.rescanFaces() }
    }

    private func changeRootViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = state.configuredRoot
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.message = "Choose the folder OpenPhoto should index."
        guard panel.runModal() == .OK, let url = panel.urls.first else { return }
        let alert = NSAlert()
        alert.messageText = "Switch OpenPhoto to \"\(url.lastPathComponent)\"?"
        alert.informativeText = "Photos from your current folder will be removed from OpenPhoto's views. Your files and edits are not touched."
        alert.addButton(withTitle: "Switch")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { state.changeRoot(to: url) }
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
