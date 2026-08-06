import SwiftUI
import AppKit
import OpenPhotoCore

/// Puts photos on the system clipboard: full-resolution pixels for photos, file references for
/// videos (and for sets too large to decode safely — see `ClipboardCopyPlan`).
@MainActor
enum ImageClipboard {
    /// Runs `plan`. URLs and rotations resolve on the main actor (catalog reads); the decode runs
    /// off-main so a big RAW never freezes the UI. The pasteboard is cleared only once there is
    /// something to write — a failed decode leaves whatever you had copied before intact.
    static func copy(_ plan: ClipboardCopyPlan, state: AppState) {
        guard !plan.isEmpty else { return }
        let photos: [(url: URL, rotation: Int)] = plan.images.compactMap { item in
            guard let url = state.fullResURL(for: item) else { return nil }
            return (url, state.displayRotation(for: item))
        }
        let fileURLs = plan.files.compactMap { state.fullResURL(for: $0) }
        guard !photos.isEmpty || !fileURLs.isEmpty else { return }

        Task {
            // One decode at a time inside an autorelease pool: full-res bitmaps are large, and
            // ImageIO's temporaries must not accumulate across the batch (the count/byte caps in
            // ClipboardCopyPlan bound the peak).
            let decoded = await Task.detached(priority: .userInitiated) { () -> [CGImage] in
                photos.compactMap { photo in
                    autoreleasepool {
                        FullResImage.decode(url: photo.url, extraRotationCW: photo.rotation)
                    }
                }
            }.value

            var objects: [NSPasteboardWriting] = decoded.map {
                NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
            }
            objects.append(contentsOf: fileURLs.map { $0 as NSURL })
            guard !objects.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(objects)
        }
    }

    /// Writes one already-decoded full-res image — the viewer's path, where the photo on screen IS
    /// the full-res decode, so copying is instant and never re-reads the file.
    static func copyDecoded(_ image: CGImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image,
                                         size: NSSize(width: image.width, height: image.height))])
    }

    /// Whether anything in `items` can actually be read right now. Deliberately cheap: local items
    /// always resolve, so only an all-drive-only set pays for a lookup (and then just for the first
    /// item) — this runs while a context menu is being built, potentially over a big selection.
    static func canCopy(_ items: [TimelineItem], state: AppState) -> Bool {
        guard !items.isEmpty else { return false }
        if items.contains(where: { !state.isDriveOnly($0) }) { return true }
        return state.fullResURL(for: items[0]) != nil
    }
}

/// The "Copy…" item for a tile's context menu. The title states the exact outcome ("Copy Image",
/// "Copy 30 Files"), so a set too large for pixels never silently copies something else.
struct CopyMenuButton: View {
    let state: AppState
    let items: [TimelineItem]

    var body: some View {
        let plan = ClipboardCopyPlan.make(for: items)
        Button(plan.title, systemImage: "doc.on.doc") {
            ImageClipboard.copy(plan, state: state)
        }
        .disabled(!ImageClipboard.canCopy(items, state: state))
    }
}

extension View {
    /// Right-click → Copy for a grid tile that has no context menu of its own.
    func copyContextMenu(state: AppState, items: [TimelineItem]) -> some View {
        contextMenu { CopyMenuButton(state: state, items: items) }
    }

    /// Publishes this grid's selection as the ⌘C target while it's on screen. `owner` guards the
    /// clear: a grid that disappears AFTER its replacement appeared can't wipe the new one's targets.
    func copyTargets(_ items: @autoclosure @escaping () -> [TimelineItem],
                     owner: String, state: AppState, changeKey: some Equatable) -> some View {
        onAppear { state.publishCopyTargets(items(), owner: owner) }
            .onChange(of: changeKey) { state.publishCopyTargets(items(), owner: owner) }
            .onDisappear { state.clearCopyTargets(owner: owner) }
    }
}

/// Change key for `copyTargets(_:owner:state:changeKey:)` — republishes whenever a grid's selection
/// or select mode changes.
struct SelectionKey: Equatable {
    let selectMode: Bool
    let selected: Set<String>
}

/// The window-wide ⌘C. Invisible, but its key equivalent is registered for the whole window, so it
/// fires from any grid or the viewer without those surfaces needing keyboard focus.
struct CopyKeyCommand: View {
    let state: AppState

    var body: some View {
        Button("Copy") { state.copyCurrent() }
            .keyboardShortcut("c", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

extension AppState {
    /// The photo(s) ⌘C acts on in a grid — published by whichever grid is on screen (empty when
    /// nothing is selected). The open viewer takes precedence over this; see `copyCurrent()`.
    var copyTargetItems: [TimelineItem] { copyTargetsStorage }

    func publishCopyTargets(_ items: [TimelineItem], owner: String) {
        copyTargetsStorage = items
        copyTargetsOwner = owner
    }

    func clearCopyTargets(owner: String) {
        guard copyTargetsOwner == owner else { return }   // a newer surface already took over
        copyTargetsStorage = []
        copyTargetsOwner = nil
    }

    /// The display rotation to bake into copied pixels, read from the catalog (the source of truth —
    /// a `TimelineItem` handed over by a grid can predate a rotate).
    func displayRotation(for item: TimelineItem) -> Int {
        (try? library?.catalog.rotation(forHash: item.hash)) ?? item.rotation
    }

    /// ⌘C: copy the open photo, or the current grid selection. While a text field is being edited,
    /// hand the key back to the standard Copy so text selection still copies.
    func copyCurrent() {
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSText {
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            return
        }
        if let item = openedItem {
            // The viewer already holds this photo decoded at full res — reuse it rather than paying
            // for a second decode of a file that can be hundreds of megabytes.
            let key = "\(item.instanceID)|\(displayRotation(for: item))" as NSString
            if let cached = viewerImageCache.object(forKey: key)?.image {
                ImageClipboard.copyDecoded(cached)
                return
            }
        }
        let items = openedItem.map { [$0] } ?? copyTargetItems
        ImageClipboard.copy(ClipboardCopyPlan.make(for: items), state: self)
    }
}
