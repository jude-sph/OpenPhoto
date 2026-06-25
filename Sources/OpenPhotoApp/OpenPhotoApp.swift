import SwiftUI
import OpenPhotoCore
import Sparkle

@main
struct OpenPhotoApp: App {
    @State private var state = AppState()

    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        WindowGroup("OpenPhoto") {
            RootView(state: state)
                .frame(minWidth: 1100, minHeight: 700)
                .background(Theme.windowBG)
                .tint(Theme.accent)
                .task {
                    guard let root = state.configuredRoot else { return }   // → Welcome
                    if FileManager.default.fileExists(atPath: root.path) {
                        state.openLibrary(roots: [root])
                    }
                    // If the saved folder is missing (moved/unplugged), fall through to Welcome
                    // without forgetting it — it may reappear; the user can re-open via Welcome.
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updaterController.checkForUpdates(nil) }
            }
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
                Button("Export Metadata Sidecars\u{2026}") {
                    MainActor.assumeIsolated { state.exportSidecars() }
                }
                Divider()
                Button("Library…") {
                    MainActor.assumeIsolated {
                        _ = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    }
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        Settings { SettingsView(state: state) }
    }
}

struct RootView: View {
    @Bindable var state: AppState
    @Environment(\.undoManager) private var undoManager

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
                            // Below the vertically-stacked traffic lights, which occupy the strip's top.
                            .padding(.top, 48)
                            Spacer()
                        }
                        .frame(width: 38)
                        .background(.ultraThinMaterial)
                    }
                    Divider().overlay(Theme.hairline)
                        .ignoresSafeArea(.container, edges: .top)
                    // Match the divider: pull the content's top toolbar up to the window top so it
                    // doesn't float below the hidden-title-bar safe-area band (the empty strip above
                    // every header). Safe in both sidebar states — the traffic lights are kept out of
                    // the content (horizontal over the wide sidebar; vertical inside the 38px strip).
                    detail
                        .ignoresSafeArea(.container, edges: .top)
                }
                .animation(.easeOut(duration: 0.18), value: state.sidebarShown)
                if state.openedItem != nil {
                    ViewerView(state: state)   // full-window overlay
                }
            }
            // Stack the traffic lights vertically when the sidebar is collapsed so they fit the
            // narrow 38px strip; keep them horizontal when it's shown OR when the full-window viewer
            // is open (no strip there — the lights sit over the viewer's top bar).
            .background(VerticalTrafficLights(vertical: !state.sidebarShown && state.openedItem == nil))
            .background(TitleBarDoubleClickZoom())
            .overlay(alignment: .top) { MLUnavailableBanner(state: state) }
            .animation(.easeOut(duration: 0.2), value: state.mlUnavailable.count)
            // Hand the window's native UndoManager to AppState (⌘Z registrations — see
            // AppState+Undo.swift). The Bool task id re-fires when nil-ness flips, which is
            // the only transition that matters (the manager instance is stable per window).
            .task(id: undoManager == nil) { state.windowUndoManager = undoManager }
            // Present the sync sheet at the app root so it's reopenable from anywhere (the sidebar
            // sync chip lives outside DrivesView). Driven by AppState so background sync survives
            // navigating away from Drives.
            .sheet(item: $state.jobSheetDrive) { drive in DriveJobSheet(state: state, drive: drive) }
            // Present the reconnect review at the app root too, so plugging a drive in surfaces it from
            // ANY screen — the mount handler sets `reviewDrive` regardless of which view is showing.
            .sheet(item: $state.reviewDrive) { p in ReviewChangesSheet(state: state, drive: p.drive) }
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
            case .albums: AlbumsView(state: state)
            case .people: PeopleView(state: state)
            case .faceMap: FaceMapView(state: state)
            case .map: MapView(state: state)
            case .search: SearchView(state: state)
            case .drives: DrivesView(state: state)
            case .tidyUp: CleanupView(state: state)
            case .bin: BinView(state: state)
            }
        }
    }
}
