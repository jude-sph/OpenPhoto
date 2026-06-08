import SwiftUI
import OpenPhotoCore

@main
struct OpenPhotoApp: App {
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("OpenPhoto") {
            RootView(state: state)
                .frame(minWidth: 1100, minHeight: 700)
                .background(Theme.windowBG)
                .tint(Theme.accent)
                .task {
                    let roots = state.configuredRoots
                    if !roots.isEmpty { state.openLibrary(roots: roots) }
                }
        }
        .windowStyle(.hiddenTitleBar)
    }
}

struct RootView: View {
    @Bindable var state: AppState

    var body: some View {
        if state.library == nil {
            WelcomeView(state: state)
        } else {
            ZStack {
                HStack(spacing: 0) {
                    SidebarView(state: state)
                    Divider().overlay(Theme.hairline)
                    detail
                }
                if state.openedItem != nil {
                    ViewerView(state: state)   // full-window overlay
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch state.selection {
        case .timeline: TimelineView(state: state)
        case .folders: FoldersView(state: state)
        case .bin: BinView(state: state)
        }
    }
}
