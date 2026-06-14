import Testing
import Foundation
@testable import OpenPhotoCore

@Test func float16CodecRoundTripsWithinHalfPrecision() {
    let samples: [Float] = [0, 1, -1, 0.5, -0.5, 0.044, -0.044, 0.0123, -0.0098,
                            1e-4, -1e-4, 6.0e-5, 2.0e-5, 0.99951, -0.333333]
    let packed = Float16Codec.pack(samples)
    #expect(packed.count == samples.count * 2)
    let restored = Float16Codec.unpack(packed, dim: samples.count)
    #expect(restored.count == samples.count)
    for (a, b) in zip(samples, restored) {
        #expect(abs(a - b) <= max(1e-3, abs(a) * 0.001) + 1e-7, "round-trip \(a) -> \(b)")
    }
}

@Test func float16CodecHandlesEmptyAndTruncation() {
    #expect(Float16Codec.pack([]) == Data())
    #expect(Float16Codec.unpack(Data(), dim: 0) == [])
    let packed = Float16Codec.pack([1, 2, 3])
    #expect(Float16Codec.unpack(packed, dim: 2).count == 2)   // dim caps output
    #expect(Float16Codec.unpack(packed, dim: 99).count == 3)  // never over-reads
}

#if arch(arm64)
@Test func float16CodecIsByteIdenticalToNativeFloat16OnARM64() {
    // arm64 has native Float16 conversions which DEFINE the on-disk format. Prove the portable
    // (vImage) codec produces identical bytes so existing catalogs remain readable cross-arch.
    let samples: [Float] = [0, -0.0, 1, -1, 0.5, -0.5, 0.04419, -0.04419, 0.99951,
                            1e-4, -1e-4, 6.0e-5, 5.96e-8, 2.0e-7, 0.3333333, -0.1234567, 65504, -65504]
    var canonical = Data()
    for f in samples { var h = Float16(f); withUnsafeBytes(of: &h) { canonical.append(contentsOf: $0) } }
    #expect(Float16Codec.pack(samples) == canonical, "portable pack must be byte-identical to native Float16")

    var nativeDecoded = [Float]()
    canonical.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        let h = raw.bindMemory(to: Float16.self)
        for i in 0..<samples.count { nativeDecoded.append(Float(h[i])) }
    }
    #expect(Float16Codec.unpack(canonical, dim: samples.count) == nativeDecoded,
            "portable unpack must match native Float16 decode")
}
#endif
