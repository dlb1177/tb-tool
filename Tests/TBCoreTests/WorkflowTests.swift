import XCTest
@testable import TBCore

/// Binder headings, prior years, roll forward, hand-edited balances, broken links, custom
/// filters, grouping lists and account search.
final class WorkflowTests: XCTestCase {

    func m(_ s: String) -> Money { Money.parse(s)!.value }

    func line(_ entity: String, _ account: String, _ amount: String) -> JELine {
        JELine(entity: entity, account: account, amount: m(amount))
    }

    func sample() throws -> Engagement {
        var e = Engagement(name: "Summit", periodEnd: "2026-12-31")
        for file in TBCoreTests.sampleFiles {
            let tb = try TBImporter.read(url: TBCoreTests.root.appendingPathComponent(file))
            _ = try e.importTrialBalance(tb, into: try e.addEntity(named: TBImporter.suggestedEntityName(fileName: file)))
        }
        return e
    }

    func money(_ t: ReportTable, row: String, column: String) -> Money {
        let c = t.columns.firstIndex { $0.title == column }!
        if case .money(let v) = t.rows.first(where: { $0.id == row })!.cells[c] { return v }
        return .zero
    }

    // MARK: Account search

    func testAccountSearchRanksNumbersThenNames() throws {
        let e = try sample()
        XCTAssertEqual(e.searchAccounts("14299").first?.id, "14299")
        // A number prefix lists that range in chart order.
        let range = e.searchAccounts("142")
        XCTAssertFalse(range.isEmpty)
        XCTAssertTrue(range.prefix(3).allSatisfy { $0.number.hasPrefix("142") })
        // Words in any order, anywhere in the number or name.
        let hits = e.searchAccounts("depreciation accumulated")
        XCTAssertTrue(hits.contains { $0.id == "14299" })
        XCTAssertTrue(hits.allSatisfy { $0.name.lowercased().contains("accumulated") && $0.name.lowercased().contains("depreciation") })
        // A name that starts with the text beats one that merely contains it.
        let land = e.searchAccounts("land")
        XCTAssertTrue(land.count > 1)
        XCTAssertTrue(land[0].name.lowercased().hasPrefix("land"))
        XCTAssertEqual(e.searchAccounts("zzzz"), [])
        XCTAssertEqual(e.searchAccounts("").count, e.accounts.count)
    }

    // MARK: Broken links

