import Testing
import Foundation
@testable import OpenPhotoCore

@Test func registryReportsAndDedupesChanges() {
    let reg = MLAvailability()
    #expect(reg.status(model: "x") == .unknown)
    #expect(reg.report(model: "x", .available) == true)    // changed
    #expect(reg.report(model: "x", .available) == false)   // no change → no post
    #expect(reg.status(model: "x") == .available)
    #expect(reg.report(model: "x", .unavailable("boom")) == true)
    #expect(reg.snapshot()["x"] == .unavailable("boom"))
}

@Test func registryPostsNotificationOnChangeOnly() {
    let reg = MLAvailability()
    var posts = 0
    let token = NotificationCenter.default.addObserver(
        forName: MLAvailability.didChange, object: nil, queue: nil) { _ in posts += 1 }
    defer { NotificationCenter.default.removeObserver(token) }
    reg.report(model: "y", .available)     // post
    reg.report(model: "y", .available)     // no post
    reg.report(model: "y", .absent)        // post
    #expect(posts == 2)
}

@Test func capabilityUnknownWhenNothingTried() {
    #expect(mlCapabilityStatus(.faceRecognition, from: [:]) == .unknown)
    #expect(mlCapabilityStatus(.semanticSearch, from: [:]) == .unknown)
}

@Test func faceRecognitionTracksAdaface() {
    #expect(mlCapabilityStatus(.faceRecognition,
        from: [MLModelKey.adaface: .available]) == .available)
    #expect(mlCapabilityStatus(.faceRecognition,
        from: [MLModelKey.adaface: .unavailable("no")]) == .unavailable("no"))
    #expect(mlCapabilityStatus(.faceRecognition,
        from: [MLModelKey.adaface: .absent]) == .absent)
}

@Test func semanticSearchUnavailableIfEitherModelFails() {
    // Image failed, text not yet tried → loud unavailable wins.
    let m: [String: MLStatus] = [MLModelKey.mobileclipImage: .unavailable("boom"),
                                 MLModelKey.mobileclipText: .unknown]
    if case .unavailable = mlCapabilityStatus(.semanticSearch, from: m) {} else {
        Issue.record("expected .unavailable when the image model fails")
    }
    // Both available → available.
    #expect(mlCapabilityStatus(.semanticSearch,
        from: [MLModelKey.mobileclipImage: .available,
               MLModelKey.mobileclipText: .available]) == .available)
}

@Test func semanticSearchAbsentWhenOneModelAbsentRestAvailable() {
    #expect(mlCapabilityStatus(.semanticSearch,
        from: [MLModelKey.mobileclipImage: .absent,
               MLModelKey.mobileclipText: .available]) == .absent)
}
