import Testing
import Foundation
@testable import OpenPhotoCore

@Test func loaderGracefulOnAbsence() {
    #expect(GeoNamesLoader.load(directory: nil).isLoaded == false)
    let missing = URL(fileURLWithPath: "/nonexistent/geonames-\(UUID().uuidString)")
    let geo = GeoNamesLoader.load(directory: missing)
    #expect(geo.isLoaded == false)
    #expect(geo.place(lat: 25.03, lon: 121.57) == nil)        // never crashes
}

@Test func loaderParsesSyntheticThreeFiles() throws {
    let t = try TestDirs(); defer { t.cleanup() }
    let dir = t.root.appendingPathComponent("geonames", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // cities15000.txt — GeoNames column order (0-based):
    //   0:geonameid  1:name  2:asciiname  3:altnames  4:lat  5:lon
    //   6:fclass  7:fcode  8:country  9:cc2  10:admin1  ...
    let cityCols: [String] = ["1668341", "Taipei", "Taipei", "", "25.03", "121.57",
                               "P", "PPLC", "TW", "", "TPE"] + Array(repeating: "", count: 8)
    try (cityCols.joined(separator: "\t") + "\n").write(
        to: dir.appendingPathComponent("cities15000.txt"),
        atomically: true, encoding: .utf8)
    // admin1CodesASCII.txt — "<CC>.<admin1> TAB name TAB asciiname TAB geonameid"
    try "TW.TPE\tTaipei\tTaipei\t1668341\n".write(
        to: dir.appendingPathComponent("admin1CodesASCII.txt"),
        atomically: true, encoding: .utf8)
    // countryInfo.txt — ISO(0) ISO3(1) ISO-Numeric(2) fips(3) Country(4) Capital(5)...
    // Lines starting with '#' are comments and must be skipped.
    try "#comment header\nTW\tTWN\t158\tTW\tTaiwan\tTaipei\n".write(
        to: dir.appendingPathComponent("countryInfo.txt"),
        atomically: true, encoding: .utf8)

    let geo = GeoNamesLoader.load(directory: dir)
    #expect(geo.isLoaded)
    let p = try #require(geo.place(lat: 25.04, lon: 121.56))
    #expect(p.city == "Taipei" && p.region == "Taipei" && p.country == "Taiwan"
            && p.countryCode == "TW")
}
