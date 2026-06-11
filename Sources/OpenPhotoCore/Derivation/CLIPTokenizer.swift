import Foundation
import Compression

/// OpenAI/MobileCLIP byte-pair-encoding (BPE) tokenizer.
///
/// Faithful port of CLIP's `simple_tokenizer.py`: byte→unicode remap, greedy BPE merges driven by
/// the public `bpe_simple_vocab_16e6.txt` merge ranks, `<|startoftext|>` (49406) / `<|endoftext|>`
/// (49407) wrapping, padded/truncated to a fixed 77-token context window. Vocab size 49408.
///
/// The merges file is gitignored (downloaded artifact); we read the gzipped form from the model
/// directory so the tokenizer and the encoders ship together.
final class CLIPTokenizer {
    static let contextLength = 77
    static let bos: Int32 = 49406
    static let eos: Int32 = 49407

    /// token string → id
    private let encoder: [String: Int]
    /// merge pair "a b" → rank (lower = merge earlier)
    private let bpeRanks: [String: Int]
    /// byte value → unicode char used by the byte-level pre-tokenizer
    private let byteToUnicode: [UInt8: Character]
    private let tokenPattern: NSRegularExpression
    /// per-instance memo of word → merged-token string
    private var cache: [String: [String]] = [:]

    /// Build from the gzipped (or plain) `bpe_simple_vocab_16e6.txt[.gz]` in `directory`.
    /// Returns nil if the file is absent or unreadable — callers degrade gracefully.
    init?(vocabDirectory directory: URL) {
        let gz = directory.appendingPathComponent("bpe_simple_vocab_16e6.txt.gz")
        let plain = directory.appendingPathComponent("bpe_simple_vocab_16e6.txt")
        let text: String
        if let raw = try? Data(contentsOf: gz),
           let inflated = Self.gunzip(raw),
           let s = String(data: inflated, encoding: .utf8) {
            text = s
        } else if let s = try? String(contentsOf: plain, encoding: .utf8) {
            text = s
        } else {
            return nil
        }

        let ordered = Self.bytesToUnicode()
        var b2u: [UInt8: Character] = [:]
        for (byte, ch) in ordered { b2u[byte] = ch }
        self.byteToUnicode = b2u

        // CLIP uses merges file lines 1 ..< 49152-256-2+1 (== 48894 merges); skip the header line 0.
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // Trim a possible trailing empty element from a final newline.
        if lines.last == "" { lines.removeLast() }
        let mergeCount = 49152 - 256 - 2 + 1   // 48895 (exclusive upper bound)
        let upper = min(mergeCount, lines.count)
        guard upper > 1 else { return nil }
        let mergeLines = Array(lines[1 ..< upper])

        // Vocab order (must match the encoder ids the model was trained with):
        //   1. 256 base byte chars
        //   2. those 256 chars + "</w>"
        //   3. one entry per merge (the concatenation of the pair)
        //   4. "<|startoftext|>", "<|endoftext|>"
        // IMPORTANT: base-char vocab order must follow bytes_to_unicode()'s deterministic list
        // ordering (NOT dictionary iteration order, which is unstable in Swift).
        let baseChars = ordered.map { String($0.1) }
        var vocab: [String] = baseChars
        vocab.append(contentsOf: baseChars.map { $0 + "</w>" })

        var ranks: [String: Int] = [:]
        ranks.reserveCapacity(mergeLines.count)
        for (i, line) in mergeLines.enumerated() {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            ranks[line] = i
            vocab.append(String(parts[0]) + String(parts[1]))
        }
        vocab.append("<|startoftext|>")
        vocab.append("<|endoftext|>")

        var enc: [String: Int] = [:]
        enc.reserveCapacity(vocab.count)
        for (i, tok) in vocab.enumerated() { enc[tok] = i }
        self.encoder = enc
        self.bpeRanks = ranks

        // Same split regex as CLIP (contractions, letters, single digits, punctuation runs).
        // \p{L}/\p{N} Unicode properties are supported by ICU-backed NSRegularExpression.
        let pattern =
            "<\\|startoftext\\|>|<\\|endoftext\\|>|'s|'t|'re|'ve|'m|'ll|'d|\\p{L}+|\\p{N}|[^\\s\\p{L}\\p{N}]+"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        self.tokenPattern = re
    }

    /// Tokenize `text` → exactly `contextLength` Int32 ids (BOS … EOS, zero-padded, truncated).
    func encode(_ text: String) -> [Int32] {
        var ids: [Int32] = [Self.bos]
        let cleaned = Self.whitespaceClean(Self.basicClean(text)).lowercased()
        let ns = cleaned as NSString
        let matches = tokenPattern.matches(in: cleaned, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let word = ns.substring(with: m.range)
            // byte-level remap of the UTF-8 bytes
            var remapped = ""
            for byte in Array(word.utf8) {
                if let ch = byteToUnicode[byte] { remapped.append(ch) }
            }
            if remapped.isEmpty { continue }
            for tok in bpe(remapped) {
                if let id = encoder[tok] { ids.append(Int32(id)) }
            }
        }
        ids.append(Self.eos)

        if ids.count > Self.contextLength {
            // Keep the leading BOS-prefixed content and force the final slot to EOS (CLIP truncation).
            ids = Array(ids.prefix(Self.contextLength))
            ids[Self.contextLength - 1] = Self.eos
        } else if ids.count < Self.contextLength {
            ids.append(contentsOf: repeatElement(0, count: Self.contextLength - ids.count))
        }
        return ids
    }

    // MARK: - BPE

