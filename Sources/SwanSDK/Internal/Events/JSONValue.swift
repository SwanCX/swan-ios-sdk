import Foundation

/// Type-safe representation of a JSON value used by the events surface.
///
/// **Capabilities:** `custom-events`, `semantic-ecommerce-events`.
///
/// Spec: `spec/wire/event-ingest.yaml` `BatchEvent.data` description,
/// `spec/api/events.yaml` `EventEnvelope.data`.
///
/// ## Why an enum, not `Any`
///
/// Android uses `Map<String, Any?>` because Kotlin's `JsonObject` builder
/// accepts a `Map<String, Any?>` and erases at the JSON boundary. Swift
/// has no such ergonomic erasure: a `[String: Any]` payload still has to
/// be normalized to `JSONSerialization`-compatible types at encode time
/// (string, number, bool, null, dictionary, array). Doing that conversion
/// once at the type system level — via this enum — gives the caller:
///
///   - compile-time safety (`.number(3.0)` vs `.string("3.0")` can't be
///     accidentally swapped),
///   - `Sendable` conformance (so events can be passed across actor /
///     `Task.detached` boundaries without a warning),
///   - explicit `Equatable` for tests.
///
/// The `[String: Any]` overload (``Swan/track(_:attributes:)-9zo5p``)
/// is kept for parity with Android's ergonomics — internally it converts
/// to this type via ``fromAny(_:)``.
///
/// ## Wire shape
///
/// Values map 1:1 to JSON types:
///
///   - ``string(_:)``  → JSON string
///   - ``number(_:)``  → JSON number (Double — encodes integer-shaped
///     values without a trailing `.0` via the custom encoder below)
///   - ``int(_:)``     → JSON integer (preserved through encode/decode)
///   - ``bool(_:)``    → JSON boolean
///   - ``null``        → JSON null
///   - ``array(_:)``   → JSON array
///   - ``object(_:)``  → JSON object (string keys only)
///
/// Both ``number(_:)`` and ``int(_:)`` exist because RN's JSON encoder
/// preserves the source numeric type when round-tripping
/// `{quantity: 2}` — and the golden batch carries `quantity: 2` as a
/// bare integer, not `2.0`. Foundation's `JSONEncoder` writes `Int` as
/// `2` and `Double` as `2.0`; we expose both so the caller's intent is
/// honored on the wire.
public enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case int(Int)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {

    /// Best-effort coercion from `Any?` — used by the `[String: Any]`
    /// overload on the public surface.
    ///
    /// Coercion rules (matches Android `mapToJsonObject` / `anyToJsonElement`):
    ///   - `nil` / `NSNull` → `.null`
    ///   - already-a-`JSONValue` → passthrough
    ///   - `String` → `.string`
    ///   - `Bool` → `.bool`  (must come before Int — `Bool` is bridged
    ///     to `NSNumber` and would otherwise match the integer branch)
    ///   - `Int`, `Int8`...`UInt64` → `.int`
    ///   - `Float`, `Double`, `CGFloat`-like → `.number`
    ///   - `NSNumber` → `.bool` / `.int` / `.number` per CFNumber type
    ///   - `[Any?]` / `NSArray` → `.array` (recursive)
    ///   - `[String: Any?]` / `NSDictionary` → `.object` (recursive,
    ///     string keys only)
    ///   - anything else → `.string(String(describing: value))` (lossy
    ///     fallback — caller should normalize ahead of time, matches
    ///     Android's `toString()` branch).
    static func fromAny(_ value: Any?) -> JSONValue {
        guard let value = value else { return .null }
        if value is NSNull { return .null }
        if let v = value as? JSONValue { return v }

        // Bool MUST be checked before Int: NSNumber bridging would
        // otherwise route a `true` through the integer branch.
        if let v = value as? Bool { return .bool(v) }

        if let v = value as? Int { return .int(v) }
        if let v = value as? Int64 { return .int(Int(v)) }
        if let v = value as? UInt { return .int(Int(v)) }
        if let v = value as? Double { return .number(v) }
        if let v = value as? Float { return .number(Double(v)) }
        if let v = value as? String { return .string(v) }

        if let v = value as? NSNumber {
            // CFNumber type tells us whether the boxed value was a
            // bool, an int, or a float.
            let typeID = CFGetTypeID(v as CFTypeRef)
            if typeID == CFBooleanGetTypeID() {
                return .bool(v.boolValue)
            }
            let numType = CFNumberGetType(v as CFNumber)
            switch numType {
            case .sInt8Type, .sInt16Type, .sInt32Type, .sInt64Type,
                 .charType, .shortType, .intType, .longType, .longLongType,
                 .cfIndexType, .nsIntegerType:
                return .int(v.intValue)
            default:
                return .number(v.doubleValue)
            }
        }

        if let arr = value as? [Any?] {
            return .array(arr.map { fromAny($0) })
        }
        if let nsArr = value as? NSArray {
            return .array(nsArr.map { fromAny($0) })
        }

        if let dict = value as? [String: Any?] {
            var out: [String: JSONValue] = [:]
            for (k, v) in dict { out[k] = fromAny(v) }
            return .object(out)
        }
        if let nsDict = value as? NSDictionary {
            var out: [String: JSONValue] = [:]
            for (k, v) in nsDict {
                let key = (k as? String) ?? String(describing: k)
                out[key] = fromAny(v)
            }
            return .object(out)
        }

        return .string(String(describing: value))
    }

    /// Build a `[String: JSONValue]` from a `[String: Any]`. Used by the
    /// public `track(_:attributes:)` `[String: Any]` overload.
    static func fromAnyDictionary(_ map: [String: Any]) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for (k, v) in map { out[k] = fromAny(v) }
        return out
    }
}

extension JSONValue: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .int(let i):    try container.encode(i)
        case .bool(let b):   try container.encode(b)
        case .null:          try container.encodeNil()
        case .array(let a):  try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

extension JSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        // Try bool BEFORE numeric branches — `NSNumber(true)` decodes
        // as `1` in the integer branch otherwise.
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let i = try? container.decode(Int.self) { self = .int(i); return }
        if let d = try? container.decode(Double.self) { self = .number(d); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        if let a = try? container.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? container.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "JSONValue: not a JSON-compatible value"
        )
    }
}
