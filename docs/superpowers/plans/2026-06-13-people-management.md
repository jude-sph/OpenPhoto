# People Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user see the actual face a person's collection claims (toggle face-crops vs photos), bulk-move a selection to an existing person, and rename a person (with sidecars kept in sync).

**Architecture:** Reuse existing primitives — `FaceCropView` (crops to `FaceRow.rect`), `Catalog.assignFaces`, and the `AppState.writeSidecarRegions(forPersonID:)` paired catalog+sidecar writer. Add one catalog method (`renamePerson`), two AppState methods (`renamePerson`, `moveFaces`), and wire PeopleView UI.

**Tech Stack:** Swift 6, SwiftUI, GRDB, swift-testing.

---

### Task 1: `Catalog.renamePerson`

**Files:**
- Modify: `Sources/OpenPhotoCore/Catalog/Catalog+Faces.swift` (add after `createPerson`)
- Test: `Tests/OpenPhotoCoreTests/FacesCRUDTests.swift` (append)

- [ ] **Step 1: Write the failing test**

```swift
@Test func renamePersonUpdatesNameKeepsFaces() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let cat = try Catalog(at: t.root.appendingPathComponent("c.sqlite"))
    try cat.upsert(assets: [photo(A)])
    let f = try cat.insertFaces([face(A, [1, 0])])
    let p = try cat.createPerson(name: "Bob")
    try cat.assignFaces(f, to: p)
    try cat.renamePerson(p, to: "Robert")
    #expect(try cat.people().first?.name == "Robert")
    #expect(try cat.faces(forPerson: p).count == 1)   // faces untouched
}
```

- [ ] **Step 2: Run, verify it fails** — `swift test --filter renamePersonUpdatesNameKeepsFaces` → FAIL (no `renamePerson`).

- [ ] **Step 3: Implement**

```swift
/// Rename a person. Human metadata — the App pairs this with a sidecar rewrite of the person's
/// confirmed regions (writeSidecarRegions) so the on-disk name stays in sync.
public func renamePerson(_ id: Int64, to name: String) throws {
    try dbQueue.write { db in
        try db.execute(sql: "UPDATE people SET name = ? WHERE id = ?", arguments: [name, id])
    }
}
```

- [ ] **Step 4: Run, verify pass.** `swift test --filter renamePersonUpdatesNameKeepsFaces` → PASS.
- [ ] **Step 5: Commit** — `feat(catalog): renamePerson`.

---

### Task 2: `AppState.renamePerson` + `AppState.moveFaces`

**Files:**
- Modify: `Sources/OpenPhotoApp/AppState.swift` (add in the "People management" section, near `splitFaces`)

No unit test (App target / @MainActor + Task.detached + sidecar I/O) — verified by build + the Task 1 catalog test + manual smoke, consistent with `nameCluster`/`splitFaces`.

- [ ] **Step 1: Add both methods**

```swift
/// Rename a person: update the catalog, then rewrite the person's photos' sidecars so the
/// on-disk MWG region name matches (writeSidecarRegions reads the new name from the catalog).
func renamePerson(_ personID: Int64, to newName: String) {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let lib = library else { return }
    Task.detached(priority: .userInitiated) { [weak self] in
        do {
            try lib.catalog.renamePerson(personID, to: trimmed)
            self?.writeSidecarRegions(forPersonID: personID, lib: lib)
        } catch { NSLog("renamePerson failed: \(error)") }
        await MainActor.run { [weak self] in
            self?.facesDirty = true
            self?.loadPeople()
        }
    }
}

/// Move selected faces to an EXISTING person. Mirrors splitFaces but assigns to a chosen person
/// instead of creating one. Rewrites sidecars for the destination (gains regions) and the source
/// (loses them) — both rewrites pull current catalog state per affected hash, so stale names drop.
func moveFaces(_ faceIDs: [Int64], toPerson personID: Int64, fromPerson old: Int64?) {
    guard !faceIDs.isEmpty, let lib = library else { return }
    Task.detached(priority: .userInitiated) { [weak self] in
        do {
            try lib.catalog.assignFaces(faceIDs, to: personID)
            self?.writeSidecarRegions(forPersonID: personID, lib: lib)
            if let old, old != personID { self?.writeSidecarRegions(forPersonID: old, lib: lib) }
        } catch { NSLog("moveFaces failed: \(error)") }
        await MainActor.run { [weak self] in
            self?.facesDirty = true
            self?.loadPeople()
        }
    }
}
```

- [ ] **Step 2: Build** — `swift build` → Build complete.
- [ ] **Step 3: Commit** — `feat(appstate): renamePerson + moveFaces (paired sidecar writes)`.

---

### Task 3: Faces ↔ Photos toggle in the person detail grid

**Files:**
- Modify: `Sources/OpenPhotoApp/People/PeopleView.swift` — the person detail view + `FacePhotoTile`.

- [ ] **Step 1:** In the person detail view add `@State private var showFaces = true`. In `detailToolbar`, before the `Select` button, add a segmented control bound to `showFaces`:

```swift
Picker("", selection: $showFaces) {
    Text("Faces").tag(true)
    Text("Photos").tag(false)
}
.pickerStyle(.segmented).labelsHidden().fixedSize()
```

