import Foundation

public enum Basis: String, CaseIterable, Sendable {
    case book, tax
    public var label: String { self == .book ? "Book" : "Tax" }
}

/// The columns of a single trial balance, left to right.
public enum EntityColumn: CaseIterable, Sendable {
    case unadjusted, aje, adjusted, rje, book, tje, tax

    public var title: String {
        switch self {
        case .unadjusted: return "Unadjusted"
        case .aje: return "AJE"
        case .adjusted: return "Adjusted"
        case .rje: return "RJE"
        case .book: return "Final (Book)"
        case .tje: return "TJE"
        case .tax: return "Tax Basis"
        }
    }
}

/// All balances of an engagement, computed once from the imported trial balances and the journal
/// entries. Nothing here is stored: every adjusted figure is derived from the source data each time.
///
///     adjusted = unadjusted + adjusting entries
///     book     = adjusted + reclassifying entries
///     tax      = book + tax-only entries
///     consolidated = sum of the entities (book or tax) + eliminating entries
public struct Ledger {
    public let engagement: Engagement

    private struct Key: Hashable {
        let entity: String
        let account: String
    }

    private var unadjusted: [Key: Int64] = [:]
    private var posted: [JEType: [Key: Int64]] = [:]
    private var activeByEntity: [String: Set<String>] = [:]
    private var prior: [Int: [Key: PriorBalance]] = [:]
    /// Accounts with a balance row or a journal line anywhere in the engagement.
    public private(set) var activeAccounts: Set<String> = []
    /// Prior years that have balances, most recent first (see `Engagement.priorYears`).
    public let priorYears: [Int]

    public init(_ e: Engagement) {
        engagement = e
        priorYears = e.priorYears
        let shownYears = Set(priorYears)
        for ent in e.entities {
            for b in ent.balances {
                unadjusted[Key(entity: ent.id, account: b.account), default: 0] += b.amount.cents
                activeByEntity[ent.id, default: []].insert(b.account)
                activeAccounts.insert(b.account)
            }
            for period in ent.priorPeriods where shownYears.contains(period.year) {
                for b in period.balances where !b.isZero {
                    let k = Key(entity: ent.id, account: b.account)
                    if var have = prior[period.year]?[k] {
                        have.book += b.book
                        have.tax += b.tax
                        have.elim += b.elim
                        prior[period.year]![k] = have
                    } else {
                        prior[period.year, default: [:]][k] = b
                    }
                    activeByEntity[ent.id, default: []].insert(b.account)
                    activeAccounts.insert(b.account)
                }
            }
        }
        for je in e.journalEntries where !je.pending {
            for l in je.lines {
                posted[je.type, default: [:]][Key(entity: l.entity, account: l.account), default: 0] += l.amount.cents
                activeAccounts.insert(l.account)
                if je.type != .eliminating {
                    activeByEntity[l.entity, default: []].insert(l.account)
                }
            }
        }
    }

    public func activeAccounts(in entityID: String) -> Set<String> {
        activeByEntity[entityID] ?? []
    }

    public func posted(_ type: JEType, entity: String, account: String) -> Money {
        Money(cents: posted[type]?[Key(entity: entity, account: account)] ?? 0)
    }

    public func value(_ column: EntityColumn, entity: String, account: String) -> Money {
        let k = Key(entity: entity, account: account)
        let u = unadjusted[k] ?? 0
        let a = posted[.adjusting]?[k] ?? 0
        let r = posted[.reclassifying]?[k] ?? 0
        let t = posted[.taxOnly]?[k] ?? 0
        switch column {
        case .unadjusted: return Money(cents: u)
        case .aje: return Money(cents: a)
        case .adjusted: return Money(cents: u + a)
        case .rje: return Money(cents: r)
        case .book: return Money(cents: u + a + r)
        case .tje: return Money(cents: t)
        case .tax: return Money(cents: u + a + r + t)
        }
    }

    public func balance(_ basis: Basis, entity: String, account: String) -> Money {
        value(basis == .book ? .book : .tax, entity: entity, account: account)
    }

    public func combined(_ basis: Basis, account: String) -> Money {
        engagement.entities.map { balance(basis, entity: $0.id, account: account) }.sum()
    }

    public func eliminations(account: String) -> Money {
        engagement.entities.map { posted(.eliminating, entity: $0.id, account: account) }.sum()
    }

    public func consolidated(_ basis: Basis, account: String) -> Money {
        combined(basis, account: account) + eliminations(account: account)
    }

    // MARK: Prior years

    /// One trial balance's closing balance in a prior year (before eliminations).
    public func prior(_ basis: Basis, year: Int, entity: String, account: String) -> Money {
        guard let b = prior[year]?[Key(entity: entity, account: account)] else { return .zero }
        return basis == .book ? b.book : b.tax
    }

    public func priorEliminations(year: Int, account: String) -> Money {
        engagement.entities.map { prior[year]?[Key(entity: $0.id, account: account)]?.elim ?? .zero }.sum()
    }

    public func priorConsolidated(_ basis: Basis, year: Int, account: String) -> Money {
        engagement.entities.map { prior(basis, year: year, entity: $0.id, account: account) }.sum()
            + priorEliminations(year: year, account: account)
    }

    /// Income is positive. Sum of the revenue and expense accounts, sign flipped.
    public func netIncome(_ column: EntityColumn, entity: String) -> Money {
        -engagement.accounts.filter { $0.type.isIncomeStatement }
            .map { value(column, entity: entity, account: $0.id) }.sum()
    }

    public func consolidatedNetIncome(_ basis: Basis) -> Money {
        -engagement.accounts.filter { $0.type.isIncomeStatement }
            .map { consolidated(basis, account: $0.id) }.sum()
    }

    /// Zero when the entity's debits equal its credits in that column.
    public func total(_ column: EntityColumn, entity: String) -> Money {
        engagement.accounts.map { value(column, entity: entity, account: $0.id) }.sum()
    }

    public func eliminationsTotal() -> Money {
        engagement.accounts.map { eliminations(account: $0.id) }.sum()
    }

    public func consolidatedTotal(_ basis: Basis) -> Money {
        engagement.accounts.map { consolidated(basis, account: $0.id) }.sum()
    }
}
