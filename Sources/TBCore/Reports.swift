import Foundation

public struct ReportColumn: Equatable, Sendable {
    public enum Kind: Sendable { case text, money }
    public var title: String
    public var kind: Kind
    public var width: Double

    public static func text(_ title: String, _ width: Double) -> ReportColumn {
        ReportColumn(title: title, kind: .text, width: width)
    }
    public static func money(_ title: String) -> ReportColumn {
        ReportColumn(title: title, kind: .money, width: 118)
    }
}

public enum ReportCell: Equatable, Sendable {
    case empty
    case text(String)
    case money(Money)
}

public struct ReportRow: Identifiable, Equatable, Sendable {
    public enum Style: Sendable { case normal, section, subtotal, total }
    public var id: String
    public var cells: [ReportCell]
    public var style: Style = .normal
    /// Set on rows that stand for one account, so the app can drill into its activity.
    public var accountID: String? = nil
    public var entityID: String? = nil
    public var entryID: String? = nil
    /// Set on rows that stand for a grouping or subgroup, so the app can open the accounts inside it.
    public var groupingID: String? = nil
    /// The type of the row's account. Filters can test it even though no column shows it.
    public var accountType: AccountType? = nil
    /// Set on a row whose amounts are already inside another row of the table (a subgroup under
    /// its grouping), so a total of the rows shown doesn't count them twice.
    public var parentRowID: String? = nil
}

/// A finished report: what the app shows on screen and what every export format is written from.
public struct ReportTable: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var sheetName: String
    /// Flat tables are pure data (one header row, one record per row) and export without a title block.
    public var flat: Bool = false
    public var columns: [ReportColumn]
    public var rows: [ReportRow] = []
    /// The binder heading written above the columns in exports: client, report title, year end,
    /// engagement details, sign-off. Empty for flat tables.
    public var heading: [String] = []

    public init(title: String, subtitle: String, sheetName: String, flat: Bool = false, columns: [ReportColumn],
                rows: [ReportRow] = [], heading: [String] = []) {
        self.title = title
        self.subtitle = subtitle
        self.sheetName = sheetName
        self.flat = flat
        self.columns = columns
        self.rows = rows
        self.heading = heading
    }
}

public struct Reports {
    public let e: Engagement
    public let ledger: Ledger
    private let accounts: [Account]
    private let groupingByID: [String: Grouping]
    private let entityByID: [String: Entity]

    public init(_ engagement: Engagement) { self.init(ledger: Ledger(engagement)) }

