import Foundation

/// An exact amount of money, held as integer cents so sums never drift.
/// Sign convention everywhere in the engine: debit is positive, credit is negative.
public struct Money: Hashable, Comparable, CustomStringConvertible, Sendable {
    public var cents: Int64

    public init(cents: Int64) { self.cents = cents }
    public init(double: Double) { self.cents = Int64((double * 100).rounded()) }

    public static let zero = Money(cents: 0)

    public var isZero: Bool { cents == 0 }
    public var debit: Money { cents > 0 ? self : .zero }
    public var credit: Money { cents < 0 ? Money(cents: -cents) : .zero }
    public var doubleValue: Double { Double(cents) / 100 }

    public static func < (a: Money, b: Money) -> Bool { a.cents < b.cents }
    public static func + (a: Money, b: Money) -> Money { Money(cents: a.cents + b.cents) }
    public static func - (a: Money, b: Money) -> Money { Money(cents: a.cents - b.cents) }
    public static prefix func - (a: Money) -> Money { Money(cents: -a.cents) }
    public static func += (a: inout Money, b: Money) { a.cents += b.cents }
    public static func -= (a: inout Money, b: Money) { a.cents -= b.cents }

    /// Machine-readable: `-1234.50`
    public var plain: String {
        let a = abs(cents)
        let frac = a % 100
        return (cents < 0 ? "-" : "") + "\(a / 100)." + (frac < 10 ? "0\(frac)" : "\(frac)")
    }

    /// Thousands separators, no sign: `1,234.50`
    public var grouped: String {
        let a = abs(cents)
        let whole = String(a / 100)
        var out = ""
        for (i, ch) in whole.enumerated() {
            if i > 0 && (whole.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        let frac = a % 100
        return out + "." + (frac < 10 ? "0\(frac)" : "\(frac)")
    }

    /// Accounting presentation: credits in parentheses.
    public var formatted: String { cents < 0 ? "(\(grouped))" : grouped }

    public var description: String { plain }

    public struct ParseResult: Equatable {
        public var value: Money
        /// True when the text carried more than two decimals and had to be rounded.
        public var rounded: Bool
    }

    /// Parses `1,234.56`, `(1,234.56)`, `-1234.5`, `$ 1,234`, `1234.56-`. Empty text and a lone dash are zero.
    /// Returns nil when the text is not a number.
    public static func parse(_ raw: String) -> ParseResult? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var negative = false
        if s.hasPrefix("(") && s.hasSuffix(")") {
            negative = true
            s = String(s.dropFirst().dropLast())
        }
        s = s.replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: " ", with: "")
        if s.isEmpty || s == "-" { return ParseResult(value: .zero, rounded: false) }
        if s.hasPrefix("-") {
            negative.toggle()
            s.removeFirst()
        } else if s.hasSuffix("-") {
            negative.toggle()
            s.removeLast()
        } else if s.hasPrefix("+") {
            s.removeFirst()
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let wholeText = String(parts[0])
        let fracText = parts.count == 2 ? String(parts[1]) : ""
        func isDigits(_ t: String) -> Bool { t.allSatisfy { $0 >= "0" && $0 <= "9" } }
        guard isDigits(wholeText), isDigits(fracText), !(wholeText.isEmpty && fracText.isEmpty) else { return nil }
        guard wholeText.count <= 14, let whole = Int64(wholeText.isEmpty ? "0" : wholeText) else { return nil }
        let frac = fracText.map { Int64($0.asciiValue! - 48) }
        var c = whole * 100
        if frac.count > 0 { c += frac[0] * 10 }
        if frac.count > 1 { c += frac[1] }
        var rounded = false
        if frac.count > 2 {
            if frac[2...].contains(where: { $0 != 0 }) { rounded = true }
            if frac[2] >= 5 { c += 1 }
        }
        return ParseResult(value: Money(cents: negative ? -c : c), rounded: rounded)
    }
}

extension Sequence where Element == Money {
    public func sum() -> Money { reduce(.zero, +) }
}
