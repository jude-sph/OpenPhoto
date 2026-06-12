import Testing
import Foundation
@testable import OpenPhotoCore

// MARK: - UndoPlan.inverseMoveGroups

@Test func inverseMoveGroups_multiOriginDirs() {
    // 3 moves from 2 different origin directories.
    // Move 1 + 2: from "2024/Paris/" (origin dir = "2024/Paris")
    // Move 3: from vault root "" (origin dir = "")
    let moves = [
        MovedFileRecord(vaultID: "vault1", from: "2024/Paris/IMG_001.jpg", to: "Trips/France/IMG_001.jpg"),
        MovedFileRecord(vaultID: "vault1", from: "2024/Paris/IMG_002.jpg", to: "Trips/France/IMG_002.jpg"),
        MovedFileRecord(vaultID: "vault2", from: "IMG_ROOT.jpg",           to: "Inbox/IMG_ROOT.jpg"),
    ]
    let result = UndoPlan.inverseMoveGroups(moves)

    // Expect 2 groups, sorted by destDir ascending ("" < "2024/Paris").
    #expect(result.count == 2)

    // Group 0: origin dir "" (vault root)
    let g0 = result[0]
    #expect(g0.destDir == "")
    #expect(g0.ids == ["vault2|Inbox/IMG_ROOT.jpg"])

    // Group 1: origin dir "2024/Paris"
    let g1 = result[1]
    #expect(g1.destDir == "2024/Paris")
    #expect(g1.ids == ["vault1|Trips/France/IMG_001.jpg", "vault1|Trips/France/IMG_002.jpg"])
}

@Test func inverseMoveGroups_instanceIDComposition() {
    // instanceID must be vaultID + "|" + to (the NEW relPath after the move).
    let move = MovedFileRecord(vaultID: "myVault", from: "Old/photo.jpg", to: "New/photo.jpg")
    let result = UndoPlan.inverseMoveGroups([move])

    #expect(result.count == 1)
    #expect(result[0].ids == ["myVault|New/photo.jpg"])
}

@Test func inverseMoveGroups_singleGroup_sortedIDs() {
    // All from the same origin dir; ids should be sorted within the group.
    let moves = [
        MovedFileRecord(vaultID: "v", from: "src/c.jpg", to: "dst/c.jpg"),
        MovedFileRecord(vaultID: "v", from: "src/a.jpg", to: "dst/a.jpg"),
        MovedFileRecord(vaultID: "v", from: "src/b.jpg", to: "dst/b.jpg"),
    ]
    let result = UndoPlan.inverseMoveGroups(moves)

    #expect(result.count == 1)
    #expect(result[0].destDir == "src")
    #expect(result[0].ids == ["v|dst/a.jpg", "v|dst/b.jpg", "v|dst/c.jpg"])
}

// MARK: - UndoAction.label

@Test func label_deletePhotos_singular() {
    let action = UndoAction.deletePhotos(hashes: ["h1"], count: 1)
    #expect(action.label == "Delete 1 Photo")
}

@Test func label_deletePhotos_plural() {
    let action = UndoAction.deletePhotos(hashes: ["h1", "h2", "h3"], count: 3)
    #expect(action.label == "Delete 3 Photos")
}

@Test func label_movePhotos_singular() {
    let moves = [MovedFileRecord(vaultID: "v", from: "a.jpg", to: "b.jpg")]
    let action = UndoAction.movePhotos(moves: moves)
    #expect(action.label == "Move 1 Photo")
}

@Test func label_movePhotos_plural() {
    let moves = [
        MovedFileRecord(vaultID: "v", from: "a.jpg", to: "x/a.jpg"),
        MovedFileRecord(vaultID: "v", from: "b.jpg", to: "x/b.jpg"),
        MovedFileRecord(vaultID: "v", from: "c.jpg", to: "x/c.jpg"),
    ]
    let action = UndoAction.movePhotos(moves: moves)
    #expect(action.label == "Move 3 Photos")
}

@Test func label_moveFolder() {
    let action = UndoAction.moveFolder(from: "Old/Dir", to: "New/Dir")
    #expect(action.label == "Move Folder")
}

@Test func label_rename() {
    let action = UndoAction.rename(vaultID: "v", relPath: "Photos/newName.jpg", oldName: "oldName.jpg")
    #expect(action.label == "Rename")
}

// MARK: - UndoAction Equatable round-trips

@Test func equatable_deletePhotos() {
    let a = UndoAction.deletePhotos(hashes: ["h1", "h2"], count: 2)
    let b = UndoAction.deletePhotos(hashes: ["h1", "h2"], count: 2)
    let c = UndoAction.deletePhotos(hashes: ["h1"], count: 1)
    #expect(a == b)
    #expect(a != c)
}

@Test func equatable_movePhotos() {
    let rec = MovedFileRecord(vaultID: "v", from: "a.jpg", to: "b.jpg")
    let a = UndoAction.movePhotos(moves: [rec])
    let b = UndoAction.movePhotos(moves: [rec])
    let c = UndoAction.movePhotos(moves: [])
    #expect(a == b)
    #expect(a != c)
}

@Test func equatable_moveFolder() {
    let a = UndoAction.moveFolder(from: "X", to: "Y")
    let b = UndoAction.moveFolder(from: "X", to: "Y")
    let c = UndoAction.moveFolder(from: "X", to: "Z")
    #expect(a == b)
    #expect(a != c)
}

@Test func equatable_rename() {
    let a = UndoAction.rename(vaultID: "v", relPath: "Photos/new.jpg", oldName: "old.jpg")
    let b = UndoAction.rename(vaultID: "v", relPath: "Photos/new.jpg", oldName: "old.jpg")
    let c = UndoAction.rename(vaultID: "v", relPath: "Photos/new.jpg", oldName: "other.jpg")
    #expect(a == b)
    #expect(a != c)
}

@Test func equatable_differentCases() {
    let del = UndoAction.deletePhotos(hashes: [], count: 0)
    let mov = UndoAction.movePhotos(moves: [])
    #expect(del != mov)
}

// MARK: - MovedFileRecord Equatable

@Test func movedFileRecord_equatable() {
    let r1 = MovedFileRecord(vaultID: "v", from: "a.jpg", to: "b.jpg")
    let r2 = MovedFileRecord(vaultID: "v", from: "a.jpg", to: "b.jpg")
    let r3 = MovedFileRecord(vaultID: "v", from: "a.jpg", to: "c.jpg")
    #expect(r1 == r2)
    #expect(r1 != r3)
}
