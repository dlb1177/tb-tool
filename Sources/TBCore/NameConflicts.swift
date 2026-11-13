import Foundation

/// An account in a file being imported whose number is already in the chart under a different
/// name. The person importing decides which name is right — or that it is a different account.
public struct AccountNameConflict: Equatable, Identifiable, Sendable {
    /// The account as the chart has it.
    public var accountID: String
    public var number: String
    public var chartName: String
    /// The name the file gives that number.
    public var fileName: String
    /// The chart account's grouping, if it has one.
    public var grouping: String?
    /// Trial balances that already use the account (by name).
    public var usedBy: [String]
    /// What the file brings in for it.
    public var amount: Money

    public var id: String { accountID }
}

public enum AccountNameChoice: Equatable, Sendable {
    /// Same account; the chart's name stands.
    case keepChartName
    /// Same account; the chart takes the file's name (for every trial balance).
    case useFileName
    /// Not the same account: bring it in under another number (or, with no number, by its name).
    case separateAccount(number: String)
}

public struct AccountNameResolution: Equatable, Sendable {
    public var choice: AccountNameChoice
    /// For the same account: keep its grouping (otherwise it goes back to ungrouped, to be looked at again).
    /// For a separate account: start it with the original's grouping (otherwise ungrouped).
    public var keepGrouping: Bool

    public init(_ choice: AccountNameChoice = .keepChartName, keepGrouping: Bool = true) {
        self.choice = choice
        self.keepGrouping = keepGrouping
    }
}

/// What one resolved conflict leaves in the chart: shown as the preview before importing.
public struct AccountNameOutcome: Equatable, Sendable {
    public var number: String
    public var name: String
    public var grouping: String?
    /// True when a new account is added beside the one already in the chart.
    public var isNew: Bool
    /// Why this choice can't be imported as it stands (a number that is taken, say). Nil when it can.
    public var problem: String?
}

extension Engagement {

    /// Accounts in an imported file whose number is in the chart under a different name. A
    /// difference only in capitals or spacing doesn't count.
    public func accountNameConflicts(in tb: ImportedTB) -> [AccountNameConflict] {
        var out: [AccountNameConflict] = []
        var at: [String: Int] = [:]
        for row in tb.rows where !row.number.isEmpty {
            guard let existing = account(row.number), Engagement.namesDiffer(existing.name, row.name) else { continue }
            if let i = at[existing.id] {
                out[i].amount += row.amount
                continue
            }
            at[existing.id] = out.count
            let users = entities.filter { ent in
                ent.balances.contains { $0.account == existing.id } || ent.priorPeriods.contains { $0.balances.contains { $0.account == existing.id } }
                    || journalEntries.contains { $0.lines.contains { $0.entity == ent.id && $0.account == existing.id } }
            }.map(\.name)
            out.append(AccountNameConflict(accountID: existing.id, number: existing.number, chartName: existing.name, fileName: row.name,
                                           grouping: grouping(existing.grouping)?.id, usedBy: users, amount: row.amount))
        }
        return out
    }

    static func namesDiffer(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return norm(a) != norm(b)
    }

    /// What a resolution would leave in the chart, without changing anything.
    public func outcome(of resolution: AccountNameResolution, for conflict: AccountNameConflict) -> AccountNameOutcome {
        switch resolution.choice {
        case .keepChartName:
            return AccountNameOutcome(number: conflict.number, name: conflict.chartName, grouping: resolution.keepGrouping ? conflict.grouping : nil,
                                      isNew: false, problem: nil)
        case .useFileName:
            return AccountNameOutcome(number: conflict.number, name: conflict.fileName, grouping: resolution.keepGrouping ? conflict.grouping : nil,
                                      isNew: false, problem: nil)
        case .separateAccount(let raw):
            let number = raw.trimmed
            let id = number.isEmpty ? conflict.fileName : number
            var problem: String?
            if number == conflict.number {
                problem = "Give it a number other than \(conflict.number), or leave the number blank to keep it by name."
            } else if let taken = account(id), Engagement.namesDiffer(taken.name, conflict.fileName) {
                problem = number.isEmpty ? "“\(id)” is already an account in the chart." : "\(number) is already “\(taken.name)” in the chart."
            }
            return AccountNameOutcome(number: number, name: conflict.fileName, grouping: resolution.keepGrouping ? conflict.grouping : nil,
                                      isNew: account(id) == nil, problem: problem)
        }
    }

    /// Applies the decisions to the chart and to the rows about to be imported. Numbers with no
    /// decision are left for the import's default (the chart's name is kept, with a note).
    /// Also returns the accounts that will come in as separate accounts, with the grouping each starts with.
    mutating func resolveNameConflicts(_ resolutions: [String: AccountNameResolution],
                                       in tb: ImportedTB) throws -> (tb: ImportedTB, separate: [(id: String, grouping: String?)]) {
        guard !resolutions.isEmpty else { return (tb, []) }
        var out = tb
        var regroup: [(id: String, grouping: String?)] = []
        for conflict in accountNameConflicts(in: tb) {
            guard let resolution = resolutions[conflict.accountID] else { continue }
            let result = outcome(of: resolution, for: conflict)
            if let problem = result.problem { throw TBError("Account \(conflict.number): \(problem)") }
            switch resolution.choice {
            case .keepChartName:
                // Rows take the chart's name so the import sees no difference left to report.
                for i in out.rows.indices where out.rows[i].number == conflict.number { out.rows[i].name = conflict.chartName }
                if !resolution.keepGrouping { updateAccount(conflict.accountID) { $0.grouping = nil } }
            case .useFileName:
                updateAccount(conflict.accountID) {
                    $0.name = conflict.fileName
                    if !resolution.keepGrouping { $0.grouping = nil }
                }
            case .separateAccount:
                for i in out.rows.indices where out.rows[i].number == conflict.number && !Engagement.namesDiffer(out.rows[i].name, conflict.fileName) {
                    out.rows[i].number = result.number
                }
                if result.isNew { regroup.append((result.number.isEmpty ? conflict.fileName : result.number, result.grouping)) }
            }
        }
        return (out, regroup)
    }
}

extension Engagement {
    /// A free account number to offer when a conflicting account is brought in as a separate one:
    /// the next unused number after it, or the number with "-2" when it isn't a plain number.
    public func suggestedSeparateNumber(for number: String) -> String {
        if let n = Int(number), !number.hasPrefix("0") {
            for step in 1...50 where account(String(n + step)) == nil { return String(n + step) }
        }
        var k = 2
        while account("\(number)-\(k)") != nil { k += 1 }
        return "\(number)-\(k)"
    }
}