    func testBrokenLinksAreFoundAndRepaired() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("tbtool-links-\(UUID().uuidString)")
        try fm.createDirectory(at: folder.appendingPathComponent("Workpapers/2026"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        try Data("x".utf8).write(to: folder.appendingPathComponent("Workpapers/2026/Depreciation.xlsx"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("Workpapers/2026/Accruals.xlsx"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("Workpapers/Here.pdf"))

        var e = try sample()
        var a = JournalEntry(number: "AJE-1", type: .adjusting, date: "2026-12-31",
                             lines: [line("ashford", "51040", "100"), line("ashford", "10001", "-100")])
        a.references = [FileReference(path: "Old/Depreciation.xlsx", note: "tab 2"), FileReference(path: "Workpapers/Here.pdf")]
        var b = JournalEntry(number: "AJE-2", type: .adjusting, date: "2026-12-31",
                             lines: [line("ashford", "51040", "50"), line("ashford", "10001", "-50")])
        b.references = [FileReference(path: "Old/Depreciation.xlsx"), FileReference(path: "Old/Accruals.xlsx"), FileReference(path: "/nowhere/Gone.pdf")]
        try e.post(a)
        try e.post(b)

        let broken = LinkFinder.withCandidates(e.brokenLinks(folder: folder), folder: folder)
        XCTAssertEqual(broken.map(\.reference.path), ["Old/Depreciation.xlsx", "Old/Depreciation.xlsx", "Old/Accruals.xlsx", "/nowhere/Gone.pdf"])
        XCTAssertEqual(broken[0].suggestion, "Workpapers/2026/Depreciation.xlsx")
        XCTAssertNil(broken[3].suggestion)

        // Locating one file finds the others that moved with it.
        let siblings = LinkFinder.siblings(of: "Old/Depreciation.xlsx", movedTo: "Workpapers/2026/Depreciation.xlsx", among: broken, folder: folder)
        XCTAssertEqual(siblings, ["Old/Accruals.xlsx": "Workpapers/2026/Accruals.xlsx"])

        XCTAssertEqual(e.relink("Old/Depreciation.xlsx", to: "Workpapers/2026/Depreciation.xlsx"), 2)
        XCTAssertEqual(e.entry(a.id)?.references.first?.note, "tab 2")  // the note stays with the link
        for (old, new) in siblings { e.relink(old, to: new) }
        XCTAssertEqual(e.removeLink("/nowhere/Gone.pdf", entryID: b.id), 1)
        XCTAssertEqual(e.brokenLinks(folder: folder), [])
        XCTAssertEqual(e.entry(b.id)?.references.map(\.path), ["Workpapers/2026/Depreciation.xlsx", "Workpapers/2026/Accruals.xlsx"])
    }

    // MARK: Balances changed by hand

    func testEditingUnadjustedBalancesByHand() throws {
        var e = try sample()
        var balances = e.editableBalances(entity: "ashford")
        let cash = balances.firstIndex { $0.account == "10001" }!
        balances[cash].amount += m("250.00")
        let equity = balances.firstIndex { $0.account == "32000" }!
        balances[equity].amount -= m("250.00")
        try e.setBalances(balances, for: "ashford")
        let l = Ledger(e)
        XCTAssertEqual(l.value(.unadjusted, entity: "ashford", account: "10001"), m("12893.59"))
        XCTAssertEqual(l.total(.unadjusted, entity: "ashford"), .zero)
        XCTAssertFalse(e.entity("ashford")!.editedAt.isEmpty)
        XCTAssertEqual(e.entity("brighton")!.editedAt, "")

        // An account from the chart that this trial balance didn't have; zeros that were never there drop out.
        let other = e.accounts.first { a in !balances.contains { $0.account == a.id } }!
        try e.setBalances(balances + [Balance(account: other.id, amount: .zero)], for: "ashford")
        XCTAssertFalse(e.entity("ashford")!.balances.contains { $0.account == other.id })
        try e.setBalances(balances + [Balance(account: other.id, amount: m("10"))], for: "ashford")
        XCTAssertEqual(Ledger(e).value(.unadjusted, entity: "ashford", account: other.id), m("10"))

        XCTAssertThrowsError(try e.setBalances([Balance(account: "nope", amount: m("1"))], for: "ashford"))
        XCTAssertThrowsError(try e.setBalances(balances + [balances[0]], for: "ashford"))

        // A blank trial balance can be keyed in from nothing.
        let id = try e.addEntity(named: "Keyed In")
        try e.setBalances([Balance(account: "10001", amount: m("100")), Balance(account: "32000", amount: m("-100"))], for: id)
        XCTAssertEqual(Ledger(e).total(.unadjusted, entity: id), .zero)
        XCTAssertEqual(try Store.decode(Store.encode(e)), e)
    }

    // MARK: Prior years

    func testPriorYearImportAndRelativeColumns() throws {
        var e = try sample()
        let py = try TBImporter.parse(text: "Account,Debit,Credit\n10001 Cash,8000.00,\n32000 Equity,,7000.00\n99990 Old Account,,1000.00\n", sourceName: "Ashford 2025.csv")
        XCTAssertEqual(try e.importPriorPeriod(py, into: "ashford", year: 2025), [])
        let older = try TBImporter.parse(text: "Account,Debit,Credit\n10001 Cash,5000.00,\n32000 Equity,,5000.00\n", sourceName: "Ashford 2024.csv")
        _ = try e.importPriorPeriod(older, into: "ashford", year: 2024)
        XCTAssertThrowsError(try e.importPriorPeriod(py, into: "ashford", year: 2026))  // not a prior year
        XCTAssertNotNil(e.account("99990"))  // joined the chart

        XCTAssertEqual(e.priorYears, [2025, 2024])
        XCTAssertEqual(e.priorLabel(2025), "PP1 2025")
        XCTAssertEqual(e.priorLabel(2024), "PP2 2024")

        let t = Reports(e).entityTrialBalance(entityID: "ashford", hideZero: false, prior: 2)
        XCTAssertEqual(Array(t.columns.map(\.title).suffix(3)), ["PP1 2025", "PP2 2024", "Change vs PP1"])
        XCTAssertEqual(money(t, row: "a:10001", column: "PP1 2025"), m("8000"))
        XCTAssertEqual(money(t, row: "a:10001", column: "PP2 2024"), m("5000"))
        XCTAssertEqual(money(t, row: "a:10001", column: "Change vs PP1"), m("4643.59"))
        XCTAssertEqual(money(t, row: "a:99990", column: "PP1 2025"), m("-1000"))  // only a prior balance
        XCTAssertEqual(money(t, row: "total", column: "PP1 2025"), .zero)
        // Without asking for prior years the report is what it always was.
        XCTAssertEqual(Reports(e).entityTrialBalance(entityID: "ashford", hideZero: false).columns.count, 10)

        let c = Reports(e).consolidating(basis: .book, hideZero: true, prior: 1)
        XCTAssertEqual(Array(c.columns.map(\.title).suffix(3)), ["Consolidated", "PP1 2025", "Change vs PP1"])
        XCTAssertEqual(money(c, row: "a:10001", column: "PP1 2025"), m("8000"))

        // The columns are relative to the current year: move the year on and they move back.
        e.periodEnd = "2027-12-31"
        XCTAssertEqual(e.priorLabel(2025), "PP2 2025")
        e.periodEnd = "2025-12-31"
        XCTAssertEqual(e.priorYears, [2024])  // 2025 is no longer a prior year, but it is kept
        XCTAssertEqual(e.entity("ashford")!.priorPeriods.map(\.year), [2025, 2024])
        e.periodEnd = "2026-12-31"

        // Prior balances can be changed by hand too; an account with a prior balance can't be deleted.
        var prior = e.editableBalances(entity: "ashford", priorYear: 2025)
        prior[prior.firstIndex { $0.account == "99990" }!].amount = m("-900")
        prior[prior.firstIndex { $0.account == "32000" }!].amount = m("-7100")
        try e.setBalances(prior, for: "ashford", priorYear: 2025)
        XCTAssertEqual(Ledger(e).prior(.book, year: 2025, entity: "ashford", account: "99990"), m("-900"))
        XCTAssertThrowsError(try e.deleteAccount("99990"))

        let back = try Store.decode(Store.encode(e))
        XCTAssertEqual(back, e)
        XCTAssertTrue(String(data: Store.encode(e), encoding: .utf8)!.contains("{ \"account\": \"99990\", \"book\": -900.00, \"tax\": -900.00, \"elim\": 0.00 }"))
    }

    // MARK: Roll forward

    func testRollForwardToNextYear() throws {
        var e = try sample()
        e.binder.engagement = "2026 Tax Return"
        e.binder.preparedBy = "DB"
        e.setGrouping("L01", forAccounts: ["10001"])
        var recurring = JournalEntry(number: "AJE-1", type: .adjusting, date: "2026-12-31", description: "Recurring accrual",
                                     lines: [line("ashford", "51040", "100"), line("ashford", "23000", "-100")],
                                     references: [FileReference(path: "Workpapers/Accrual.xlsx")])
        recurring.rollForward = .withAmounts
        var template = JournalEntry(number: "TJE-1", type: .taxOnly, date: "2026-12-31", description: "Depreciation difference",
                                    lines: [line("ashford", "51040", "40"), line("ashford", "14299", "-40")])
        template.rollForward = .withoutAmounts
        let oneOff = JournalEntry(number: "RJE-1", type: .reclassifying, date: "2026-06-30", description: "One time",
                                  lines: [line("ashford", "51040", "5"), line("ashford", "51060", "-5")])
        var elim = JournalEntry(number: "EJE-1", type: .eliminating, date: "2026-12-31",
                                lines: [line("ashford", "32000", "181441.23"), line("parent", "16100", "-181441.23")])
        elim.rollForward = .withAmounts
        for je in [recurring, template, oneOff, elim] { try e.post(je) }
        let closing = Ledger(e)

        let summary = try e.rollForwardSummary()
        XCTAssertEqual(summary.newPeriodEnd, "2027-12-31")
        XCTAssertEqual(summary.withAmounts.map(\.number), ["AJE-1", "EJE-1"])
        XCTAssertEqual(summary.withoutAmounts.map(\.number), ["TJE-1"])
        XCTAssertEqual(summary.notRolled.map(\.number), ["RJE-1"])

        var o = RollForwardOptions()
        o.sourceName = "Summit 2026 Trial Balance.json"
        let next = try e.rolledForward(o)
        XCTAssertEqual(e.periodEnd, "2026-12-31")  // the original is untouched
        XCTAssertEqual(next.periodEnd, "2027-12-31")
        XCTAssertEqual(next.currentYear, 2027)
        XCTAssertEqual(next.binder.engagement, "2027 Tax Return")
        XCTAssertEqual(next.binder.preparedBy, "DB")
        XCTAssertEqual(next.rolledForwardFrom, "Summit 2026 Trial Balance.json")
        XCTAssertEqual(next.accounts, e.accounts)
        XCTAssertEqual(next.groupings, e.groupings)
        XCTAssertTrue(next.entities.allSatisfy { $0.balances.isEmpty })  // ready for the new year's import
        XCTAssertEqual(next.issues(), [])

        // This year's final balances are now PP1 — book, tax, and the eliminations.
        let l = Ledger(next)
        XCTAssertEqual(next.priorYears, [2026])
        XCTAssertEqual(l.prior(.book, year: 2026, entity: "ashford", account: "51040"), closing.value(.book, entity: "ashford", account: "51040"))
        XCTAssertEqual(l.prior(.tax, year: 2026, entity: "ashford", account: "14299"), closing.value(.tax, entity: "ashford", account: "14299"))
        XCTAssertEqual(l.priorConsolidated(.book, year: 2026, account: "32000"), closing.consolidated(.book, account: "32000"))
        for a in next.accounts {
            XCTAssertEqual(l.priorConsolidated(.tax, year: 2026, account: a.id), closing.consolidated(.tax, account: a.id), a.id)
        }

        // Entries: with amounts, without amounts (waiting, posting nothing), or not at all.
        XCTAssertEqual(next.journalEntries.map(\.number), ["AJE-1", "EJE-1", "TJE-1"])
        let rolled = next.journalEntries[0]
        XCTAssertEqual(rolled.date, "2027-12-31")
        XCTAssertEqual(rolled.lines, recurring.lines)
        XCTAssertEqual(rolled.references, [])
        XCTAssertNotEqual(rolled.id, recurring.id)
        XCTAssertEqual(l.value(.aje, entity: "ashford", account: "51040"), m("100"))
        let waiting = next.journalEntries[2]
        XCTAssertTrue(waiting.pending)
        XCTAssertTrue(waiting.lines.allSatisfy { $0.amount.isZero })
        XCTAssertEqual(waiting.lines.map(\.account), ["51040", "14299"])
        XCTAssertEqual(l.value(.tje, entity: "ashford", account: "51040"), .zero)
        XCTAssertEqual(next.nextEntryNumber(for: .taxOnly), "TJE-2")

        // Filling in the amounts and posting completes it.
        var done = waiting
        done.lines[0].amount = m("55")
        done.lines[1].amount = m("-55")
        var next2 = next
        try next2.post(done)
        XCTAssertFalse(next2.entry(done.id)!.pending)
        XCTAssertEqual(Ledger(next2).value(.tje, entity: "ashford", account: "51040"), m("55"))

        XCTAssertEqual(try Store.decode(Store.encode(next)), next)

        // Rolling again moves 2026 back to PP2.
        let third = try next2.rolledForward()
        XCTAssertEqual(third.priorYears, [2027, 2026])
        XCTAssertEqual(third.priorLabel(2026), "PP2 2026")

        XCTAssertEqual(Engagement.rolledFileName("Summit 2026 Trial Balance.json", from: 2026, to: 2027), "Summit 2027 Trial Balance.json")
        XCTAssertEqual(Engagement.rolledFileName("Trial Balance.json", from: 2026, to: 2027), "Trial Balance 2027.json")
        var noYear = e
        noYear.periodEnd = ""
        XCTAssertThrowsError(try noYear.rolledForward())
    }

    func testRollForwardCarryingTheBalanceSheet() throws {
        let e = try sample()
        let closing = Ledger(e)
        var o = RollForwardOptions()
        o.opening = .carryBalanceSheet(closeInto: "32000")
        let next = try e.rolledForward(o)
        let l = Ledger(next)
        for ent in next.entities {
            XCTAssertEqual(l.total(.unadjusted, entity: ent.id), .zero, ent.name)
            XCTAssertEqual(l.netIncome(.book, entity: ent.id), .zero, ent.name)
        }
        XCTAssertEqual(l.value(.unadjusted, entity: "ashford", account: "10001"), closing.value(.book, entity: "ashford", account: "10001"))
        // Equity opens at last year's equity plus last year's income (a credit, so it goes more negative).
        XCTAssertEqual(l.value(.unadjusted, entity: "ashford", account: "32000"),
                       closing.value(.book, entity: "ashford", account: "32000") - closing.netIncome(.book, entity: "ashford"))
        o.opening = .carryBalanceSheet(closeInto: "40000")  // an income account can't take the close
        XCTAssertThrowsError(try e.rolledForward(o))
    }

    // MARK: Binder heading

    func testBinderHeadsEveryReportExport() throws {
        var e = try sample()
        e.binder.clientNumber = "1042"
        e.binder.entityType = "Partnership (Form 1065)"
        e.binder.engagement = "2026 Tax Return"
        e.binder.preparedBy = "DB"
        let reports = Reports(e)
        let t = reports.consolidating(basis: .book, hideZero: true)
        XCTAssertEqual(t.heading, ["Summit", "Consolidating Trial Balance — Book Basis", "Year ended December 31, 2026",
                                   "Client No. 1042  ·  Partnership (Form 1065)  ·  2026 Tax Return", "Prepared by DB"])
        for table in reports.workbook() {
            XCTAssertEqual(table.heading.isEmpty, table.flat, table.sheetName)
            if !table.flat { XCTAssertEqual(table.heading[0], "Summit", table.sheetName) }
        }
        XCTAssertTrue(reports.tidy().flat)  // the pivot data stays a plain table

        let csv = TBImporter.parseCSV(Exporter.csv(t, heading: true))
        XCTAssertEqual(csv[0], ["Summit"])
        XCTAssertEqual(csv[2], ["Year ended December 31, 2026"])
        XCTAssertEqual(csv[6][0], "Account")
        XCTAssertEqual(TBImporter.parseCSV(Exporter.csv(t))[0][0], "Account")
        XCTAssertEqual(XLSXWriter.headerRow(t), 7)
        XCTAssertEqual(XLSXWriter.headerRow(reports.tidy()), 1)

        // Our own workbook still reads back, heading and all.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tbtool-head-\(UUID().uuidString).xlsx")
        try Exporter.xlsx(reports.workbook()).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sheets = try SourceReader.read(url: tmp)
        XCTAssertEqual(sheets[0].rows[0].first, "Summit")
        XCTAssertEqual(sheets[0].rows[6].first, "Account")

        let back = try Store.decode(Store.encode(e))
        XCTAssertEqual(back.binder, e.binder)
    }

    func testVersionOneFilesStillOpen() throws {
        let json = """
        {"fileType": "trial-balance", "schemaVersion": 1, "name": "X", "periodEnd": "2026-12-31",
         "accounts": [{"number": "1000", "name": "Cash"}, {"number": "3000", "name": "Equity"}],
         "entities": [{"id": "a", "name": "A", "balances": [{"account": "1000", "debit": 10}, {"account": "3000", "credit": 10}]}],
         "journalEntries": [{"number": "AJE-1", "type": "adjusting", "date": "2026-12-31",
           "lines": [{"entity": "a", "account": "1000", "debit": 5}, {"entity": "a", "account": "3000", "credit": 5}]}]}
        """
        let e = try Store.decode(Data(json.utf8))
        XCTAssertEqual(e.binder, Binder())
        XCTAssertEqual(e.journalEntries[0].rollForward, .none)
        XCTAssertEqual(e.priorYears, [])
        XCTAssertEqual(e.issues(), [])
    }

    // MARK: Custom filters

    func testCustomFilters() throws {
        let e = try sample()
        let t = Reports(e).consolidating(basis: .book, hideZero: true)
        func rows(_ f: FilterSet, _ query: String = "") -> [ReportRow] { t.filtered(query, filters: f).rows.filter { $0.style == .normal } }
        let all = t.rows.filter { $0.style == .normal }.count

        // Size ignores the sign: debits and credits over the threshold both show.
        let big = rows(FilterSet(conditions: [FilterCondition(column: "Consolidated", op: .atLeast, value: "100,000")]))
        XCTAssertTrue(!big.isEmpty && big.count < all)
        let col = t.columns.firstIndex { $0.title == "Consolidated" }!
        for r in big { if case .money(let v) = r.cells[col] { XCTAssertGreaterThanOrEqual(abs(v.cents), 10_000_000) } }
        XCTAssertTrue(big.contains { if case .money(let v) = $0.cells[col] { return v.cents < 0 }; return false })

        let credits = rows(FilterSet(conditions: [FilterCondition(column: "Consolidated", op: .isCredit)]))
        let debits = rows(FilterSet(conditions: [FilterCondition(column: "Consolidated", op: .isDebit)]))
        let zero = rows(FilterSet(conditions: [FilterCondition(column: "Consolidated", op: .isZero)]))
        XCTAssertEqual(credits.count + debits.count + zero.count, all)

        // All of / any of.
        let five = FilterCondition(column: "Account", op: .startsWith, value: "5")
        let four = FilterCondition(column: "Account", op: .startsWith, value: "4")
        XCTAssertEqual(rows(FilterSet(matchAll: true, conditions: [five, four])).count, 0)
        let either = rows(FilterSet(matchAll: false, conditions: [five, four]))
        XCTAssertTrue(!either.isEmpty && either.allSatisfy { if case .text(let s) = $0.cells[0] { return s.hasPrefix("4") || s.hasPrefix("5") }; return false })

        // Ungrouped accounts; a rule still being typed changes nothing; rules combine with the quick box.
        XCTAssertEqual(rows(FilterSet(conditions: [FilterCondition(column: "Grp", op: .isEmpty)])).count, all)
        XCTAssertEqual(rows(FilterSet(conditions: [FilterCondition(column: "Name", op: .contains, value: "")])).count, all)
        XCTAssertEqual(rows(FilterSet(conditions: [FilterCondition(column: "Consolidated", op: .between, value: "1", value2: "")])).count, all)
        let both = rows(FilterSet(conditions: [five]), "insurance")
        XCTAssertTrue(!both.isEmpty && both.count < rows(FilterSet(conditions: [five])).count)
        // Any column.
        let anywhere = rows(FilterSet(conditions: [FilterCondition(column: "", op: .contains, value: "goodwill")]))
        XCTAssertEqual(anywhere.count, 1)
        XCTAssertEqual(rows(FilterSet(conditions: [FilterCondition(column: "", op: .notContains, value: "goodwill")])).count, all - 1)

        // The shown rows are totalled.
        let filtered = t.filtered("", filters: FilterSet(conditions: [five]))
        XCTAssertEqual(filtered.rows.last?.id, "filtered-total")

        // Saved filters survive being written to preferences.
        let saved = SavedFilter(name: "Over 100k", filter: FilterSet(matchAll: false, conditions: [five, FilterCondition(column: "Consolidated", op: .between, value: "1", value2: "2")]))
        let back = try JSONDecoder().decode(SavedFilter.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(back.filter.matchAll, false)
        XCTAssertEqual(back.filter.conditions.map(\.summary), saved.filter.conditions.map(\.summary))
    }

    // MARK: Grouping lists

    func testGroupingListExportAndImport() throws {
        var e = try sample()
        e.setGrouping("L01", forAccounts: ["10001"])
        e.setGrouping("815-MGMT", forAccounts: ["51040"])
        let exported = GroupingTransfer.list(of: e)
        XCTAssertEqual(try GroupingTransfer.decodeJSON(GroupingTransfer.json(exported), name: "x").groupings, e.groupings)
        let fromCSV = try GroupingTransfer.fromTable(TBImporter.parseCSV(GroupingTransfer.csv(exported)), name: "x")
        XCTAssertEqual(fromCSV.groupings, e.groupings)

        // An S corporation list in a plain sheet: the section is carried down, and rows that share a
        // code come in as one grouping with subgroups, because a code is used once.
        let sheet = "Section,Code,Name\nPage 1,S1A,GROSS RECEIPTS\n,S7,COMPENSATION OF OFFICERS\n,S19,OTHER DEDUCTIONS - OFFICE\n,S19,OTHER DEDUCTIONS - TRAVEL\nSch. L Accounts,L01,CASH\n"
        let scorp = try GroupingTransfer.fromTable(TBImporter.parseCSV(sheet), name: "S Corp")
        XCTAssertEqual(scorp.groupings.map(\.name), ["GROSS RECEIPTS", "COMPENSATION OF OFFICERS", "OTHER DEDUCTIONS", "OFFICE", "TRAVEL", "CASH"])
        XCTAssertEqual(scorp.groupings.map(\.code), ["S1A", "S7", "S19", "", "", "L01"])
        let other = scorp.groupings[2]
        XCTAssertEqual(scorp.groupings.map(\.parent), [nil, nil, nil, other.id, other.id, nil])
        XCTAssertEqual(scorp.groupings.map(\.section), ["Page 1", "Page 1", "Page 1", "Page 1", "Page 1", "Sch. L Accounts"])
        XCTAssertEqual(Set(scorp.groupings.map(\.id)).count, 6)
        XCTAssertTrue(Engagement.sharedCodes(scorp.groupings).isEmpty)

        // Replace: the list becomes the S corp list; cash keeps its grouping (same id), the 8825 one is lost.
        let replace = e.planGroupingImport(scorp, mode: .replace)
        XCTAssertEqual(replace.result, scorp.groupings)
        XCTAssertEqual(replace.ungrouped.map(\.id), ["51040"])
        var replaced = e
        replaced.applyGroupingImport(replace, name: "S Corporation")
        XCTAssertEqual(replaced.groupingListName, "S Corporation")
        XCTAssertEqual(replaced.account("10001")?.grouping, "L01")
        XCTAssertNil(replaced.account("51040")?.grouping)
        XCTAssertEqual(replaced.issues(), [])
        XCTAssertEqual(try Store.decode(Store.encode(replaced)), replaced)

        // Merge: only what's missing is added; nothing is lost.
        let merge = e.planGroupingImport(scorp, mode: .merge)
        XCTAssertEqual(merge.added.count, 5)
        XCTAssertEqual(merge.removed, [])
        var merged = e
        merged.applyGroupingImport(merge)
        XCTAssertEqual(merged.groupings.count, e.groupings.count + 5)
        XCTAssertTrue(merged.sharedGroupingCodes.isEmpty)
        XCTAssertEqual(merged.account("51040")?.grouping, "815-MGMT")
        // Importing the list a file already has changes nothing.
        XCTAssertTrue(e.planGroupingImport(exported, mode: .replace).isEmpty)

        // The library keeps lists for new files.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tbtool-lists-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try GroupingLibrary.save(GroupingList(name: "S Corporation", groupings: scorp.groupings), in: dir)
        XCTAssertEqual(GroupingLibrary.lists(in: dir).map(\.name), ["S Corporation"])
        XCTAssertEqual(GroupingLibrary.lists(in: dir)[0].groupings, scorp.groupings)
    }
}
