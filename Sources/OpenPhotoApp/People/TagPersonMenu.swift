import SwiftUI
import OpenPhotoCore

/// "Tag person…" menu for one or more photos: pick an existing person or create a new one to MANUALLY
/// tag them as present — no detected face required (for obscured faces). The tag is view-only: it
/// shows the photo in the person's grid but never informs face matching/clustering. Used by the
/// timeline + folder selection bars and the inspector.
struct TagPersonMenu: View {
    @Bindable var state: AppState
    let hashes: [String]
    var label: String = "Tag person\u{2026}"
    var onDone: () -> Void = {}

    @State private var newName = ""
    @State private var showNew = false

    var body: some View {
        Menu {
            if state.people.isEmpty {
                Text("No people yet")
            } else {
                ForEach(state.people, id: \.id) { p in
                    Button(p.name) { state.tagPerson(p.id, inPhotos: hashes); onDone() }
                }
            }
            Divider()
            Button("New Person\u{2026}") { newName = ""; showNew = true }
        } label: {
            Label(label, systemImage: "person.crop.circle.badge.plus")
        }
        .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
        .disabled(hashes.isEmpty)
        .alert("Tag a new person", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Tag") { state.tagNewPerson(named: newName, inPhotos: hashes); onDone() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Adds \(hashes.count) photo\(hashes.count == 1 ? "" : "s") to this person for viewing, even with no detected face. It won't affect face matching.")
        }
    }
}
