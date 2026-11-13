import Foundation

public struct JSONField: Equatable, Sendable {
    public var key: String
    public var value: JSONValue
    public init(_ key: String, _ value: JSONValue) {
        self.key = key
        self.value = value
    }
}

/// A JSON tree that keeps key order, so the file on disk is written the same way every time
/// (stable diffs, readable by people and by other tools).
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case money(Money)
    /// A numeric literal carried through untouched (used for fields this app doesn't own).
    case raw(String)
    case string(String)
    case array([JSONValue])
    case object([JSONField])

    var isScalar: Bool {
        switch self {
        case .array, .object: return false
        default: return true
        }
    }

    public func render() -> String {
        var out = ""
        write(&out, indent: 0, top: true)
        out.append("\n")
        return out
    }

    private func write(_ out: inout String, indent: Int, top: Bool = false) {
        let pad = String(repeating: "  ", count: indent + 1)
        let closePad = String(repeating: "  ", count: indent)
        switch self {
        case .null: out.append("null")
        case .bool(let b): out.append(b ? "true" : "false")
        case .int(let i): out.append(String(i))
        case .money(let m): out.append(m.plain)
        case .raw(let r): out.append(r)
        case .string(let s): out.append(JSONValue.quote(s))
        case .array(let items):
            if items.isEmpty {
                out.append("[]")
            } else if items.allSatisfy({ $0.isScalar }) && items.count <= 8 {
                out.append("[")
                for (i, v) in items.enumerated() {
                    if i > 0 { out.append(", ") }
                    v.write(&out, indent: indent)
                }
                out.append("]")
            } else {
                out.append("[\n")
                for (i, v) in items.enumerated() {
                    out.append(pad)
                    v.write(&out, indent: indent + 1)
                    out.append(i < items.count - 1 ? ",\n" : "\n")
                }
                out.append(closePad + "]")
            }
        case .object(let fields):
            if fields.isEmpty {
                out.append("{}")
            } else if !top && fields.allSatisfy({ $0.value.isScalar }) {
                // Leaf records (a balance, a journal line, an account) sit on one line each.
                out.append("{ ")
                for (i, f) in fields.enumerated() {
                    if i > 0 { out.append(", ") }
                    out.append(JSONValue.quote(f.key) + ": ")
                    f.value.write(&out, indent: indent)
                }
                out.append(" }")
            } else {
                out.append("{\n")
                for (i, f) in fields.enumerated() {
                    out.append(pad + JSONValue.quote(f.key) + ": ")
                    f.value.write(&out, indent: indent + 1)
                    out.append(i < fields.count - 1 ? ",\n" : "\n")
                }
                out.append(closePad + "}")
            }
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                if u.value < 0x20 {
                    out.append(String(format: "\\u%04x", u.value))
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out.append("\"")
        return out
    }

    /// Converts a `JSONSerialization` tree. Object keys come back sorted because the parser doesn't keep order.
    static func from(any: Any) -> JSONValue {
        if any is NSNull { return .null }
        if let s = any as? String { return .string(s) }
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .raw(n.stringValue)
        }
        if let a = any as? [Any] { return .array(a.map { from(any: $0) }) }
        if let d = any as? [String: Any] {
            return .object(d.keys.sorted().map { JSONField($0, from(any: d[$0]!)) })
        }
        return .null
    }
}

/// Typed access to a parsed JSON object, with error messages that say where the problem is.
struct JSONObject {
    let dict: [String: Any]
    let path: String

    init(_ any: Any?, _ path: String) throws {
        guard let d = any as? [String: Any] else { throw TBError("\(path): expected an object.") }
        self.dict = d
        self.path = path
    }

    func string(_ key: String) throws -> String {
        guard let s = dict[key] as? String else { throw TBError("\(path): missing text field “\(key)”.") }
        return s
    }

    func optString(_ key: String, default def: String = "") -> String {
        (dict[key] as? String) ?? def
    }

    func optStringOrNil(_ key: String) -> String? {
        guard let s = dict[key] as? String, !s.isEmpty else { return nil }
        return s
    }

    func int(_ key: String) -> Int? {
        guard let n = dict[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.intValue
    }

    func money(_ key: String) throws -> Money {
        guard let v = dict[key], !(v is NSNull) else { return .zero }
        if let s = v as? String {
            guard let p = Money.parse(s) else { throw TBError("\(path): “\(key)” is not an amount (\(s)).") }
            return p.value
        }
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            return Money(double: n.doubleValue)
        }
        throw TBError("\(path): “\(key)” is not an amount.")
    }

    func array(_ key: String) -> [Any] {
        (dict[key] as? [Any]) ?? []
    }
}
