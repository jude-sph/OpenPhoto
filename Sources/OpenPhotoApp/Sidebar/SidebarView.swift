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
            if !state.lockedFolders.isEmpty {
                Button {
                    if state.lockedRevealed {
                        state.relock()
                    } else {
                        Task { _ = await state.revealLockedContent() }
                    }
                } label: {
                    Label(
                        state.lockedRevealed ? "Lock now" : "Show hidden folders",
                        systemImage: state.lockedRevealed ? "lock.open.fill" : "lock.fill"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let p = state.scanProgress {
                ActivityIndicatorView(progress: p)
            }
            if let d = state.derivationProgress, d.done < d.total {
                let pct = Int(Double(d.done) / Double(max(d.total, 1)) * 100)
                Text(state.derivationStageName.map { "Analyzing \($0)\u{2026} \(pct)%" } ?? "Analyzing\u{2026} \(pct)%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textFaint)
                    .padding(.horizontal, 18).padding(.bottom, 4)
                    .help("\(d.done) of \(d.total) on-device analysis tasks (several per photo)")
            }
            if let a = state.activeJob {
                let syncResult: SyncResult? = { if case .sync(let r) = a.result { return r }; return nil }()
                let hasFailures = jobHasFailures(a)
                Button {
                    if let d = state.jobDrive { state.jobSheetDrive = d }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: jobSymbol(a))
                            Text(jobLabel(a, syncResult: syncResult))
                                .font(.system(size: 11, weight: .medium))
                        }.foregroundStyle(hasFailures ? Theme.amber : Theme.textDim)
                        if a.phase == .running {
                            ProgressView(value: Double(a.bytesDone), total: Double(max(a.bytesTotal, 1))).tint(Theme.accent)
                            Text("\(byteString(a.bytesDone)) / \(byteString(a.bytesTotal)) · \(speedString(a.speedBytesPerSec))")
                                .font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textFaint)
                        } else if hasFailures {
                            Text("\(jobFailureCount(a)) failed — tap to review")
                                .font(.system(size: 10)).foregroundStyle(Theme.amber)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Theme.bg2, in: RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 10).padding(.bottom, 6)
            }
        }
        .frame(width: Theme.sidebarWidth)
        .background(.ultraThinMaterial)
        // Pull the sidebar content up under the traffic lights (no empty band above LIBRARY): the
        // collapse button lands in line with the lights, LIBRARY just below them.
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: - Active-job chip helpers (label/icon/badge vary by job kind)

    /// SF Symbol for the chip. Running jobs keep the spinning-arrows glyph; finished jobs vary by kind
    /// (sync settles on the drive glyph, evict/rehydrate show their direction).
    private func jobSymbol(_ a: DriveJob) -> String {
        if a.phase == .running { return "arrow.triangle.2.circlepath" }
        switch a.kind {
        case .sync: return "externaldrive.fill"
        case .evict: return "arrow.down.circle"
        case .rehydrate: return "arrow.down.circle.dotted"
        }
    }

    /// Chip title varies by kind (and, for sync, by whether it finished clean).
    private func jobLabel(_ a: DriveJob, syncResult: SyncResult?) -> String {
        if a.phase == .running {
            switch a.kind {
            case .sync: return "Syncing"
            case .evict: return "Freeing space"
            case .rehydrate: return "Downloading"
            }
        }
        switch a.kind {
        case .sync: return syncResult?.failed.isEmpty == false ? "Sync finished" : "Synced"
        case .evict: return "Freed space"
        case .rehydrate: return "Downloaded"
        }
    }

    /// Whether the (finished) job carries failures worth an amber alarm badge. Evict refusals are
    /// kept-safe by design, so they don't count.
    private func jobHasFailures(_ a: DriveJob) -> Bool {
        switch a.result {
        case .sync(let r): return !r.failed.isEmpty
        case .rehydrate(_, let failed): return !failed.isEmpty
        case .evict, .none: return false
        }
    }

    private func jobFailureCount(_ a: DriveJob) -> Int {
        switch a.result {
        case .sync(let r): return r.failed.count
        case .rehydrate(_, let failed): return failed.count
        case .evict, .none: return 0
        }
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