- [ ] **Step 2:** Thread `showFace: showFaces` into each `FacePhotoTile(...)` in `grid`.
- [ ] **Step 3:** Add `let showFace: Bool` to `FacePhotoTile`. In its body, render the face crop when `showFace`, else the photo — replacing the current `thumbnail: ThumbnailImage(...)`:

```swift
// in FacePhotoTile body, where the tile image is built:
Group {
    if showFace {
        FaceCropView(state: state, faceID: face.id, item: item, targetPixel: thumbPixels)
    } else {
        ThumbnailImage(timelineItem: item, library: state.library!, targetPixel: thumbPixels)
    }
}
```

(Match `FaceCropView`'s actual initializer signature when editing — confirm against its definition in this file.)

- [ ] **Step 4: Build** — `swift build` → Build complete.
- [ ] **Step 5: Commit** — `feat(people): Faces/Photos toggle in person detail (show the claimed face)`.

---

### Task 4: Bulk "Move to person…" in the selection bar

**Files:**
- Modify: `Sources/OpenPhotoApp/People/PeopleView.swift` — `selectionBar` in the person detail view.

- [ ] **Step 1:** In `selectionBar`, before "Split to new person…", add a Menu of existing people (excluding the current person), then keep Split as the "New person" path:

```swift
Menu("Move to person…") {
    ForEach(allPeople.filter { $0.id != person.id }, id: \.id) { p in
        Button(p.name) {
            state.moveFaces(selectedFaceIDs, toPerson: p.id, fromPerson: person.id)
            selection.clear(); reload()
        }
    }
    if allPeople.filter({ $0.id != person.id }).isEmpty {
        Text("No other people yet").foregroundStyle(.secondary)
    }
}
.controlSize(.small)
.disabled(selection.count == 0)
```

- [ ] **Step 2: Build** → Build complete.
- [ ] **Step 3: Commit** — `feat(people): bulk Move to existing person from the selection bar`.

---

### Task 5: Rename a person (card menu + detail header)

**Files:**
- Modify: `Sources/OpenPhotoApp/People/PeopleView.swift` — person card context menu + detail header.

- [ ] **Step 1: Detail header rename.** In the person detail view add `@State private var renaming = false` and `@State private var renameField = ""`. Replace the static `Text(person.name)` in `detailToolbar` with an inline editor:

```swift
if renaming {
    TextField("Name", text: $renameField)
        .textFieldStyle(.plain).font(.system(size: 15, weight: .semibold))
        .frame(width: 200)
        .onSubmit { commitRename() }
        .onExitCommand { renaming = false }
} else {
    Text(person.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
        .onTapGesture(count: 2) { renameField = person.name; renaming = true }
}
```

with:

```swift
private func commitRename() {
    let n = renameField.trimmingCharacters(in: .whitespacesAndNewlines)
    if !n.isEmpty, n != person.name { state.renamePerson(person.id, to: n) }
    renaming = false
}
```

- [ ] **Step 2: Person card menu rename.** In `PersonCard`'s `.contextMenu`, above "Remove person", add a Rename action. Because the card is a sibling of the grid, the simplest reliable affordance is a callback the parent wires to a rename prompt; if the card already takes an `onRemove` callback, add a parallel `onRename: (String) -> Void` and a small inline `@State` name field, OR (simpler) open the detail view's rename. Implement as: add `var onRename: () -> Void` to `PersonCard`, call it from a "Rename…" button; the parent opens that person's detail with `renaming = true`. (Confirm `PersonCard`'s existing callback wiring when editing.)

- [ ] **Step 3: Build** → Build complete.
- [ ] **Step 4: Commit** — `feat(people): rename a person (detail header + card menu); sidecars kept in sync`.

---

### Task 6: Same toggle on the suggested-cluster detail view

**Files:**
- Modify: `Sources/OpenPhotoApp/People/PeopleView.swift` — `ClusterDetailView`.

- [ ] **Step 1:** Mirror Task 3 in `ClusterDetailView`: add `@State private var showFaces = true`, a Faces/Photos `Picker` in its toolbar, and render its tiles via `FaceCropView` vs `ThumbnailImage` on `showFaces`. Reuse the same tile component if `ClusterDetailView` already uses `FacePhotoTile`; otherwise thread `showFace` into whatever tile it uses.

- [ ] **Step 2: Build** → Build complete.
- [ ] **Step 3: Commit** — `feat(people): Faces/Photos toggle on suggested-cluster review`.

---

## Self-review

- **Spec coverage:** Toggle (Tasks 3, 6) ✓; bulk Move-to-person (Task 4) ✓; rename + sidecar sync (Tasks 1, 2, 5) ✓; "multiple groups resolved by model" needs no task ✓; no format change ✓.
- **Type consistency:** `renamePerson(_:to:)`, `moveFaces(_:toPerson:fromPerson:)`, `FacePhotoTile.showFace`, `showFaces` state — names consistent across tasks.
- **Placeholders:** UI tasks note "confirm against the actual `FaceCropView`/`PersonCard` signatures when editing" — these are real signatures in the same file, resolved at edit time, not invented types. Catalog/AppState code is complete.
