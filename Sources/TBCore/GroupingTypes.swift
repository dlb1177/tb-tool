import Foundation

// An account's type is not chosen on the account. It comes from the account's grouping: every
// grouping says what type of account belongs in it, and an account put there has that type.
// Everything that touches a grouping or an account's grouping goes through here, so the two
// cannot disagree. An account with no grouping yet (or in an "any type" grouping) keeps the type
// guessed from its number or name when it was imported, until it is grouped.

extension Engagement {

    /// The account type a grouping gives its accounts: its own, or for a subgroup its grouping's.
    /// Nil means the grouping takes any type.
    public func groupingType(_ id: String?) -> AccountType? {
        guard let g = grouping(id) else { return nil }
        if let p = parentGrouping(of: g) { return p.type }
        return g.type
    }

    /// Gives the named accounts the type of their grouping. Returns how many changed.
    @discardableResult
    mutating func alignTypes(ofAccounts ids: Set<String>) -> Int {
        var changed = 0
        for i in accounts.indices where ids.contains(accounts[i].id) {
            if let type = groupingType(accounts[i].grouping), accounts[i].type != type {
                accounts[i].type = type
                changed += 1
            }
        }
        return changed
    }

    /// Gives every account the type of its grouping. Run whenever the grouping list changes as a
    /// whole and when a file is opened, so a file edited by hand or written by an earlier version
    /// comes out consistent. Returns how many accounts changed.
    @discardableResult
    public mutating func alignAccountTypes() -> Int {
        alignTypes(ofAccounts: Set(accounts.map(\.id)))
    }

    /// For lists written before groupings had account types: a grouping that is in the built-in
    /// list (same id and code) takes the built-in type. Others are left as "any type".
    public static func fillingStandardTypes(_ list: [Grouping]) -> [Grouping] {
        let standard = Dictionary(DefaultGroupings.list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return list.map { g in
            guard g.type == nil, g.parent == nil, let s = standard[g.id], s.parent == nil,
                  s.code.caseInsensitiveCompare(g.code) == .orderedSame else { return g }
            var x = g
            x.type = s.type
            return x
        }
    }
}
