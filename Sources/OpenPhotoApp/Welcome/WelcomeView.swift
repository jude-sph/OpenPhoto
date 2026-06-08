import SwiftUI
import OpenPhotoCore

struct WelcomeView: View {
    @Bindable var state: AppState
    @State private var roots: [URL] = []

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 44)).foregroundStyle(Theme.accent)
            Text("Welcome to OpenPhoto").font(.system(size: 24, weight: .bold))
            Text("Your photos stay exactly where they are — regular files in regular folders.\nOpenPhoto only indexes them. Delete the app and your library is untouched.")
                .font(.system(size: 13)).foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)

            VStack(spacing: 6) {
                ForEach(roots, id: \.self) { url in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(Theme.accent)
                        Text(url.path).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Image(systemName: "checkmark").foregroundStyle(Theme.green)
                        Button { roots.removeAll { $0 == url } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textFaint)
                        }.buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 9))
                }
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = true
                    panel.directoryURL = FileManager.default.urls(for: .picturesDirectory,
                                                                  in: .userDomainMask).first
                    if panel.runModal() == .OK {
                        roots.append(contentsOf: panel.urls.filter { !roots.contains($0) })
                    }
                } label: {
                    Label("Choose a folder…", systemImage: "plus")
                        .frame(maxWidth: .infinity).padding(10)
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Theme.hairline, style: .init(lineWidth: 1, dash: [5])))
                }.buttonStyle(.plain)
            }
            .frame(width: 460)

            Button("Open library") { state.openLibrary(roots: roots) }
                .buttonStyle(.borderedProminent)
                .disabled(roots.isEmpty)

            Text("Suggested: your Pictures and Movies folders.")
                .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
