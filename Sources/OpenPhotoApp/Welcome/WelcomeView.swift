import SwiftUI
import OpenPhotoCore

struct WelcomeView: View {
    @Bindable var state: AppState
    @State private var root: URL?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text("Welcome to OpenPhoto").font(.system(size: 24, weight: .bold))
            Text("Your photos stay exactly where they are — regular files in regular folders.\nOpenPhoto only indexes them. Delete the app and your library is untouched.")
                .font(.system(size: 13)).foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)

            VStack(spacing: 6) {
                if let root {
                    HStack {
                        Image(systemName: "folder").foregroundStyle(Theme.accent)
                        Text(root.path).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Image(systemName: "checkmark").foregroundStyle(Theme.green)
                    }
                    .padding(10)
                    .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 9))
                }
                Button { chooseFolder() } label: {
                    Label(root == nil ? "Choose your photo folder…" : "Choose a different folder…",
                          systemImage: "plus")
                        .frame(maxWidth: .infinity).padding(10)
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Theme.hairline, style: .init(lineWidth: 1, dash: [5])))
                }.buttonStyle(.plain)
            }
            .frame(width: 460)

            Button("Open library") { if let root { state.openLibrary(roots: [root]) } }
                .buttonStyle(.borderedProminent)
                .disabled(root == nil)

            Text("Tip: choose your Pictures folder. Don't choose the Photos Library — that's Apple's internal database.")
                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK { root = panel.urls.first }
    }
}
