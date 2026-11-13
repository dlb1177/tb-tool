import Foundation

public struct RollForwardOptions: Equatable, Sendable {
    public enum Opening: Equatable, Sendable {
        /// The new year starts with no balances; import the new year's trial balance into each one.
        case empty
        /// Balance sheet accounts open at last year's final (book) balance. Income and expense
        /// accounts start at zero, closed into the named equity account.
        case carryBalanceSheet(closeInto: String)
    }

    public var opening: Opening = .empty
    /// How many prior years the new file keeps, counting the year being closed.
    public var keepPriorYears = 5
    /// Carry the workpaper links of entries that roll forward. Off by default: they point at last year's files.
    public var keepLinks = false
    /// The file being rolled forward, recorded in the new file.
    public var sourceName = ""

    public init() {}
}

public struct RollForwardSummary: Equatable, Sendable {
    public var fromYear: Int
    public var toYear: Int
    public var newPeriodEnd: String
    public var withAmounts: [JournalEntry] = []
    public var withoutAmounts: [JournalEntry] = []
    /// Entries that roll forward with debits and credits swapped.
    public var reversed: [JournalEntry] = []
    public var notRolled: [JournalEntry] = []

    /// "2 with amounts · 1 as a reversal · 3 left behind" — only the kinds that occur.
    public var entryCounts: String {
        var parts: [String] = []
        if !withAmounts.isEmpty { parts.append("\(withAmounts.count) with amounts") }
        if !withoutAmounts.isEmpty { parts.append("\(withoutAmounts.count) without amounts") }
        if !reversed.isEmpty { parts.append("\(reversed.count) as a reversal") }
        parts.append("\(notRolled.count) left behind")
        return parts.joined(separator: " · ")
    }
}

extension Engagement {

    /// What a roll forward would do with the entries, without doing it.
    public func rollForwardSummary() throws -> RollForwardSummary {
        guard let year = currentYear, let next = Timestamp.day(periodEnd, addingYears: 1) else {
            throw TBError("Set the year end in Trial Balance Settings before rolling forward.")
        }
        var s = RollForwardSummary(fromYear: year, toYear: year + 1, newPeriodEnd: next)
        for je in Reports(self).sortedEntries() {
            switch je.rollForward {
            case .withAmounts: je.pending ? s.withoutAmounts.append(je) : s.withAmounts.append(je)
            case .withoutAmounts: s.withoutAmounts.append(je)
            // An entry still waiting for amounts posted nothing, so there is nothing to reverse.
            case .reversal: je.pending ? s.notRolled.append(je) : s.reversed.append(je)
            case .none: s.notRolled.append(je)
            }
        }
        return s
    }

    /// Next year's file. This year's final balances (book, tax, and eliminations) become prior year
    /// PP1; older prior years move back one. The chart, groupings and binder details carry over.
    /// Journal entries carry over only as each one is marked: with amounts, without, as a reversal,
    /// or not at all. A reversal is dated the first day of the new year, has every debit and credit
    /// swapped, starts each line's memo with "[Reversal from 2026]", and is not marked to roll again.
    /// The file being rolled forward is not changed.
    public func rolledForward(_ options: RollForwardOptions = RollForwardOptions()) throws -> Engagement {
        let summary = try rollForwardSummary()
        let ledger = Ledger(self)
        var next = self
        next.periodEnd = summary.newPeriodEnd
        next.rolledForwardFrom = options.sourceName
        next.binder.engagement = binder.engagement.replacingOccurrences(of: String(summary.fromYear), with: String(summary.toYear))
        let chart = sortedAccounts
        let typeByID = accountTypes

        var closeInto: String?
        if case .carryBalanceSheet(let id) = options.opening {
            guard let target = account(id), !target.type.isIncomeStatement else {
                throw TBError("Choose the equity account that income and expenses close into.")
            }
            closeInto = id
        }

        for i in next.entities.indices {
            let id = entities[i].id
            var closing = PriorPeriod(year: summary.fromYear)
            closing.source = options.sourceName.isEmpty ? "Rolled forward" : "Rolled forward from \(options.sourceName)"
            closing.importedAt = Timestamp.now()
            for a in chart {
                let b = PriorBalance(account: a.id, book: ledger.value(.book, entity: id, account: a.id),
                                     tax: ledger.value(.tax, entity: id, account: a.id),
                                     elim: ledger.posted(.eliminating, entity: id, account: a.id))
                if !b.isZero { closing.balances.append(b) }
            }
            let older = entities[i].priorPeriods.filter { $0.year < summary.fromYear }.sorted { $0.year > $1.year }
            next.entities[i].priorPeriods = Array(([closing] + older).prefix(max(1, options.keepPriorYears)))

            var opening: [Balance] = []
            if let closeInto {
                var income = Money.zero
                var equity = Money.zero
                for a in chart {
                    let v = ledger.value(.book, entity: id, account: a.id)
                    if typeByID[a.id]?.isIncomeStatement == true {
                        income += v
                    } else if a.id == closeInto {
                        equity = v
                    } else if !v.isZero {
                        opening.append(Balance(account: a.id, amount: v))
                    }
                }
                if !(equity + income).isZero { opening.append(Balance(account: closeInto, amount: equity + income)) }
                let order = Dictionary(chart.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
                opening.sort { (order[$0.account] ?? 0) < (order[$1.account] ?? 0) }
            }
            next.entities[i].balances = opening
            next.entities[i].source = opening.isEmpty ? "" : "Opening balances carried forward from \(summary.fromYear)"
            next.entities[i].importedAt = opening.isEmpty ? "" : Timestamp.now()
            next.entities[i].editedAt = ""
        }

        next.journalEntries = []
        for je in summary.withAmounts + summary.withoutAmounts {
            var copy = JournalEntry(number: je.number, type: je.type,
                                    date: Timestamp.day(je.date, addingYears: 1) ?? summary.newPeriodEnd,
                                    description: je.description, lines: je.lines,
                                    references: options.keepLinks ? je.references : [])
            copy.rollForward = je.rollForward
            if je.rollForward == .withoutAmounts || je.pending {
                for j in copy.lines.indices { copy.lines[j].amount = .zero }
                copy.pending = true
            }
            next.journalEntries.append(copy)
        }
        let tag = "[Reversal from \(summary.fromYear)]"
        for je in summary.reversed {
            var copy = JournalEntry(number: je.number, type: je.type,
                                    date: Timestamp.day(periodEnd, addingDays: 1) ?? summary.newPeriodEnd,
                                    description: je.description,
                                    lines: je.lines.map { l in
                                        JELine(entity: l.entity, account: l.account, amount: -l.amount,
                                               memo: l.memo.trimmed.isEmpty ? tag : "\(tag) \(l.memo.trimmed)")
                                    },
                                    references: options.keepLinks ? je.references : [])
            copy.rollForward = .none
            next.journalEntries.append(copy)
        }
        return next
    }

    /// A file name for the rolled-forward year: the year in the current name moved on, or appended.
    public static func rolledFileName(_ name: String, from: Int, to: Int) -> String {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension.isEmpty ? "json" : (name as NSString).pathExtension
        let moved = stem.contains(String(from)) ? stem.replacingOccurrences(of: String(from), with: String(to)) : "\(stem) \(to)"
        return "\(moved).\(ext)"
    }
}
