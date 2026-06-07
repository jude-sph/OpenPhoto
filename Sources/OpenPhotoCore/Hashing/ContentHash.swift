/// Content-addressed identity of a media file. Replaced with the real
/// implementation in Task 2.
public struct ContentHash: Hashable, Sendable {
    public let stringValue: String
    public init(stringValue: String) { self.stringValue = stringValue }
}
