import SwiftUI
import OpenPhotoCore

/// The library folder tree as a picker. `travelsFolder` mode adds the auto-discover toggle and tags
/// the current Travels folder; `newTrip`/`addFolder` grey out folders already covered by a trip.
struct FolderPickerSheet: View {
    enum Mode { case travelsFolder, newTrip, addFolder(exclude: [String]) }
    @Bindable var state: AppState
    let mode: Mode
    let onPick: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    @State private var auto = true
    @State private var expanded: Set<String> = []

    /// One visible line of the tree: the node, its indent, and the photo count of its whole subtree
    /// (a trip always takes the subtree, so the count has to match what the trip will show).
    private struct TreeRow: Identifiable {
        let node: FolderNode
        let depth: Int
        let total: Int
        var id: String { node.path }
    }

    private var title: String {
        switch mode {
        case .travelsFolder: "Travels folder"
        case .newTrip: "New trip"
        case .addFolder: "Add a folder to this trip"
        }
    }

    private var hint: String {
        switch mode {
        case .travelsFolder: "Every folder directly inside it becomes a trip. New trip folders appear on their own; trips you removed stay removed."
        case .newTrip: "Choose the folder that holds the trip. Subfolders are included."
        case .addFolder: "Its subfolders come along. Folders already in the trip are greyed out."
        }
    }

    private var confirmLabel: String { if case .travelsFolder = mode { "Use folder" } else { "Add" } }

    /// Greyed out: a folder that overlaps an existing trip (new trip), or one this trip already
    /// covers. Both tests look in BOTH directions — an ancestor of a trip's folder would make two
    /// trips share photos just as surely as a descendant does.
    private func disabled(_ path: String) -> Bool {
        func overlaps(_ folders: [String]) -> Bool {
            folders.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
        }
        switch mode {
        case .travelsFolder: return false
        case .newTrip: return state.travels.contains { overlaps($0.folders) }
        case .addFolder(let ex): return overlaps(ex)
        }
    }

    /// Flattened so the list stays a plain `ForEach` (a recursive `@ViewBuilder` row can't name its
    /// own opaque type) and every row is one `LazyVStack` child.
    private var rows: [TreeRow] {
        func total(_ n: FolderNode) -> Int { n.count + n.children.reduce(0) { $0 + total($1) } }
        var out: [TreeRow] = []
        func walk(_ n: FolderNode, _ depth: Int) {
            out.append(TreeRow(node: n, depth: depth, total: total(n)))
            if expanded.contains(n.path) { for c in n.children { walk(c, depth + 1) } }
        }
        for n in state.folderTree { walk(n, 0) }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(hint).font(.system(size: 12)).foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            Divider().overlay(Theme.hairline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) { ForEach(rows) { row($0) } }.padding(8)
            }
            Divider().overlay(Theme.hairline)
            HStack {
                if case .travelsFolder = mode { Toggle("Add its subfolders as trips automatically", isOn: $auto) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(confirmLabel) { if let s = selected { onPick(s, auto); dismiss() } }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(selected == nil)
            }
            .controlSize(.small).padding(12)
        }
        .frame(width: 520, height: 520)
        .onAppear {
            if case .travelsFolder = mode {
                selected = state.travelSettings.travelsFolder
                auto = state.travelSettings.autoDiscover
            }
            expanded = Set(state.folderTree.map(\.path))
            // Reveal the Travels folder: every ancestor has to be open for its row to exist.
            var p = state.travelSettings.travelsFolder ?? ""
            while !p.isEmpty {
                expanded.insert(p)
                p = (p as NSString).deletingLastPathComponent
            }
        }
    }

    private func row(_ r: TreeRow) -> some View {
        let node = r.node
        let dis = disabled(node.path), sel = selected == node.path, open = expanded.contains(node.path)
        return HStack(spacing: 6) {
            Button {
                if open { expanded.remove(node.path) } else { expanded.insert(node.path) }
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(Theme.textFaint).frame(width: 14)
                    .opacity(node.children.isEmpty ? 0 : 1)
            }
            .buttonStyle(.plain).disabled(node.children.isEmpty)
            Image(systemName: "folder").foregroundStyle(Theme.textDim)
            Text(node.name).lineLimit(1)
            if state.travelSettings.travelsFolder == node.path {
                Text("Travels").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.accentDim, in: Capsule())
            }
            Spacer()
            Text(r.total.formatted()).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textFaint)
        }
        .padding(.vertical, 5).padding(.leading, CGFloat(6 + r.depth * 16)).padding(.trailing, 8)
        .background(sel ? Theme.accentDim : .clear, in: RoundedRectangle(cornerRadius: 5))
        .opacity(dis ? 0.45 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if !dis { selected = node.path } }
        // Simultaneous (not a second `onTapGesture`): the single tap still selects, and the second
        // click confirms — SwiftUI won't hand a plain count-2 tap the clicks the count-1 one took.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if !dis { selected = node.path; onPick(node.path, auto); dismiss() }
        })
    }
}
