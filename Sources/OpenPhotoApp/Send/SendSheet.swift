import SwiftUI
import OpenPhotoCore

/// Resolves `items` into reachable / unreachable, warns about the unreachable ones (grouped by the
/// drive to connect), then runs a send of the reachable ones to `device` and shows the result.
struct SendSheet: View {
    @Bindable var state: AppState
    let items: [TimelineItem]
    let device: ConnectedDevice
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var plan: SendSourcePlan?
    @State private var progress: SendProgress?
    @State private var result: SendEngine.Result?
    @State private var running = false
    @State private var sending = false   // user dismissed the warning and started the send
    @State private var sendFailed = false   // state.send returned nil — couldn't start (device not ready)

    /// Title count: what's actually about to be sent. Before the plan loads, or when nothing is
    /// reachable, fall back to the full selection so the header never reads "Send 0".
    private var titleCount: Int {
        guard let plan else { return items.count }
        return plan.sendable.isEmpty ? items.count : plan.sendable.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Send \(titleCount) to \(device.name)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Close") { dismiss(); onDone() }.disabled(running)
            }
            .padding(16)
            Divider().overlay(Theme.hairline)

            Group {
                if sendFailed {
                    failedToStartView
                } else if let result {
                    resultView(result)
                } else if let plan, !plan.unreachable.isEmpty, !sending {
                    warningView(plan)
                } else if let p = progress {
                    VStack(spacing: 10) {
                        ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                            .tint(Theme.accent)
                        Text("\(p.stage == .verifying ? "Verifying" : "Copying")… \(p.done)/\(p.total) · \(p.currentName)")
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textDim)
                    }.padding(24)
                } else {
                    ProgressView().padding(24)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: 520, height: 360)
        .task { await prepareThenMaybeSend() }
    }

    /// Photos that can't be sent, grouped by the drive the user must connect.
    private func warningView(_ plan: SendSourcePlan) -> some View {
        let groups = Dictionary(grouping: plan.unreachable, by: \.driveName)
            .sorted { $0.key < $1.key }
        return VStack(alignment: .leading, spacing: 14) {
            Label("\(plan.unreachable.count) photo\(plan.unreachable.count == 1 ? "" : "s") can't be sent right now — "
                  + "their drive\(groups.count == 1 ? " isn't" : "s aren't") connected.",
                  systemImage: "externaldrive.badge.xmark")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.amber)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups, id: \.key) { driveName, entries in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("On \(driveName) — connect it to include these")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textDim)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 5) {
                                    ForEach(thumbItems(for: entries), id: \.instanceID) { item in
                                        ThumbView(item: item, library: state.library!)
                                            .frame(width: 44, height: 44)
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button("Cancel") { dismiss(); onDone() }
                Spacer()
                Button("Send \(plan.sendable.count)") { sending = true; Task { await run(plan.sendable) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(plan.sendable.isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
    }

    /// Map unreachable hashes back to their TimelineItems (the sheet holds the original selection),
    /// so cached thumbnails render even with the drive unplugged.
    private func thumbItems(for entries: [UnreachableSendItem]) -> [TimelineItem] {
        let wanted = Set(entries.map(\.hash))
        return items.filter { wanted.contains($0.hash) }
    }

    private func resultView(_ r: SendEngine.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if r.confirmed.count > 0 {
                Label("\(r.confirmed.count) sent & verified to \(device.name)",
                      systemImage: "checkmark.seal").foregroundStyle(Theme.green)
            } else {
                Label("Nothing new sent to \(device.name)", systemImage: "tray")
                    .foregroundStyle(Theme.textDim)
            }
            if !r.alreadyPresent.isEmpty {
                Text("\(r.alreadyPresent.count) already on \(device.name) — skipped")
                    .foregroundStyle(Theme.textDim)
            }
            if !r.unconfirmed.isEmpty {
                Text("\(r.unconfirmed.count) not confirmed").foregroundStyle(Theme.amber)
            }
            if !r.failed.isEmpty {
                Text("\(r.failed.count) failed").foregroundStyle(Theme.amber)
                ForEach(r.failed, id: \.item.hash) { o in
                    Text("• \(o.item.displayName): \(o.error ?? "")")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.amber)
                }
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
    }

    /// `state.send` returned nil — the send couldn't even start (e.g. the device just connected,
    /// is locked, or its session isn't ready). Distinct from a completed send that had nothing new,
    /// so a transient hiccup reads as actionable (Try Again) rather than a silent "nothing sent".
    private var failedToStartView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Couldn't start the send to \(device.name)", systemImage: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.amber)
            Text("\(device.name) may not be ready — just connected, locked, or busy. "
                 + "Make sure it's unlocked and connected, then try again.")
                .font(.system(size: 12)).foregroundStyle(Theme.textDim)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Try Again") { sendFailed = false; Task { await run(plan?.sendable ?? []) } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(24)
    }

    /// Compute the plan once. If nothing is unreachable, send immediately (today's flow);
    /// otherwise wait — `warningView` drives the send when the user confirms.
    private func prepareThenMaybeSend() async {
        guard plan == nil else { return }
        let p = state.sendPlan(for: items)
        plan = p
        if p.unreachable.isEmpty {
            sending = true
            await run(p.sendable)
        }
    }

    private func run(_ sendItems: [SendItem]) async {
        guard !running, result == nil else { return }
        running = true
        sendFailed = false
        progress = nil
        let r = await state.send(sendItems, to: device) { p in
            Task { @MainActor in progress = p }
        }
        // nil = the send couldn't start (a precondition/device-session failure) → surface it as an
        // actionable error; a non-nil empty Result is a real "nothing new to send".
        if let r { result = r } else { sendFailed = true }
        running = false
    }
}
