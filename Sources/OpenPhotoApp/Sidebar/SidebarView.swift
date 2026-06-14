import SwiftUI
import OpenPhotoCore

struct SidebarView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Button {
                    state.sidebarShown = false
                } label: {
                    Image(systemName: "sidebar.left")
                        .foregroundStyle(Theme.textDim)
                }
                .buttonStyle(.plain)
                .frame(width: 28, height: 24)
                .padding(.trailing, 8)
            }
            .padding(.top, 8)
            Text("LIBRARY")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.44)
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
            ForEach(SidebarItem.allCases, id: \.self) { item in
                let active = state.selection == item && state.openedDevice == nil
                Button {
                    state.selection = item
                    state.openedDevice = nil
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol).frame(width: 18)
                        Text(item.label).font(.system(size: 13.5, weight: .medium))
                        Spacer()
                        if item == .bin, !state.binEntries.isEmpty {
                            Text("\(state.binEntries.count)")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Theme.textFaint)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(active ? Theme.accentDim : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(active ? Theme.accent : Theme.text)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }
            Text("IMPORT")
                .font(.system(size: 11, weight: .semibold)).kerning(0.44)
                .foregroundStyle(Theme.textFaint)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
            ForEach(state.deviceWatcher.devices) { device in
                let active = state.openedDevice?.id == device.id
                let button = Button { state.openedDevice = device } label: {
                    HStack(spacing: 9) {
                        Image(systemName: device.symbol).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name).font(.system(size: 13.5, weight: .medium))
                                .lineLimit(1).truncationMode(.middle)
                            Text(device.recognizedKind)
                                .font(.system(size: 10)).foregroundStyle(Theme.textDim)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .background(active ? Theme.accentDim : .clear,
                                in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(active ? Theme.accent : Theme.text)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                // Folder sources (added via "Add import source…") can be removed here;
                // phones/SD cards are removed by unplugging.
                if device.id.hasPrefix("vol-manual-") || device.id.hasPrefix("takeout-manual-") {
                    button.contextMenu {
                        Button(role: .destructive) { state.removeImportSource(device) } label: {
                            Label("Remove import source", systemImage: "minus.circle")
                        }
                    }
                } else {
                    button
                }
            }
            Button { state.addImportSourceViaPanel() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "plus.circle").frame(width: 18)
                    Text("Add import source…").font(.system(size: 13.5, weight: .medium))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .contentShape(Rectangle())
                .foregroundStyle(Theme.textDim)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            if state.deviceWatcher.devices.isEmpty {
                Text("Plug in a phone or SD card, or add a folder.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 18).padding(.top, 2)
            }
            Spacer()
            if let p = state.scanProgress {
                ActivityIndicatorView(progress: p)
            }
            if let d = state.derivationProgress, d.done < d.total {
                Text("Analyzing \(d.done)/\(d.total)\u{2026}")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 18).padding(.bottom, 4)
            }
        }
        .frame(width: Theme.sidebarWidth)
        .background(.ultraThinMaterial)
        // Pull the sidebar content up under the traffic lights (no empty band above LIBRARY): the
        // collapse button lands in line with the lights, LIBRARY just below them.
        .ignoresSafeArea(.container, edges: .top)
    }
}

struct ActivityIndicatorView: View {
    let progress: Scanner.Progress
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text("Indexing library").font(.system(size: 12, weight: .medium))
            }
            if progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .tint(Theme.accent)
                Text("\(progress.done) of \(progress.total) · \(progress.stage.rawValue)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .padding(12)
        .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
    }
}
