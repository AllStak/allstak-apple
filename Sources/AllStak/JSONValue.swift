import Foundation

/// A `Codable` JSON value. Used so the scope's free-form `contexts`/`extra`
/// dictionaries (which carry arbitrary `Any` values supplied by the host app)
/// can be `Encodable` for the wire and `Decodable` for round-trip tests, without
/// pulling in a third-party `AnyCodable`.
///
/// Only JSON-representable shapes are kept: string / number (Int or Double) /
/// bool / null / array / object. Anything that cannot be represented as JSON is
/// coerced to its `String(describing:)` form on the way in (fail-open — a value
/// the host app passed must never break encoding), so the event still serialises.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    /// Wrap an arbitrary `Any` into a JSON value. Unknown / non-JSON types are
    /// coerced to a string so encoding never fails (fail-open). `NSNull` and
    /// `nil`-bearing optionals map to ``null``.
    public init(_ value: Any?) {
        guard let value, !(value is NSNull) else { self = .null; return }

        switch value {
        case let v as JSONValue:
            self = v
        case let v as Bool where type(of: value) == Bool.self:
            // Guard the dynamic type so `NSNumber`-boxed ints aren't misread as
            // bools (a common Foundation footgun).
            self = .bool(v)
        case let v as Int:
            self = .int(v)
        case let v as Int64:
            self = .int(Int(truncatingIfNeeded: v))
        case let v as UInt:
            self = .int(Int(truncatingIfNeeded: v))
        case let v as Double:
            self = .double(v)
        case let v as Float:
            self = .double(Double(v))
        case let v as String:
            self = .string(v)
        case let v as [Any?]:
            self = .array(v.map { JSONValue($0) })
        case let v as [String: Any?]:
            self = .object(v.mapValues { JSONValue($0) })
        case let v as [String: Any]:
            self = .object(v.mapValues { JSONValue($0) })
        case let v as NSNumber:
            // CFBoolean reports as NSNumber; distinguish by its objCType.
            if CFGetTypeID(v) == CFBooleanGetTypeID() {
                self = .bool(v.boolValue)
            } else if CFNumberIsFloatType(v) {
                self = .double(v.doubleValue)
            } else {
                self = .int(v.intValue)
            }
        default:
            self = .string(String(describing: value))
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Int.self) {
            self = .int(v)
        } else if let v = try? container.decode(Double.self) {
            self = .double(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    /// Coerce an `[String: Any]` map into the `Codable` `[String: JSONValue]`
    /// the wire model uses.
    func asJSONValueMap() -> [String: JSONValue] {
        mapValues { JSONValue($0) }
    }
}
