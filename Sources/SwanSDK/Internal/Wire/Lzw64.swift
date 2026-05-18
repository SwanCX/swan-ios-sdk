import Foundation

/// Swan wire-format codec — LZW with a 6-bit URL-safe alphabet, 18-bit
/// codes packed LSB-first into 3-char triples.
///
/// Spec: `spec/wire/LZW64.md` — the contract is byte-for-byte equivalence
/// with the canonical encoder in
/// `swan-ecom-tracking-backend/src/utils/lzwEncoding.ts`.
///
/// Used to:
///   - Compress JSON request bodies before POSTing to Swan endpoints.
///   - Encode the `X-Swan-Device-Id` header for most Swan SDK endpoints.
///
/// Backend always tries `JSON.parse` first via `parseJsonOrLzw64`, so
/// plain JSON bodies still work — but RN parity means we always encode.
///
/// NOT a stock base64. The alphabet is `A-Za-z0-9-_` with `0-9` AFTER
/// lowercase. Hard-coded; do not substitute a base64 library.
enum Lzw64 {

    /// 64-char URL-safe alphabet, indexed 0..63.
    static let alphabet =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

    /// Pre-computed [Character: Int] reverse lookup for the decoder.
    private static let alphabetIndex: [Character: Int] = {
        var map = [Character: Int]()
        for (i, ch) in alphabet.enumerated() {
            map[ch] = i
        }
        return map
    }()

    /// `(1 << 18) - 1` — dictionary reset point. Off-by-one from the
    /// theoretical 18-bit max (262144). Encoder + decoder agree.
    private static let dictReset = (1 << 18) - 1

    /// Encode a UTF-8 string with LZW64.
    ///
    /// Empty/nil input passes through unchanged — both backend
    /// `parseJsonOrLzw64` and RN `lzw64_encode` short-circuit on falsy
    /// input. Encoding `""` to 3 zero bytes would round-trip to `" "`
    /// and fail backend parse.
    ///
    /// Single-character input encodes to a single 3-char triple of the
    /// byte index — no dictionary entries are created.
    static func encode(_ input: String?) -> String? {
        guard let input = input, !input.isEmpty else { return input }

        // Convert to UTF-8 bytes; we treat the byte stream as
        // 1-byte-per-char Strings so the dictionary keying matches
        // RN's JS-string-of-bytes idiom.
        let bytes = Array(input.utf8)

        var dict = [String: Int]()
        var word = byteToString(bytes[0])
        var num = 256
        var out = ""
        out.reserveCapacity(bytes.count * 4)

        for i in 1..<bytes.count {
            let c = byteToString(bytes[i])
            let candidate = word + c
            if dict[candidate] != nil {
                word = candidate
            } else {
                dict[candidate] = num
                num += 1
                emit(into: &out, word: word, dict: dict)
                word = c
                if num == dictReset {
                    dict.removeAll(keepingCapacity: true)
                    num = 256
                }
            }
        }
        emit(into: &out, word: word, dict: dict)
        return out
    }

    /// Decode an LZW64-encoded string back to UTF-8.
    ///
    /// Used in tests (round-trip + golden assertions). Production code
    /// does not decode bodies — backend is the only decoder. Header
    /// `X-Swan-Device-Id` is encoded outbound only.
    static func decode(_ input: String?) -> String? {
        guard let input = input, !input.isEmpty else { return input }
        precondition(
            input.count % 3 == 0,
            "LZW64 input length must be a multiple of 3 (got \(input.count))"
        )
        let chars = Array(input)

        var dict = [Int: String]()
        var num = 256
        var word = byteToString(UInt8(readTriple(chars, 0)))
        var prev = word
        var outRaw = ""
        outRaw.reserveCapacity(input.count)
        outRaw += word

        var i = 3
        while i < chars.count {
            let key = readTriple(chars, i)
            if key < 256 {
                word = byteToString(UInt8(key))
            } else if let cached = dict[key] {
                word = cached
            } else {
                // Classic LZW K+v[0] case.
                word = prev + String(prev.first!)
            }
            outRaw += word
            dict[num] = prev + String(word.first!)
            num += 1
            prev = word
            if num == dictReset {
                dict.removeAll(keepingCapacity: true)
                num = 256
            }
            i += 3
        }

        // outRaw holds raw bytes packed as Unicode codepoints 0..255.
        // Pack back into UTF-8 bytes and decode.
        var bytes = [UInt8]()
        bytes.reserveCapacity(outRaw.count)
        for ch in outRaw.unicodeScalars {
            bytes.append(UInt8(ch.value & 0xFF))
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    /// Emits one 18-bit code as 3 base-64 chars, LSB-first.
    private static func emit(into out: inout String, word: String, dict: [String: Int]) {
        let key: Int
        if word.count > 1 {
            key = dict[word]!
        } else {
            // Length-1 word: code is the raw byte (0..255).
            key = Int(word.unicodeScalars.first!.value) & 0xFF
        }
        let a = alphabet.index(alphabet.startIndex, offsetBy: key & 0x3F)
        let b = alphabet.index(alphabet.startIndex, offsetBy: (key >> 6) & 0x3F)
        let c = alphabet.index(alphabet.startIndex, offsetBy: (key >> 12) & 0x3F)
        out.append(alphabet[a])
        out.append(alphabet[b])
        out.append(alphabet[c])
    }

    private static func readTriple(_ chars: [Character], _ offset: Int) -> Int {
        let a = lookup(chars[offset])
        let b = lookup(chars[offset + 1])
        let c = lookup(chars[offset + 2])
        return a | (b << 6) | (c << 12)
    }

    private static func lookup(_ ch: Character) -> Int {
        guard let idx = alphabetIndex[ch] else {
            fatalError("Char '\(ch)' not in LZW64 alphabet")
        }
        return idx
    }

    /// Convert a single byte to a 1-codepoint String holding that byte
    /// value (0..255). Mirrors RN's `unescape(encodeURIComponent(s))`
    /// byte-string idiom — we operate on bytes via Strings so that the
    /// dictionary keying matches RN exactly.
    private static func byteToString(_ b: UInt8) -> String {
        let scalar = Unicode.Scalar(UInt32(b))!
        return String(Character(scalar))
    }
}
