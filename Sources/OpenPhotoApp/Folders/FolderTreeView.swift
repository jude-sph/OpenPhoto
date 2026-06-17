import SwiftUI
import OpenPhotoCore

struct FolderTreeView: View {
    @Bindable var state: AppState

    @State private var showNewRootFolder = false
    @State private var newRootFolderName = ""
    @State private var rootDropTargeted = false
    @State private var scrollViewportH: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VideosOnlyBanner(state: state)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(state.folderTree) { node in
                        FolderRow(node: node, state: state, depth: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(8)
                // Fill the viewport so the empty area below the last folder is itself a drop target
                // for un-nesting. Drops landing on a folder row are handled by that row (nest); drops
                // in the empty space fall through to here → move to the library root.
                .frame(minHeight: scrollViewportH, alignment: .top)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    moveToRoot(items.first)
                } isTargeted: { rootDropTargeted = $0 }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scrollViewportH = $0 }
        }
        .background(Theme.bg2.opacity(0.5))
        .alert("New Folder", isPresented: $showNewRootFolder) {
            TextField("Folder name", text: $newRootFolderName)
            Button("Create") {
                let trimmed = newRootFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    Task { await state.createFolder(named: trimmed, under: nil) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new folder at the library root.")
        }
    }

    // Pinned header. The leading area (title + spacer) doubles as the drop target for un-nesting:
    // drag a folder there to move it to the top level (library root). Kept outside the scroll view so
    // it stays reachable in a long tree.
    //
    // The header MUST be `Theme.toolbarHeight` tall (like every other top toolbar). The window is
    // `.hiddenTitleBar` and `detail` ignores the top safe area, so this header is pulled flush to the
    // window top — and the top ~28pt is AppKit's title-bar drag band (it intercepts mouse-down for
    // window drag/zoom). A compact header put the "+" button entirely inside that band, so clicks were
    // eaten (double-clicks zoomed the window). At toolbar height the button centers at ~26pt, its hit
    // area extends below the band, and AppKit hit-tests it to the control — exactly like the working
    // toolbars on the other views. (The "+" is also a SEPARATE trailing sibling of the drop zone, never
    // overlapping it, so the un-nest `.dropDestination` can't eat the click either.)
    private var header: some View {
        HStack(spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.to.line")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .opacity(rootDropTargeted ? 1 : 0)    // reserve width so the title doesn't shift
                Text(rootDropTargeted ? "Move to top level" : "Folders")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(rootDropTargeted ? Theme.accent : Theme.textFaint)
                    .textCase(.uppercase)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)              // fill the bar so the drop zone is full-height
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                moveToRoot(items.first)
            } isTargeted: { rootDropTargeted = $0 }

            Button {
                newRootFolderName = ""
                showNewRootFolder = true
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 30, height: 30)         // generous hit target, centered in the bar so
                    .contentShape(Rectangle())            // it clears the title-bar drag band
            }
            .buttonStyle(.plain)
            .help("New Folder at library root")
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.toolbarHeight)
        .background(rootDropTargeted ? Theme.accent.opacity(0.16) : .clear)
        .overlay(alignment: .bottom) { Divider().overlay(Theme.hairline) }
    }

    /// Header + empty-space drops: photos move to the library root; a dragged folder
    /// un-nests to the root (rejected if it's already there).
    private func moveToRoot(_ payload: String?) -> Bool {
        guard let payload, !payload.isEmpty else { return false }
        if let ids = PhotoMovePayload.decode(payload) {
            guard !ids.isEmpty else { return false }
            Task { await state.movePhotos(ids: ids, into: "") }
            return true
        }
        guard !(payload as NSString).deletingLastPathComponent.isEmpty else { return false }
        Task { await state.moveFolder(from: payload, into: "") }
        return true
    }
}

private struct FolderRow: View {
    let node: FolderNode
    @Bindable var state: AppState
    let depth: Int

    @State private var dropTargeted = false
    @State private var showNewChildFolder = false
    @State private var newChildFolderName = ""
    @State private var showDeleteConfirm = false
    @State private var showTagAll = false
    @State private var tagAllName = ""
    @State private var showUntagAll = false
    @State private var untagName = ""
    @State private var showRename = false
    @State private var renameText = ""