    public init(ledger: Ledger) {
        self.ledger = ledger
        self.e = ledger.engagement
        self.accounts = e.sortedAccounts
        self.groupingByID = Dictionary(e.groupings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.entityByID = Dictionary(e.entities.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private var asOf: String { e.periodEnd.isEmpty ? e.name : "\(e.name) — as of \(e.periodEnd)" }

    /// The lines that head a report export, built from the binder details.
    public func heading(_ title: String) -> [String] {
        var lines = [e.name, title]
        if let day = Timestamp.longDay(e.periodEnd) { lines.append("Year ended \(day)") }
        let b = e.binder
        var detail: [String] = []
        if !b.clientNumber.isEmpty { detail.append("Client No. \(b.clientNumber)") }
        if !b.taxID.isEmpty { detail.append("Tax ID \(b.taxID)") }
        if !b.entityType.isEmpty { detail.append(b.entityType) }
        if !b.engagement.isEmpty { detail.append(b.engagement) }
        if !detail.isEmpty { lines.append(detail.joined(separator: "  ·  ")) }
        var signOff: [String] = []
        if !b.firm.isEmpty { signOff.append(b.firm) }
        if !b.preparedBy.isEmpty { signOff.append("Prepared by \(b.preparedBy)") }
        if !b.reviewedBy.isEmpty { signOff.append("Reviewed by \(b.reviewedBy)") }
        if !signOff.isEmpty { lines.append(signOff.joined(separator: "  ·  ")) }
        return lines
    }

    private func table(_ title: String, sheet: String, columns: [ReportColumn]) -> ReportTable {
        ReportTable(title: title, subtitle: asOf, sheetName: sheet, columns: columns, heading: heading(title))
    }

    /// The most recent `count` prior years, most recent first.
    private func years(_ count: Int) -> [Int] { Array(ledger.priorYears.prefix(max(0, count))) }

    private func priorColumns(_ years: [Int], basis: Basis, markTax: Bool) -> [ReportColumn] {
        guard !years.isEmpty else { return [] }
        return years.map { .money(e.priorLabel($0) + (markTax && basis == .tax ? " (Tax)" : "")) } + [.money("Change vs \(e.priorLabel(years[0]).split(separator: " ")[0])")]
    }
    private func code(_ a: Account) -> String { e.groupingCode(a.grouping) }
    private func add(_ a: inout [Money], _ b: [Money]) { for i in a.indices { a[i] += b[i] } }
    private func subtract(_ a: inout [Money], _ b: [Money]) { for i in a.indices { a[i] -= b[i] } }

    // MARK: One trial balance

    /// With `prior`, that many prior-year columns follow (PP1, PP2…) on `priorBasis`, then the
    /// change from PP1 to this year's balance on the same basis.
    public func entityTrialBalance(entityID: String, hideZero: Bool, prior: Int = 0, priorBasis: Basis = .book) -> ReportTable {
        let ent = entityByID[entityID]
        let columns = EntityColumn.allCases
        let years = years(prior)
        let activity = (ent?.activityNumber.isEmpty ?? true) ? "" : " (Activity \(ent!.activityNumber))"
        var t = table("\(ent?.name ?? entityID)\(activity) — Trial Balance", sheet: ent?.name ?? entityID,
                      columns: [.text("Account", 76), .text("Name", 260), .text("Grp", 60)]
                          + columns.map { .money($0.title) } + priorColumns(years, basis: priorBasis, markTax: true))
        let active = ledger.activeAccounts(in: entityID)
        var total = [Money](repeating: .zero, count: t.columns.count - 3)
        var income = total
        for a in accounts where active.contains(a.id) {
            var v = columns.map { ledger.value($0, entity: entityID, account: a.id) }
            if !years.isEmpty {
                let past = years.map { ledger.prior(priorBasis, year: $0, entity: entityID, account: a.id) }
                v += past + [ledger.balance(priorBasis, entity: entityID, account: a.id) - past[0]]
            }
            add(&total, v)
            if a.type.isIncomeStatement { subtract(&income, v) }
            if hideZero && v.allSatisfy(\.isZero) { continue }
            t.rows.append(ReportRow(id: "a:\(a.id)", cells: [.text(a.number), .text(a.name), .text(code(a))] + v.map { .money($0) },
                                    accountID: a.id, entityID: entityID, accountType: a.type))
        }
        t.rows.append(ReportRow(id: "total", cells: [.empty, .text("Total (zero when in balance)"), .empty] + total.map { .money($0) }, style: .total))
        t.rows.append(ReportRow(id: "income", cells: [.empty, .text("Net income (loss)"), .empty] + income.map { .money($0) }, style: .subtotal))
        return t
    }

    // MARK: Consolidation

    /// One value per entity, then Combined, Eliminations, Consolidated — then the consolidated
    /// balance of each prior year asked for and the change from the most recent one.
    private func consolidationVector(_ accountID: String, _ basis: Basis, _ years: [Int] = []) -> [Money] {
        let per = e.entities.map { ledger.balance(basis, entity: $0.id, account: accountID) }
        let combined = per.sum()
        let elim = ledger.eliminations(account: accountID)
        var v = per + [combined, elim, combined + elim]
        if !years.isEmpty {
            let past = years.map { ledger.priorConsolidated(basis, year: $0, account: accountID) }
            v += past + [combined + elim - past[0]]
        }
        return v
    }

    private func consolidationColumns(_ years: [Int], _ basis: Basis) -> [ReportColumn] {
        e.entities.map { .money($0.name) } + [.money("Combined"), .money("Eliminations"), .money("Consolidated")]
            + priorColumns(years, basis: basis, markTax: false)
    }

    public func consolidating(basis: Basis, hideZero: Bool, prior: Int = 0) -> ReportTable {
        let years = years(prior)
        var t = table("Consolidating Trial Balance — \(basis.label) Basis", sheet: basis == .book ? "Consolidated" : "Consolidated (Tax)",
                      columns: [.text("Account", 76), .text("Name", 260), .text("Grp", 60)] + consolidationColumns(years, basis))
        let width = t.columns.count - 3
        var total = [Money](repeating: .zero, count: width)
        var income = total
        for a in accounts where ledger.activeAccounts.contains(a.id) {
            let v = consolidationVector(a.id, basis, years)
            add(&total, v)
            if a.type.isIncomeStatement { subtract(&income, v) }
            if hideZero && v.allSatisfy(\.isZero) { continue }
            t.rows.append(ReportRow(id: "a:\(a.id)", cells: [.text(a.number), .text(a.name), .text(code(a))] + v.map { .money($0) },
                                    accountID: a.id, accountType: a.type))
        }
        t.rows.append(ReportRow(id: "total", cells: [.empty, .text("Total (zero when in balance)"), .empty] + total.map { .money($0) }, style: .total))
        t.rows.append(ReportRow(id: "income", cells: [.empty, .text("Net income (loss)"), .empty] + income.map { .money($0) }, style: .subtotal))
        return t
    }

    /// Consolidation rolled up to the grouping list, as an outline: each grouping carries its total
    /// and its subgroups sit indented beneath it. With `detail`, every grouping and subgroup is
    /// expanded to the accounts inside it. Accounts with no grouping are always listed one by one
    /// so they can be found and fixed. Net income is shown under the total, column by column.
    public func groupingSummary(basis: Basis, detail: Bool, prior: Int = 0, hideZero: Bool = true) -> ReportTable {
        let years = years(prior)
        var t = table("Grouping \(detail ? "Detail" : "Summary") — \(basis.label) Basis", sheet: detail ? "Grouping Detail" : "Groupings",
                      columns: [.text("Code", 76), .text("Grouping", 280)] + consolidationColumns(years, basis))
        let width = t.columns.count - 2
        var grand = [Money](repeating: .zero, count: width), income = grand
        var shown: [(Account, [Money])] = []
        for a in accounts where ledger.activeAccounts.contains(a.id) {
            let v = consolidationVector(a.id, basis, years)
            add(&grand, v)
            if a.type.isIncomeStatement { subtract(&income, v) }
            if hideZero && v.allSatisfy(\.isZero) { continue }
            shown.append((a, v))
        }
        t.rows = outline(shown, width: width, detail: detail, hideZero: hideZero)
        t.rows.append(ReportRow(id: "total", cells: [.empty, .text("Total (zero when in balance)")] + grand.map { .money($0) }, style: .total))
        t.rows.append(ReportRow(id: "income", cells: [.empty, .text("Net income (loss)")] + income.map { .money($0) }, style: .subtotal))
        return t
    }

    /// One trial balance laid out like the grouping detail report: its accounts under their
    /// groupings and subgroups, each with a total, section by section. The columns are the same
    /// as the plain trial balance's.
    public func entityByGrouping(entityID: String, hideZero: Bool, prior: Int = 0, priorBasis: Basis = .book) -> ReportTable {
        let ent = entityByID[entityID]
        let columns = EntityColumn.allCases
        let years = years(prior)
        let activity = (ent?.activityNumber.isEmpty ?? true) ? "" : " (Activity \(ent!.activityNumber))"
        var t = table("\(ent?.name ?? entityID)\(activity) — Trial Balance by Grouping", sheet: ent?.name ?? entityID,
                      columns: [.text("Code", 76), .text("Grouping", 280)]
                          + columns.map { .money($0.title) } + priorColumns(years, basis: priorBasis, markTax: true))
        let width = t.columns.count - 2
        let active = ledger.activeAccounts(in: entityID)
        var grand = [Money](repeating: .zero, count: width), income = grand
        var shown: [(Account, [Money])] = []
        for a in accounts where active.contains(a.id) {
            var v = columns.map { ledger.value($0, entity: entityID, account: a.id) }
            if !years.isEmpty {
                let past = years.map { ledger.prior(priorBasis, year: $0, entity: entityID, account: a.id) }
                v += past + [ledger.balance(priorBasis, entity: entityID, account: a.id) - past[0]]
            }
            add(&grand, v)
            if a.type.isIncomeStatement { subtract(&income, v) }
            if hideZero && v.allSatisfy(\.isZero) { continue }
            shown.append((a, v))
        }
        t.rows = outline(shown, width: width, detail: true, hideZero: hideZero, entityID: entityID)
        t.rows.append(ReportRow(id: "total", cells: [.empty, .text("Total (zero when in balance)")] + grand.map { .money($0) }, style: .total))
        t.rows.append(ReportRow(id: "income", cells: [.empty, .text("Net income (loss)")] + income.map { .money($0) }, style: .subtotal))
        return t
    }

    /// The grouping outline over a set of accounts and their amounts: sections, groupings with
    /// their totals, subgroups nested, and (with `detail`) the accounts inside each. Accounts
    /// with no grouping come last, one by one.
    private func outline(_ shown: [(Account, [Money])], width: Int, detail: Bool, hideZero: Bool, entityID: String? = nil) -> [ReportRow] {
        let zero = [Money](repeating: .zero, count: width)
        var members: [String: [(Account, [Money])]] = [:]
        var ungrouped: [(Account, [Money])] = []
        for (a, v) in shown {
            if let g = a.grouping, groupingByID[g] != nil {
                members[g, default: []].append((a, v))
            } else {
                ungrouped.append((a, v))
            }
        }
        func blanks() -> [ReportCell] { [ReportCell](repeating: .empty, count: width) }
        func sum(_ list: [(Account, [Money])]) -> [Money] {
            var out = zero
            for (_, v) in list { add(&out, v) }
            return out
        }
        func accountRows(_ list: [(Account, [Money])], under id: String, indent: String) -> [ReportRow] {
            list.map { a, v in
                ReportRow(id: "\(id):a:\(a.id)", cells: [.text(a.number), .text(indent + a.name)] + v.map { .money($0) },
                          accountID: a.id, entityID: entityID, accountType: a.type)
            }
        }
        let groupStyle: ReportRow.Style = detail ? .subtotal : .normal
        var out: [ReportRow] = []

        for section in e.groupingSections {
            var rows: [ReportRow] = []
            var sectionTotal = zero
            for g in e.topGroupings(in: section) {
                let direct = members[g.id] ?? []
                let subs = e.subgroups(of: g.id).compactMap { s in members[s.id].map { (s, $0) } }
                if direct.isEmpty && subs.isEmpty { continue }
                let directSum = sum(direct)
                var total = directSum
                for (_, list) in subs { add(&total, sum(list)) }
                if hideZero && total.allSatisfy(\.isZero) && !detail { continue }
                add(&sectionTotal, total)
                let gid = "g:\(g.id)"
                rows.append(ReportRow(id: gid, cells: [.text(g.code), .text(g.name)] + total.map { .money($0) },
                                      style: groupStyle, groupingID: g.id))
                if subs.isEmpty {
                    if detail { rows += accountRows(direct, under: gid, indent: "    ") }
                    continue
                }
                for (s, list) in subs {
                    rows.append(ReportRow(id: "g:\(s.id)", cells: [.text(s.code), .text("    " + s.name)] + sum(list).map { .money($0) },
                                          style: groupStyle, groupingID: s.id, parentRowID: gid))
                    if detail { rows += accountRows(list, under: "g:\(s.id)", indent: "        ") }
                }
                if !direct.isEmpty {
                    // What the grouping holds outside its subgroups, so the nested rows add up to it.
                    rows.append(ReportRow(id: "\(gid):direct", cells: [.empty, .text("    Not in a subgroup")] + directSum.map { .money($0) },
                                          style: groupStyle, groupingID: g.id, parentRowID: gid))
                    if detail { rows += accountRows(direct, under: gid, indent: "        ") }
                }
            }
            if rows.isEmpty { continue }
            out.append(ReportRow(id: "s:\(section)", cells: [.empty, .text(section.uppercased())] + blanks(), style: .section))
            out += rows
            out.append(ReportRow(id: "st:\(section)", cells: [.empty, .text("Total \(section)")] + sectionTotal.map { .money($0) }, style: .subtotal))
        }
        if !ungrouped.isEmpty {
            out.append(ReportRow(id: "s:ungrouped", cells: [.empty, .text("UNGROUPED ACCOUNTS")] + blanks(), style: .section))
            for (a, v) in ungrouped {
                out.append(ReportRow(id: "u:\(a.id)", cells: [.text(a.number), .text("    " + a.name)] + v.map { .money($0) },
                                     accountID: a.id, entityID: entityID, accountType: a.type))
            }
            out.append(ReportRow(id: "st:ungrouped", cells: [.empty, .text("Total ungrouped")] + sum(ungrouped).map { .money($0) }, style: .subtotal))
        }
        return out
    }

    /// The accounts inside one grouping, with every consolidation column. A grouping with
    /// subgroups lists each subgroup's accounts under it. This is what opens when a grouping row
    /// is double-clicked.
    public func groupingAccounts(groupingID: String, basis: Basis, prior: Int = 0, hideZero: Bool = true) -> ReportTable {
        let years = years(prior)
        let g = groupingByID[groupingID]
        let label = e.groupingLabel(groupingID).isEmpty ? groupingID : e.groupingLabel(groupingID)
        var t = ReportTable(title: label, subtitle: "\(g?.section ?? "") · \(basis.label.lowercased()) basis", sheetName: "Grouping",
                            columns: [.text("Account", 76), .text("Name", 280)] + consolidationColumns(years, basis),
                            heading: heading("Grouping — \(label) — \(basis.label) Basis"))
        let width = t.columns.count - 2
        let zero = [Money](repeating: .zero, count: width)
        var total = zero
        func rows(in id: String, indent: String) -> ([ReportRow], [Money]) {
            var out: [ReportRow] = []
            var sum = zero
            for a in accounts where a.grouping == id && ledger.activeAccounts.contains(a.id) {
                let v = consolidationVector(a.id, basis, years)
                add(&sum, v)
                if hideZero && v.allSatisfy(\.isZero) { continue }
                out.append(ReportRow(id: "a:\(a.id)", cells: [.text(a.number), .text(indent + a.name)] + v.map { .money($0) },
                                     accountID: a.id, accountType: a.type))
            }
            return (out, sum)
        }
        let subs = e.subgroups(of: groupingID).map { ($0, rows(in: $0.id, indent: "    ")) }.filter { !$0.1.0.isEmpty }
        if subs.isEmpty {
            let (direct, sum) = rows(in: groupingID, indent: "")
            t.rows += direct
            add(&total, sum)
        } else {
            for (s, (list, sum)) in subs {
                t.rows.append(ReportRow(id: "g:\(s.id)", cells: [.text(s.code), .text(s.name)] + sum.map { .money($0) }, style: .subtotal, groupingID: s.id))
                t.rows += list
                add(&total, sum)
            }
            let (direct, sum) = rows(in: groupingID, indent: "    ")
            if !direct.isEmpty {
                t.rows.append(ReportRow(id: "direct", cells: [.empty, .text("Not in a subgroup")] + sum.map { .money($0) }, style: .subtotal))
                t.rows += direct
            }
            add(&total, sum)
        }
        t.rows.append(ReportRow(id: "total", cells: [.empty, .text("Total \(g?.name ?? groupingID)")] + total.map { .money($0) }, style: .total))
        return t
    }

    // MARK: Journal entries

    /// One row per journal line, with the entry's own fields repeated on each row.
    public func journalEntries(types: Set<JEType>? = nil, entityID: String? = nil) -> ReportTable {
        var t = table("Journal Entries", sheet: "Journal Entries",
                      columns: [.text("Entry", 70), .text("Type", 100), .text("Date", 90), .text("Description", 240),
                                .text("Trial Balance", 130), .text("Account", 76), .text("Account Name", 230),
                                .money("Debit"), .money("Credit"), .text("Memo", 180), .text("Linked Files", 220),
                                .text("Next Year", 110)])
        var debits = Money.zero, credits = Money.zero
        for je in sortedEntries() where !je.pending {
            if let types, !types.contains(je.type) { continue }
            if let entityID, !je.lines.contains(where: { $0.entity == entityID }) { continue }
            let refs = je.references.map { $0.location.isEmpty ? $0.path : "\($0.path) [\($0.location)]" }.joined(separator: "; ")
            for (i, l) in je.lines.enumerated() {
                debits += l.amount.debit
                credits += l.amount.credit
                let acct = e.account(l.account)
                t.rows.append(ReportRow(id: "\(je.id):\(i)", cells: [
                    .text(je.number), .text(je.type.label), .text(je.date), .text(je.description),
                    .text(entityByID[l.entity]?.name ?? l.entity), .text(acct?.number ?? l.account), .text(acct?.name ?? ""),
                    l.amount.cents > 0 ? .money(l.amount.debit) : .empty,
                    l.amount.cents < 0 ? .money(l.amount.credit) : .empty,
                    .text(l.memo), .text(refs), .text(je.rollForward.short),
                ], accountID: l.account, entityID: l.entity, entryID: je.id, accountType: acct?.type))
            }
        }
        t.rows.append(ReportRow(id: "total", cells: [.empty, .empty, .empty, .text("Total"), .empty, .empty, .empty,
                                                     .money(debits), .money(credits), .empty, .empty, .empty], style: .total))
        return t
    }

    public func sortedEntries() -> [JournalEntry] {
        let order = Dictionary(uniqueKeysWithValues: JEType.allCases.enumerated().map { ($1, $0) })
        return e.journalEntries.sorted { a, b in
            if a.type != b.type { return order[a.type]! < order[b.type]! }
            let c = a.number.compare(b.number, options: [.numeric, .caseInsensitive])
            return c == .orderedSame ? a.createdAt < b.createdAt : c == .orderedAscending
        }
    }

    // MARK: Data exports

    /// Long format: one row per trial balance × account, every column of the model. This is the
    /// export meant for pivoting, charting, or handing to another tool.
    public func tidy(hideZero: Bool = false) -> ReportTable {
        var t = ReportTable(title: "Trial Balance Data", subtitle: asOf, sheetName: "Data", flat: true,
                            columns: [.text("Trial Balance", 130), .text("Activity", 70), .text("Account", 76), .text("Account Name", 240), .text("Type", 80),
                                      .text("Grouping Code", 90), .text("Grouping", 200), .text("Subgroup", 160), .text("Grouping Section", 130)]
                                + EntityColumn.allCases.map { .money($0.title) }
                                + [.money("Eliminations"), .money("Consolidated (Book)"), .money("Consolidated (Tax)")]
                                + ledger.priorYears.flatMap { [.money("\(e.priorLabel($0)) (Book)"), .money("\(e.priorLabel($0)) (Tax)")] })
        for ent in e.entities {
            // Include accounts that only eliminating entries touch for this entity.
            for a in accounts {
                let elim = ledger.posted(.eliminating, entity: ent.id, account: a.id)
                guard ledger.activeAccounts(in: ent.id).contains(a.id) || !elim.isZero else { continue }
                let v = EntityColumn.allCases.map { ledger.value($0, entity: ent.id, account: a.id) }
                let g = groupingNames(a)
                let book = ledger.value(.book, entity: ent.id, account: a.id)
                let tax = ledger.value(.tax, entity: ent.id, account: a.id)
                let amounts = v + [elim, book + elim, tax + elim]
                    + ledger.priorYears.flatMap { [ledger.prior(.book, year: $0, entity: ent.id, account: a.id),
                                                   ledger.prior(.tax, year: $0, entity: ent.id, account: a.id)] }
                if hideZero && amounts.allSatisfy(\.isZero) { continue }
                t.rows.append(ReportRow(id: "\(ent.id):\(a.id)", cells: [
                    .text(ent.name), .text(ent.activityNumber), .text(a.number), .text(a.name), .text(a.type.label),
                    .text(g.code), .text(g.name), .text(g.subgroup), .text(g.section),
                ] + amounts.map { .money($0) }, accountID: a.id, entityID: ent.id, accountType: a.type))
            }
        }
        return t
    }

    /// An account's grouping as the data exports spell it: the grouping it rolls up to, the
    /// subgroup inside that (if any), and the code it reports under.
    private func groupingNames(_ a: Account) -> (code: String, name: String, subgroup: String, section: String) {
        guard let g = a.grouping.flatMap({ groupingByID[$0] }) else { return ("", "", "", "") }
        if let p = e.parentGrouping(of: g) { return (g.code.isEmpty ? p.code : g.code, p.name, g.name, p.section) }
        return (g.code, g.name, "", g.section)
    }

    public func chartOfAccounts() -> ReportTable {
        var t = table("Chart of Accounts", sheet: "Accounts",
                      columns: [.text("Account", 76), .text("Name", 280), .text("Type", 90),
                                .text("Grouping Code", 100), .text("Grouping", 240), .text("Subgroup", 160), .text("Grouping Section", 140),
                                .text("Used By", 300)])
        for a in accounts {
            let g = groupingNames(a)
            let used = e.entities.filter { ledger.activeAccounts(in: $0.id).contains(a.id) }.map(\.name).joined(separator: ", ")
            t.rows.append(ReportRow(id: a.id, cells: [.text(a.number), .text(a.name), .text(a.type.label),
                                                      .text(g.code), .text(g.name), .text(g.subgroup), .text(g.section), .text(used)],
                                    accountID: a.id, accountType: a.type))
        }
        return t
    }

    // MARK: Drill-down

    /// Everything that makes up one account's balance: the imported amounts and each journal line.
    /// With an entity, eliminating entries are left out (they only exist in consolidation).
    public func accountActivity(accountID: String, entityID: String?) -> ReportTable {
        let a = e.account(accountID)
        let scope = entityID.flatMap { entityByID[$0]?.name } ?? "All trial balances"
        var t = ReportTable(title: a?.display ?? accountID, subtitle: scope, sheetName: "Activity",
                            columns: [.text("Source", 90), .text("Type", 100), .text("Date", 90), .text("Trial Balance", 130),
                                      .text("Description", 300), .money("Amount")],
                            heading: heading("Account Activity — \(a?.display ?? accountID) — \(scope)"))
        var book = Money.zero, tax = Money.zero, elim = Money.zero
        for ent in e.entities where entityID == nil || ent.id == entityID {
            let u = ledger.value(.unadjusted, entity: ent.id, account: accountID)
            if u.isZero && !ent.balances.contains(where: { $0.account == accountID }) { continue }
            book += u
            tax += u
            t.rows.append(ReportRow(id: "u:\(ent.id)", cells: [.text(ent.editedAt.isEmpty ? "Imported" : "Edited"), .text("Unadjusted"), .text(e.periodEnd), .text(ent.name),
                                                               .text(ent.source), .money(u)], entityID: ent.id))
        }
        for je in sortedEntries() where !je.pending {
            if entityID != nil && je.type == .eliminating { continue }
            for (i, l) in je.lines.enumerated() where l.account == accountID && (entityID == nil || l.entity == entityID) {
                switch je.type {
                case .adjusting, .reclassifying:
                    book += l.amount
                    tax += l.amount
                case .taxOnly: tax += l.amount
                case .eliminating: elim += l.amount
                }
                let text = l.memo.isEmpty ? je.description : "\(je.description) — \(l.memo)"
                t.rows.append(ReportRow(id: "\(je.id):\(i)", cells: [.text(je.number), .text(je.type.label), .text(je.date),
                                                                     .text(entityByID[l.entity]?.name ?? l.entity), .text(text), .money(l.amount)],
                                        entryID: je.id))
            }
        }
        func totalRow(_ id: String, _ label: String, _ m: Money, _ style: ReportRow.Style) -> ReportRow {
            ReportRow(id: id, cells: [.empty, .empty, .empty, .empty, .text(label), .money(m)], style: style)
        }
        if entityID == nil {
            t.rows.append(totalRow("book", "Consolidated — book basis", book + elim, .total))
            if tax != book { t.rows.append(totalRow("tax", "Consolidated — tax basis", tax + elim, .subtotal)) }
        } else {
            t.rows.append(totalRow("book", "Final (book)", book, .total))
            if tax != book { t.rows.append(totalRow("tax", "Tax basis", tax, .subtotal)) }
        }
        return t
    }

    // MARK: Everything

    /// The sheets of the full workbook export, in order.
    /// Prior-year columns (the most recent `prior` years) are included where there are any.
    /// The Data sheet always carries every row, zero or not.
    // MARK: The paper trail

    /// The change log, oldest first: when, what was done, what it changed, who did it and on which Mac.
    public func changeLog() -> ReportTable {
        var t = table("Change Log", sheet: "Change Log",
                      columns: [.text("When (UTC)", 150), .text("Action", 210), .text("What changed", 460), .text("Name", 130),
                                .text("Login", 90), .text("Computer", 170), .text("Device ID", 260)])
        for (i, a) in e.auditLog.enumerated() {
            t.rows.append(ReportRow(id: "log:\(i)", cells: [.text(a.at), .text(a.action), .text(a.details.joined(separator: "; ")), .text(a.actor.name),
                                                            .text(a.actor.account), .text(a.actor.computer), .text(a.actor.device)]))
        }
        return t
    }

    /// Every workpaper that has been signed off, and by whom: one row per file, in index order.
    public func signOffs() -> ReportTable {
        var columns: [ReportColumn] = [.text("Index", 80), .text("Workpaper", 300), .text("Folder", 220)]
        for level in SignOffLevel.allCases { columns += [.text("\(level.label) by", 140), .text("\(level.label) (UTC)", 150)] }
        var t = table("Workpaper Sign-offs", sheet: "Sign-offs", columns: columns)
        var paths: [String] = []
        for s in e.signOffs where !paths.contains(s.path) { paths.append(s.path) }
        paths.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        func named(_ path: String) -> (index: String, title: String) {
            let parsed = BinderIndex.parse((path as NSString).lastPathComponent, isFolder: false)
            return (parsed.index?.text ?? "", parsed.title)
        }
        paths.sort { a, b in
            let x = named(a), y = named(b)
            if x.index.isEmpty != y.index.isEmpty { return !x.index.isEmpty }
            return (x.index + " " + x.title).localizedStandardCompare(y.index + " " + y.title) == .orderedAscending
        }
        for path in paths {
            let name = named(path)
            var cells: [ReportCell] = [.text(name.index), .text(name.title), .text((path as NSString).deletingLastPathComponent)]
            for level in SignOffLevel.allCases {
                if let s = e.signOff(level, for: path) {
                    cells += [.text(s.actor.display), .text(s.at)]
                } else {
                    cells += [.empty, .empty]
                }
            }
            t.rows.append(ReportRow(id: "so:\(path)", cells: cells))
        }
        return t
    }

    public func workbook(prior: Int = 1, hideZero: Bool = true) -> [ReportTable] {
        var out = [consolidating(basis: .book, hideZero: hideZero, prior: prior)]
        if e.journalEntries.contains(where: { $0.type == .taxOnly && !$0.pending }) {
            out.append(consolidating(basis: .tax, hideZero: hideZero, prior: prior))
        }
        out.append(groupingSummary(basis: .tax, detail: false, prior: prior, hideZero: hideZero))
        out.append(groupingSummary(basis: .tax, detail: true, prior: prior, hideZero: hideZero))
        for ent in e.entities {
            out.append(entityTrialBalance(entityID: ent.id, hideZero: hideZero, prior: prior))
        }
        out.append(journalEntries())
        out.append(tidy())
        out.append(chartOfAccounts())
        return out
    }
}

// MARK: - Filtering and sorting (what the grids on screen do)

extension ReportTable {
    /// Rows whose cells contain every word of the query (any order, any column). Section and
    /// subtotal rows drop out because they'd no longer add up; one total row sums what is shown.
    public func filtered(_ query: String, filters: FilterSet = FilterSet()) -> ReportTable {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty || filters.isActive else { return self }
        var t = self
        let index = Dictionary(columns.enumerated().map { ($1.title, $0) }, uniquingKeysWith: { a, _ in a })
        t.rows = rows.filter { row in
            guard row.style == .normal else { return false }
            if !terms.isEmpty {
                let haystack = row.cells.map { cell -> String in
                    switch cell {
                    case .empty: return ""
                    case .text(let s): return s.lowercased()
                    case .money(let m): return "\(m.plain) \(m.grouped) \(m.formatted)"
                    }
                }.joined(separator: " \u{1F} ")
                guard terms.allSatisfy({ haystack.contains($0) }) else { return false }
            }
            return filters.matches(cell: { title in
                if let i = index[title] { return i < row.cells.count ? row.cells[i] : .empty }
                // The account's type can be tested on any table of accounts, shown as a column or not.
                if title == FilterCondition.accountTypeColumn { return .text(row.accountType?.label ?? "") }
                return nil
            }, all: row.cells)
        }
        let shown = t.rows.count
        // A subgroup shown under its grouping is already inside the grouping's amounts.
        let shownIDs = Set(t.rows.map(\.id))
        let counted = t.rows.filter { $0.parentRowID.map { !shownIDs.contains($0) } ?? true }
        if columns.contains(where: { $0.kind == .money }) {
            var cells = [ReportCell](repeating: .empty, count: columns.count)
            for (i, c) in columns.enumerated() where c.kind == .money {
                var sum = Money.zero
                for r in counted where i < r.cells.count { if case .money(let m) = r.cells[i] { sum += m } }
                cells[i] = .money(sum)
            }
            let labelAt = columns.count > 1 && columns[1].kind == .text ? 1 : 0
            if columns[labelAt].kind == .text { cells[labelAt] = .text("Total of \(shown) shown row\(shown == 1 ? "" : "s")") }
            t.rows.append(ReportRow(id: "filtered-total", cells: cells, style: .total))
        }
        return t
    }

    /// Account rows ordered by one column. Section and subtotal rows drop out while sorted;
    /// total rows stay at the bottom.
    public func sorted(by column: Int, ascending: Bool) -> ReportTable {
        guard column >= 0, column < columns.count else { return self }
        var t = self
        let body = rows.enumerated().filter { $0.element.style == .normal }
        let isMoney = columns[column].kind == .money
        func key(_ r: ReportRow) -> ReportCell { column < r.cells.count ? r.cells[column] : .empty }
        let ordered = body.sorted { a, b in
            let x = key(a.element), y = key(b.element)
            var result: ComparisonResult
            if isMoney {
                let mx: Int64 = { if case .money(let m) = x { return m.cents }; return 0 }()
                let my: Int64 = { if case .money(let m) = y { return m.cents }; return 0 }()
                result = mx == my ? .orderedSame : (mx < my ? .orderedAscending : .orderedDescending)
            } else {
                let sx: String = { if case .text(let s) = x { return s }; return "" }()
                let sy: String = { if case .text(let s) = y { return s }; return "" }()
                // Blanks last either way.
                if sx.isEmpty != sy.isEmpty { return !sx.isEmpty }
                result = sx.trimmed.compare(sy.trimmed, options: [.numeric, .caseInsensitive])
            }
            if result == .orderedSame { return a.offset < b.offset }
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
        t.rows = ordered.map(\.element) + rows.filter { $0.style == .total }
        return t
    }
}
