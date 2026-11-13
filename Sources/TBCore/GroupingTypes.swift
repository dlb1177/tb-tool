import Foundation

/// A grouping whose accounts don't all have the account type the grouping calls for.
public struct GroupingTypeConflict: Equatable, Identifiable, Sendable {
    /// The grouping (never a subgroup: a subgroup's accounts are listed under its grouping).
    public var groupingID: String
    public var groupingType: AccountType
    /// Every account in the grouping and its subgroups.
    public var accounts: [Account]
    /// The ones whose type differs from the grouping's.
    public var mismatched: [Account]

    public var id: String { groupingID }
}

/// How one conflict is settled: one type for the grouping and everything in it.
public struct GroupingTypeResolution: Equatable, Sendable {
    /// The type the grouping and its accounts will have.
    public var type: AccountType
    /// Accounts to take out of the grouping instead (they keep their own type and become ungrouped).
    public var ungroup: Set<String>

    public init(type: AccountType, ungroup: Set<String> = []) {
        self.type = type
        self.ungroup = ungroup
    }
}

extension Engagement {

    /// The account type a grouping calls for: its own, or for a subgroup its grouping's. Nil means any.
    public func groupingType(_ id: String?) -> AccountType? {
        guard let g = grouping(id) else { return nil }
        if let p = parentGrouping(of: g) { return p.type }
        return g.type
    }

    /// The top-level grouping an account's grouping rolls up to.
    private func topGrouping(_ id: String?) -> Grouping? {
        guard let g = grouping(id) else { return nil }
        return parentGrouping(of: g) ?? g
    }

    /// Groupings holding accounts of another type than the grouping's, in list order.
    public var typeConflicts: [GroupingTypeConflict] {
        var members: [String: [Account]] = [:]
        for a in sortedAccounts {
            if let top = topGrouping(a.grouping) { members[top.id, default: []].append(a) }
        }
        return groupingOutline.compactMap { item in
            guard item.depth == 0, let type = item.grouping.type, let accounts = members[item.grouping.id] else { return nil }
            let off = accounts.filter { $0.type != type }
            return off.isEmpty ? nil : GroupingTypeConflict(groupingID: item.grouping.id, groupingType: type, accounts: accounts, mismatched: off)
        }
    }

    /// Settles conflicts, by grouping id: the grouping and every account in it (and in its
    /// subgroups) take the chosen type, except accounts that are taken out of the grouping instead.
    /// Returns how many accounts changed type.
    @discardableResult
    public mutating func resolveTypeConflicts(_ resolutions: [String: GroupingTypeResolution]) -> Int {
        var changed = 0
        for (id, r) in resolutions {
            guard let gi = groupings.firstIndex(where: { $0.id == id }), groupings[gi].parent == nil else { continue }
            groupings[gi].type = r.type
            let inside = Set([id] + subgroups(of: id).map(\.id))
            for i in accounts.indices {
                guard let g = accounts[i].grouping, inside.contains(g) else { continue }
                if r.ungroup.contains(accounts[i].id) {
                    accounts[i].grouping = nil
                } else if accounts[i].type != r.type {
                    accounts[i].type = r.type
                    changed += 1
                }
            }
        }
        return changed
    }

    /// Gives accounts the type their grouping calls for. Returns how many changed.
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