    private var expanded: Bool { state.expandedFolders.contains(node.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if node.children.isEmpty {
                    Spacer().frame(width: 22)             // match the disclosure button's width so
                } else {                                  // leaf rows stay aligned with parent rows
                    Button {
                        state.expandedFolders.formSymmetricDifference([node.path])
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textFaint)
                            .frame(width: 22, height: 22)  // small glyph, generous click target
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(state.selectedFolder == node.path ? Theme.accent : Theme.textDim)
                Text(node.name).font(.system(size: 13))
                if state.isFolderLocked(node.path) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.textFaint)
                }
                Spacer()
                if node.count > 0 {
                    Text("\(node.count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .padding(.leading, CGFloat(depth) * 14)
            .background(
                dropTargeted ? Theme.accent.opacity(0.22) :
                    (state.selectedFolder == node.path ? Theme.accentDim : .clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                dropTargeted ?
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.accent.opacity(0.7), lineWidth: 1.5)
                        .padding(.leading, CGFloat(depth) * 14)
                    : nil
            )
            .contentShape(Rectangle())
            .onTapGesture {
                state.selectedFolder = node.path
                if state.isFolderLocked(node.path) && !state.lockedRevealed {
                    Task { _ = await state.revealLockedContent() }
                }
            }
            .draggable(node.path)
            .dropDestination(for: String.self) { items, _ in
                guard let payload = items.first else { return false }
                if let ids = PhotoMovePayload.decode(payload) {
                    guard !ids.isEmpty else { return false }
                    Task { await state.movePhotos(ids: ids, into: node.path) }
                    return true
                }
                guard payload != node.path,
                      !payload.isEmpty,
                      !node.path.hasPrefix(payload + "/") else { return false }
                Task { await state.moveFolder(from: payload, into: node.path) }
                return true
            } isTargeted: { targeted in
                dropTargeted = targeted
            }
            .contextMenu {
                Button("New Folder Inside\u{2026}") {
                    newChildFolderName = ""
                    showNewChildFolder = true
                }
                if !node.path.isEmpty {
                    Button("Rename Folder\u{2026}", systemImage: "pencil") {
                        renameText = node.name; showRename = true
                    }
                }
                Divider()
                if state.isFolderLocked(node.path) {
                    Button("Unlock", systemImage: "lock.open") {
                        state.unlockFolder(node.path)
                    }
                } else {
                    Button("Lock (Touch ID)", systemImage: "lock") {
                        state.lockFolder(node.path)
                    }
                }
                Divider()
                Button("Tag All in Folder\u{2026}", systemImage: "tag") {
                    tagAllName = ""; showTagAll = true
                }
                Button("Remove Tag from Folder\u{2026}", systemImage: "tag.slash") {
                    untagName = ""; showUntagAll = true
                }
                Divider()
                Button("Delete Folder\u{2026}", role: .destructive) {
                    showDeleteConfirm = true
                }
            }
            if expanded {
                ForEach(node.children) { child in
                    FolderRow(node: child, state: state, depth: depth + 1)
                }
            }
        }
        // "New Folder Inside…" prompt
        .alert("New Folder", isPresented: $showNewChildFolder) {
            TextField("Folder name", text: $newChildFolderName)
            Button("Create") {
                let trimmed = newChildFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    Task { await state.createFolder(named: trimmed, under: node.path) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the new folder inside \u{201C}\(node.name)\u{201D}.")
        }
        // Rename-folder prompt
        .alert("Rename \u{201C}\(node.name)\u{201D}", isPresented: $showRename) {
            TextField("Folder name", text: $renameText)
            Button("Rename") {
                let n = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty, n != node.name { Task { await state.renameFolder(node.path, to: n) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Renames this folder on disk. Your photos and their edits are unaffected.")
        }
        // Tag-all-in-folder prompt
        .alert("Tag all photos in \u{201C}\(node.name)\u{201D}", isPresented: $showTagAll) {
            TextField("Tag", text: $tagAllName)
            Button("Apply") { state.tagAllInFolder(node.path, tag: tagAllName, recursive: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Adds the tag to every photo in this folder and its subfolders. Photos that already have it are skipped.")
        }
        // Remove-tag-from-folder prompt
        .alert("Remove a tag from \u{201C}\(node.name)\u{201D}", isPresented: $showUntagAll) {
            TextField("Tag", text: $untagName)
            Button("Remove") { state.untagAllInFolder(node.path, tag: untagName, recursive: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the tag from every photo in this folder and its subfolders that has it.")
        }
        // Delete confirmation
        .alert("Delete \u{201C}\(node.name)\u{201D}?", isPresented: $showDeleteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await state.deleteFolder(node.path) }
            }
        } message: {
            Text("Photos inside this folder move to the Bin and can be restored from there. The folder is removed from all connected drives.")
        }
    }
}
