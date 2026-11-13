import Foundation

/// One rule of a custom filter: a column, a test, and the value(s) to test against.
public struct FilterCondition: Equatable, Codable, Identifiable, Sendable {
    public enum Op: String, Codable, CaseIterable, Sendable {
        // Text
        case contains, notContains, equals, notEquals, startsWith, isEmpty, notEmpty
        // Amounts. Sizes ignore the sign: "at least 10,000" finds debits and credits of 10,000 or more.
        case atLeast, atMost, between, amountEquals, isZero, notZero, isDebit, isCredit

        public var label: String {
            switch self {
            case .contains: return "contains"
            case .notContains: return "doesn't contain"
            case .equals: return "is exactly"
            case .notEquals: return "is not"
            case .startsWith: return "starts with"
            case .isEmpty: return "is blank"
            case .notEmpty: return "isn't blank"
            case .atLeast: return "is at least"
            case .atMost: return "is at most"
            case .between: return "is between"
            case .amountEquals: return "equals"
            case .isZero: return "is zero"
            case .notZero: return "isn't zero"
            case .isDebit: return "is a debit"
            case .isCredit: return "is a credit"
            }
        }

        public var needsValue: Bool {
            switch self {
            case .isEmpty, .notEmpty, .isZero, .notZero, .isDebit, .isCredit: return false
            default: return true
            }
        }

        public var isAmountTest: Bool {
            switch self {
            case .atLeast, .atMost, .between, .amountEquals, .isZero, .notZero, .isDebit, .isCredit: return true
            default: return false
            }
        }

        public static let textOps: [Op] = [.contains, .notContains, .equals, .notEquals, .startsWith, .isEmpty, .notEmpty]
        /// The tests offered for a column with a fixed list of values, such as the account type.
        public static let choiceOps: [Op] = [.equals, .notEquals]
        public static let amountOps: [Op] = [.atLeast, .atMost, .between, .amountEquals, .notZero, .isZero, .isDebit, .isCredit]
    }

    /// The filter "column" for an account's type (asset, liability, equity, revenue, expense). It
    /// works on every table whose rows are accounts, whether or not the type is shown as a column.
    public static let accountTypeColumn = "Account Type"

    public var id = UUID()
    /// Column title. Empty means any column (text tests only).
    public var column: String
    public var op: Op
    public var value: String
    public var value2: String

    public init(column: String = "", op: Op = .contains, value: String = "", value2: String = "") {
        self.column = column
        self.op = op
        self.value = value
        self.value2 = value2
    }

    /// A rule still being typed (no value yet) doesn't filter anything.
    public var isComplete: Bool {
        guard op.needsValue else { return true }
        if op.isAmountTest {
            guard Money.parse(value) != nil, !value.trimmed.isEmpty else { return false }
            return op != .between || (Money.parse(value2) != nil && !value2.trimmed.isEmpty)
        }
        return !value.trimmed.isEmpty
    }

    public var summary: String {
        let name = column.isEmpty ? "Any column" : column
        guard op.needsValue else { return "\(name) \(op.label)" }
        return op == .between ? "\(name) \(op.label) \(value) and \(value2)" : "\(name) \(op.label) \(value)"
    }

    func matches(_ cell: ReportCell) -> Bool {
        if op.isAmountTest {
            let amount: Money
            switch cell {
            case .money(let m): amount = m
            case .text(let s):
                guard !s.trimmed.isEmpty, let p = Money.parse(s) else { return false }
                amount = p.value
            case .empty: amount = .zero
            }
            let size = abs(amount.cents)
            func magnitude(_ text: String) -> Int64 { abs(Money.parse(text)?.value.cents ?? 0) }
            switch op {
            case .atLeast: return size >= magnitude(value)
            case .atMost: return size <= magnitude(value)
            case .between:
                let a = magnitude(value), b = magnitude(value2)
                return size >= min(a, b) && size <= max(a, b)
            case .amountEquals: return size == magnitude(value)
            case .isZero: return amount.isZero
            case .notZero: return !amount.isZero
            case .isDebit: return amount.cents > 0
            case .isCredit: return amount.cents < 0
            default: return true
            }
        }
        let text: String
        switch cell {
        case .empty: text = ""
        case .text(let s): text = s.trimmed.lowercased()
        case .money(let m): text = m.isZero ? "" : "\(m.plain) \(m.grouped) \(m.formatted)"
        }
        let v = value.trimmed.lowercased()
        switch op {
        case .contains: return text.contains(v)
        case .notContains: return !text.contains(v)
        case .equals:
            if case .money(let m) = cell { return Money.parse(value)?.value == m }
            return text == v
        case .notEquals:
            if case .money(let m) = cell { return Money.parse(value)?.value != m }
            return text != v
        case .startsWith: return text.hasPrefix(v)
        case .isEmpty: return text.isEmpty
        case .notEmpty: return !text.isEmpty
        default: return true
        }
    }

    private enum CodingKeys: String, CodingKey { case column, op, value, value2 }
}

/// A custom filter: rules joined by "all of" or "any of". Saved by name per screen.
public struct FilterSet: Equatable, Codable, Sendable {
    public var matchAll = true
    public var conditions: [FilterCondition] = []

    public init(matchAll: Bool = true, conditions: [FilterCondition] = []) {
        self.matchAll = matchAll
        self.conditions = conditions
    }

    public var active: [FilterCondition] { conditions.filter(\.isComplete) }
    public var isActive: Bool { !active.isEmpty }

    public var summary: String {
        active.map(\.summary).joined(separator: matchAll ? " and " : " or ")
    }

    /// `cell` returns the cell under a column title; `all` is every cell of the row (for "any column").
    public func matches(cell: (String) -> ReportCell?, all: [ReportCell]) -> Bool {
        let rules = active
        guard !rules.isEmpty else { return true }
        func test(_ c: FilterCondition) -> Bool {
            if c.column.isEmpty {
                // "Doesn't contain" over any column means no column contains it.
                if c.op == .notContains || c.op == .notEquals || c.op == .isEmpty { return all.allSatisfy { c.matches($0) } }
                return all.contains { c.matches($0) }
            }
            guard let value = cell(c.column) else { return true }  // a rule for a column this table doesn't have
            return c.matches(value)
        }
        return matchAll ? rules.allSatisfy(test) : rules.contains(where: test)
    }
}

/// Named filters remembered per screen (in the app's preferences, not in the trial balance file).
public struct SavedFilter: Equatable, Codable, Identifiable, Sendable {
    public var name: String
    public var filter: FilterSet
    public var id: String { name }

    public init(name: String, filter: FilterSet) {
        self.name = name
        self.filter = filter
    }
}
