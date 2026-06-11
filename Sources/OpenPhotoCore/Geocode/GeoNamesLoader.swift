import Foundation

/// Parses the bundled GeoNames extract (cities15000.txt + admin1CodesASCII.txt + countryInfo.txt)
/// under `directory` (…/geonames/) into a ReverseGeocoder. Graceful absence is TOTAL: a nil/missing
/// directory or missing files → an empty-but-valid geocoder (isLoaded == false). Never throws for
/// absence, never touches the network.
///
/// Column indices (0-based) in cities15000.txt:
///   0  geonameid     1  name           2  asciiname       3  alternatenames
///   4  latitude      5  longitude      6  feature class   7  feature code
///   8  country code  9  cc2            10 admin1 code     11 admin2 code
///   12 admin3 code   13 admin4 code    14 population      15 elevation
///   16 dem           17 timezone       18 modification date
///
/// admin1CodesASCII.txt: "<CC>.<admin1> TAB name TAB asciiname TAB geonameid"
///
/// countryInfo.txt: ISO(0) ISO3(1) ISO-Numeric(2) fips(3) Country(4) Capital(5) ...
///   (lines beginning with '#' are comments)
public enum GeoNamesLoader {
    public static func load(directory: URL?) -> ReverseGeocoder {
        guard let dir = directory else { return ReverseGeocoder(cities: []) }
        let citiesURL = dir.appendingPathComponent("cities15000.txt")
        guard let citiesText = try? String(contentsOf: citiesURL, encoding: .utf8) else {
            return ReverseGeocoder(cities: [])
        }
        // admin1: "<cc>.<admin1>" → region name (col 1, 0-based). Best-effort.
        // Use .newlines character set to tolerate both LF and CRLF line endings.
        var admin1: [String: String] = [:]
        if let a = try? String(contentsOf: dir.appendingPathComponent("admin1CodesASCII.txt"),
                               encoding: .utf8) {
            for line in a.components(separatedBy: .newlines) where !line.isEmpty {
                let f = line.components(separatedBy: "\t")
                if f.count >= 2 { admin1[f[0]] = f[1] }
            }
        }
        // countryInfo: ISO cc (col 0) → country name (col 4). Skip "#" comment lines.
        // Note: GeoNames ships countryInfo.txt with CRLF endings — .newlines handles both.
        var countries: [String: String] = [:]
        if let c = try? String(contentsOf: dir.appendingPathComponent("countryInfo.txt"),
                               encoding: .utf8) {
            for line in c.components(separatedBy: .newlines) where !line.hasPrefix("#") && !line.isEmpty {
                let f = line.components(separatedBy: "\t")
                if f.count >= 5 { countries[f[0]] = f[4] }
            }
        }
        var out: [ReverseGeocoder.City] = []
        out.reserveCapacity(30_000)
        for line in citiesText.components(separatedBy: .newlines) where !line.isEmpty {
            let f = line.components(separatedBy: "\t")
            // name=1, lat=4, lon=5, country=8, admin1=10
            guard f.count >= 11, let lat = Double(f[4]), let lon = Double(f[5]) else { continue }
            let cc = f[8]
            out.append(ReverseGeocoder.City(
                name: f[1], lat: lat, lon: lon, countryCode: cc,
                region: admin1["\(cc).\(f[10])"] ?? "",
                country: countries[cc] ?? ""))
        }
        return ReverseGeocoder(cities: out)
    }
}