    private func bpe(_ token: String) -> [String] {
        if let hit = cache[token] { return hit }
        var word = token.map(String.init)
        guard !word.isEmpty else { return [] }
        // Mark the final symbol as word-final.
        word[word.count - 1] += "</w>"

        if word.count == 1 {
            cache[token] = word
            return word
        }

        while true {
            // Find the adjacent pair with the lowest merge rank.
            var bestRank = Int.max
            var bestIndex = -1
            for i in 0 ..< (word.count - 1) {
                let pair = word[i] + " " + word[i + 1]
                if let r = bpeRanks[pair], r < bestRank {
                    bestRank = r
                    bestIndex = i
                }
            }
            if bestIndex < 0 { break }

            let first = word[bestIndex]
            let second = word[bestIndex + 1]
            var newWord: [String] = []
            newWord.reserveCapacity(word.count)
            var i = 0
            while i < word.count {
                if i < word.count - 1 && word[i] == first && word[i + 1] == second {
                    newWord.append(first + second)
                    i += 2
                } else {
                    newWord.append(word[i])
                    i += 1
                }
            }
            word = newWord
            if word.count == 1 { break }
        }
        cache[token] = word
        return word
    }

    // MARK: - Text cleaning (subset of CLIP's basic/whitespace clean)

    private static func basicClean(_ s: String) -> String {
        // Decode HTML entities twice (matches CLIP's double html.unescape) then trim.
        decodeHTMLEntities(decodeHTMLEntities(s)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func whitespaceClean(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Minimal HTML entity decode (named common entities + numeric). CLIP relies on Python's
    /// html.unescape; for our caption/query text the common cases suffice.
    private static func decodeHTMLEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var result = ""
        result.reserveCapacity(s.count)
        var i = s.startIndex
        let named: [String: Character] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00a0}",
        ]
        while i < s.endIndex {
            if s[i] == "&", let semi = s[i...].firstIndex(of: ";"),
               s.distance(from: i, to: semi) <= 10 {
                let entStart = s.index(after: i)
                let entity = String(s[entStart ..< semi])
                if entity.hasPrefix("#") {
                    let numPart = entity.dropFirst()
                    let scalarValue: UInt32?
                    if numPart.hasPrefix("x") || numPart.hasPrefix("X") {
                        scalarValue = UInt32(numPart.dropFirst(), radix: 16)
                    } else {
                        scalarValue = UInt32(numPart)
                    }
                    if let v = scalarValue, let sc = Unicode.Scalar(v) {
                        result.append(Character(sc))
                        i = s.index(after: semi)
                        continue
                    }
                } else if let ch = named[entity] {
                    result.append(ch)
                    i = s.index(after: semi)
                    continue
                }
            }
            result.append(s[i])
            i = s.index(after: i)
        }
        return result
    }

    // MARK: - Byte ↔ unicode table (CLIP bytes_to_unicode)

    /// Returns the (byte, char) pairs in CLIP's deterministic `bytes_to_unicode()` order. The order
    /// is load-bearing: it fixes the first 512 vocab ids.
    private static func bytesToUnicode() -> [(UInt8, Character)] {
        var bs: [Int] = []
        bs.append(contentsOf: 0x21 ... 0x7E)   // '!' ... '~'
        bs.append(contentsOf: 0xA1 ... 0xAC)
        bs.append(contentsOf: 0xAE ... 0xFF)
        var cs = bs
        var n = 0
        for b in 0 ..< 256 {
            if !bs.contains(b) {
                bs.append(b)
                cs.append(256 + n)
                n += 1
            }
        }
        var pairs: [(UInt8, Character)] = []
        pairs.reserveCapacity(bs.count)
        for (b, c) in zip(bs, cs) {
            pairs.append((UInt8(b), Character(Unicode.Scalar(UInt32(c))!)))
        }
        return pairs
    }

    // MARK: - gzip

    /// Inflate a gzip stream (RFC 1952) using the system Compression framework's raw-DEFLATE codec.
    static func gunzip(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 0x08 else { return nil }
        let flg = bytes[3]
        var idx = 10
        if flg & 0x04 != 0 {   // FEXTRA
            guard idx + 2 <= bytes.count else { return nil }
            let xlen = Int(bytes[idx]) | (Int(bytes[idx + 1]) << 8)
            idx += 2 + xlen
        }
        if flg & 0x08 != 0 {   // FNAME
            while idx < bytes.count && bytes[idx] != 0 { idx += 1 }
            idx += 1
        }
        if flg & 0x10 != 0 {   // FCOMMENT
            while idx < bytes.count && bytes[idx] != 0 { idx += 1 }
            idx += 1
        }
        if flg & 0x02 != 0 { idx += 2 }   // FHCRC
        let n = bytes.count
        guard idx < n - 8 else { return nil }
        let isize = Int(bytes[n - 4]) | (Int(bytes[n - 3]) << 8)
            | (Int(bytes[n - 2]) << 16) | (Int(bytes[n - 1]) << 24)
        var capacity = isize > 0 ? isize : bytes.count * 8
        if capacity < 4096 { capacity = 4096 }

        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dst.deallocate() }
        let deflateLen = (n - 8) - idx
        let decoded = bytes.withUnsafeBufferPointer { buf -> Int in
            let src = buf.baseAddress!.advanced(by: idx)
            return compression_decode_buffer(dst, capacity, src, deflateLen, nil, COMPRESSION_ZLIB)
        }
        guard decoded > 0 else { return nil }
        return Data(bytes: dst, count: decoded)
    }
}
