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
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    MainActor.assumeIsolated { state.sidebarShown.toggle() }
                }
                .keyboardShortcut("\\", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Open Folder as Import Source…") {
                    MainActor.assumeIsolated { state.addImportSourceViaPanel() }
                }
                Button("Quick View Folder\u{2026}") {
                    MainActor.assumeIsolated { state.quickViewFolderViaPanel() }
                }
            }
        }
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
                    if state.sidebarShown {
                        SidebarView(state: state)
                    } else {
                        VStack(spacing: 0) {
                            Button {
                                state.sidebarShown = true
                            } label: {
                                Image(systemName: "sidebar.left")
                                    .foregroundStyle(Theme.textDim)
                            }
                            .buttonStyle(.plain)
                            .frame(width: 28, height: 24)
                            .padding(.top, 8)
                            Spacer()
                        }
                        .frame(width: 38)
                        .background(.ultraThinMaterial)
                    }
                    Divider().overlay(Theme.hairline)
                        .ignoresSafeArea(.container, edges: .top)
                    // Match the divider: pull the content's top toolbar up to the window top so it
                    // doesn't float below the hidden-title-bar safe-area band (the empty strip above
                    // every header) — but ONLY when the sidebar is shown. Collapsed, the strip is too
                    // narrow for the traffic lights, so the toolbar must stay below the band to clear them.
                    detail
                        .ignoresSafeArea(.container, edges: state.sidebarShown ? .top : [])
                }
                .animation(.easeOut(duration: 0.18), value: state.sidebarShown)
                if state.openedItem != nil {
                    ViewerView(state: state)   // full-window overlay
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let ctx = state.peekContext {
            PeekView(context: ctx) { state.endQuickView() }
        } else if let device = state.openedDevice {
            ImportView(state: state, device: device)
        } else {
            switch state.selection {
            case .timeline: TimelineView(state: state)
            case .folders: FoldersView(state: state)
            case .drives: DrivesView(state: state)
            case .bin: BinView(state: state)
            }
        }
    }
}
