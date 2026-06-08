import SwiftUI
import OpenPhotoCore

/// Runs a send of `items` to `device` and shows progress + a result summary.
struct SendSheet: View {
    @Bindable var state: AppState
    let items: [TimelineItem]
    let device: ConnectedDevice
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var progress: SendProgress?
    @State private var result: SendEngine.Result?
    @State private var running = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Send \(items.count) to \(device.name)")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Close") { dismiss(); onDone() }.disabled(running)
            }
            .padding(16)
            Divider().overlay(Theme.hairline)

            Group {
                if let result {
                    resultView(result)
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
        .frame(width: 520, height: 320)
        .task { await run() }
    }

    private func resultView(_ r: SendEngine.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(r.confirmed.count) sent & verified to \(device.name)",
                  systemImage: "checkmark.seal").foregroundStyle(Theme.green)
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

    private func run() async {
        guard !running, result == nil else { return }
        running = true
        let r = await state.send(items, to: device) { p in
            Task { @MainActor in progress = p }
        }
        result = r ?? SendEngine.Result()
        running = false
    }
}
