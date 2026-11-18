import XCTest
@testable import TBCore

final class TBCoreTests: XCTestCase {

    // Made-up trial balances for a fictional group ("Summit Storage"): four properties and a parent.
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let sampleFiles = [
        "Summit_TB_Ashford_2026-12-31.csv", "Summit_TB_Brighton_2026-12-31.csv", "Summit_TB_Clayton_2026-12-31.csv",
        "Summit_TB_West_Clayton_2026-12-31.csv", "Summit_TB_Parent_2026-12-31.csv",
    ]

    func sampleEngagement() throws -> Engagement {
        var e = Engagement(name: "Summit", periodEnd: "2026-12-31")
        for file in Self.sampleFiles {
            let tb = try TBImporter.read(url: Self.root.appendingPathComponent(file))
            let id = try e.addEntity(named: TBImporter.suggestedEntityName(fileName: file))
            let warnings = try e.importTrialBalance(tb, into: id)
            XCTAssertEqual(warnings, [], file)
        }
        return e
    }

    func m(_ s: String) -> Money { Money.parse(s)!.value }

    func line(_ entity: String, _ account: String, _ amount: String) -> JELine {
        JELine(entity: entity, account: account, amount: m(amount))
    }

    // MARK: Money

    func testMoneyParsing() {
        XCTAssertEqual(m("8123.45").cents, 812345)
        XCTAssertEqual(m("1,234.56").cents, 123456)
        XCTAssertEqual(m("(1,234.56)").cents, -123456)
        XCTAssertEqual(m("-1234.5").cents, -123450)
        XCTAssertEqual(m("$ 1,234").cents, 123400)
        XCTAssertEqual(m("1234.56-").cents, -123456)
        XCTAssertEqual(m("").cents, 0)
        XCTAssertEqual(m("-").cents, 0)
        XCTAssertEqual(m(".5").cents, 50)
        XCTAssertEqual(Money.parse("1.005"), Money.ParseResult(value: Money(cents: 101), rounded: true))
        XCTAssertEqual(Money.parse("1.100"), Money.ParseResult(value: Money(cents: 110), rounded: false))
        XCTAssertNil(Money.parse("abc"))
        XCTAssertNil(Money.parse("1.2.3"))
        XCTAssertNil(Money.parse("12a"))
    }

    func testMoneyFormatting() {
        XCTAssertEqual(Money(cents: 123456789).formatted, "1,234,567.89")
        XCTAssertEqual(Money(cents: -123405).formatted, "(1,234.05)")
        XCTAssertEqual(Money(cents: -5).plain, "-0.05")
        XCTAssertEqual(Money(cents: 100000).grouped, "1,000.00")
        XCTAssertEqual(Money(cents: 99).grouped, "0.99")
    }

    // MARK: Import

    func testSplitAccount() {
        XCTAssertEqual(TBImporter.splitAccount("10001 Ashford Checking (1042) - 2").number, "10001")
        XCTAssertEqual(TBImporter.splitAccount("10001 Ashford Checking (1042) - 2").name, "Ashford Checking (1042) - 2")
        XCTAssertEqual(TBImporter.splitAccount("Unapplied Cash Bill Payment Expense").number, "")
        XCTAssertEqual(TBImporter.splitAccount("1000 · Cash").name, "Cash")
        XCTAssertEqual(TBImporter.splitAccount("14290 Furniture, Fixtures & Equipment - Brighton").name, "Furniture, Fixtures & Equipment - Brighton")
    }

    func testSuggestedEntityNames() {
        XCTAssertEqual(TBImporter.suggestedEntityName(fileName: "Summit_TB_Ashford_2026-12-31.csv"), "Ashford")
        XCTAssertEqual(TBImporter.suggestedEntityName(fileName: "Summit_TB_West_Clayton_2026-12-31.csv"), "West Clayton")
        XCTAssertEqual(TBImporter.suggestedEntityName(fileName: "Main Street.csv"), "Main Street")
    }

    func testSampleFilesImportInBalanceAndMatchTheirTotals() throws {
        let expected: [String: (rows: Int, total: String)] = [
            "Summit_TB_Ashford_2026-12-31.csv": (35, "563050.45"),
            "Summit_TB_Brighton_2026-12-31.csv": (43, "1688011.72"),
            "Summit_TB_Clayton_2026-12-31.csv": (37, "940611.16"),
            "Summit_TB_West_Clayton_2026-12-31.csv": (33, "713953.42"),
            "Summit_TB_Parent_2026-12-31.csv": (12, "1936620.86"),
        ]
        for file in Self.sampleFiles {
            let tb = try TBImporter.read(url: Self.root.appendingPathComponent(file))
            XCTAssertEqual(tb.rows.count, expected[file]!.rows, file)
            XCTAssertEqual(tb.totalDebits, m(expected[file]!.total), file)
            XCTAssertEqual(tb.totalCredits, m(expected[file]!.total), file)
            XCTAssertEqual(tb.warnings, [], file)
        }
    }

    func testImportFlagsProblems() throws {
        let csv = "Account,Debit,Credit\n1000 Cash,100.00,\n3000 Equity,,90.00\nTOTAL,100.00,100.00\n"
        let tb = try TBImporter.parse(text: csv, sourceName: "bad.csv")
        XCTAssertEqual(tb.rows.count, 2)
        XCTAssertEqual(tb.warnings.count, 2)  // TOTAL row mismatch + out of balance
        XCTAssertThrowsError(try TBImporter.parse(text: "Account,Debit,Credit\n1000 Cash,abc,\n", sourceName: "x.csv"))
        XCTAssertThrowsError(try TBImporter.parse(text: "nothing here\n", sourceName: "x.csv"))
    }

    func testImportSignedBalanceAndSeparateColumns() throws {
        let csv = "Acct No,Account Name,Balance\n1000,\"Cash, operating\",\"1,500.00\"\n3000,Equity,(1500.00)\n"
        let tb = try TBImporter.parse(text: csv, sourceName: "bal.csv")
        XCTAssertEqual(tb.rows.map(\.number), ["1000", "3000"])
        XCTAssertEqual(tb.rows[0].name, "Cash, operating")
        XCTAssertEqual(tb.rows[1].amount.cents, -150000)
        XCTAssertEqual(tb.warnings, [])
    }

    func testSharedChartOfAccounts() throws {
        let e = try sampleEngagement()
        XCTAssertEqual(e.entities.map(\.name), ["Ashford", "Brighton", "Clayton", "West Clayton", "Parent"])
        // 14299 Accumulated Depreciation is used by four entities but is one chart account.
        XCTAssertEqual(e.accounts.filter { $0.id == "14299" }.count, 1)
        XCTAssertEqual(Set(e.accounts.map(\.id)).count, e.accounts.count)
        XCTAssertEqual(e.account("40000")?.type, .revenue)
        XCTAssertEqual(e.account("Unapplied Cash Bill Payment Expense")?.type, .expense)
        XCTAssertEqual(e.issues(), [])
    }

    func testReimportReplacesBalancesAndKeepsEntries() throws {
        var e = try sampleEngagement()
        try e.post(JournalEntry(number: "AJE-1", type: .adjusting, date: "2026-12-31",
                                lines: [line("ashford", "51200", "100"), line("ashford", "10001", "-100")]))
        let tb = try TBImporter.read(url: Self.root.appendingPathComponent(Self.sampleFiles[0]))
        _ = try e.importTrialBalance(tb, into: "ashford")
        XCTAssertEqual(e.entity("ashford")?.balances.count, 35)
        XCTAssertEqual(e.journalEntries.count, 1)
    }

    // MARK: Posting rules

    func testWhichEntriesMaySpanTrialBalances() throws {
        var e = try sampleEngagement()
        // Adjusting and tax-only entries post to one trial balance.
        for type in [JEType.adjusting, .taxOnly] {
            let je = JournalEntry(number: "X-1", type: type, date: "2026-12-31",
                                  lines: [line("ashford", "51200", "100"), line("brighton", "51200", "-100")])
            XCTAssertThrowsError(try e.post(je), type.rawValue) { error in
                XCTAssertTrue(error.localizedDescription.contains("single trial balance"))
            }
        }
        XCTAssertFalse(JEType.adjusting.canSpanTrialBalances)
        XCTAssertFalse(JEType.taxOnly.canSpanTrialBalances)
        // A reclassifying entry can name a trial balance on each line: overhead allocated in one entry.
        let before = Ledger(e)
        let allocation = JournalEntry(number: "RJE-1", type: .reclassifying, date: "2026-12-31", description: "Allocate management overhead",
                                      lines: [line("ashford", "51155", "300"), line("clayton", "51155", "200"), line("brighton", "51155", "-500")])
        XCTAssertNoThrow(try e.post(allocation))
        let l = Ledger(e)
        XCTAssertEqual(l.value(.rje, entity: "ashford", account: "51155"), m("300"))
        XCTAssertEqual(l.value(.rje, entity: "clayton", account: "51155"), m("200"))
        XCTAssertEqual(l.value(.rje, entity: "brighton", account: "51155"), m("-500"))
        XCTAssertEqual(l.value(.adjusted, entity: "ashford", account: "51155"), before.value(.adjusted, entity: "ashford", account: "51155"))
        // The consolidation is unchanged in total; each trial balance has moved by its share.
        XCTAssertEqual(l.consolidated(.book, account: "51155"), before.consolidated(.book, account: "51155"))
        XCTAssertEqual(l.consolidatedTotal(.book), .zero)
        XCTAssertEqual(l.total(.book, entity: "ashford"), m("300"))
        XCTAssertEqual(e.issues(), [])
        XCTAssertEqual(try Store.decode(Store.encode(e)), e)
        // It still has to balance as a whole.
        XCTAssertThrowsError(try e.post(JournalEntry(number: "RJE-2", type: .reclassifying, date: "2026-12-31",
                                                     lines: [line("ashford", "51155", "300"), line("brighton", "51155", "-200")])))
        let elim = JournalEntry(number: "EJE-1", type: .eliminating, date: "2026-12-31",
                                lines: [line("ashford", "51200", "100"), line("brighton", "51200", "-100")])
        XCTAssertNoThrow(try e.post(elim))
        XCTAssertEqual(e.journalEntries.count, 2)
        // An entry that spans trial balances can't be turned into an adjusting or tax-only one.
        var converted = allocation
        converted.type = .adjusting
        XCTAssertFalse(e.validationErrors(for: converted).filter { $0.contains("single trial balance") }.isEmpty)
    }

    func testActivityNumbersPerTrialBalance() throws {
        var e = try sampleEngagement()
        try e.setActivityNumber(" 1 ", for: "ashford")
        try e.setActivityNumber("2", for: "brighton")
        XCTAssertEqual(e.entity("ashford")?.activityNumber, "1")
        XCTAssertThrowsError(try e.setActivityNumber("1", for: "clayton"))   // each trial balance has its own
        try e.setActivityNumber("", for: "brighton")                          // blank clears it
        try e.setActivityNumber("2", for: "clayton")
        XCTAssertEqual(try Store.decode(Store.encode(e)), e)
        XCTAssertTrue(String(data: Store.encode(e), encoding: .utf8)!.contains("\"activityNumber\": \"1\""))
        // It heads that trial balance's report and is a column of the data export.
        let reports = Reports(e)
        XCTAssertEqual(reports.entityTrialBalance(entityID: "ashford", hideZero: true).title, "Ashford (Activity 1) — Trial Balance")
        XCTAssertEqual(reports.entityTrialBalance(entityID: "brighton", hideZero: true).title, "Brighton — Trial Balance")
        let data = reports.tidy()
        let column = data.columns.firstIndex { $0.title == "Activity" }!
        XCTAssertEqual(data.rows.first { $0.entityID == "ashford" }?.cells[column], .text("1"))
        XCTAssertEqual(data.rows.first { $0.entityID == "brighton" }?.cells[column], .text(""))
        // And it carries into next year's file.
        XCTAssertEqual(try e.rolledForward().entity("clayton")?.activityNumber, "2")
    }

    func testEntryMustBalanceAndReferenceRealThings() throws {
        var e = try sampleEngagement()
        func errors(_ lines: [JELine], number: String = "AJE-1", date: String = "2026-12-31") -> [String] {
            e.validationErrors(for: JournalEntry(number: number, type: .adjusting, date: date, lines: lines))
        }
        XCTAssertEqual(errors([line("ashford", "51200", "100"), line("ashford", "10001", "-100")]), [])
        XCTAssertTrue(errors([line("ashford", "51200", "100"), line("ashford", "10001", "-99.99")]).contains { $0.contains("Out of balance by 0.01") })
        XCTAssertTrue(errors([line("ashford", "99999", "100"), line("ashford", "10001", "-100")]).contains { $0.contains("isn't in the chart") })
        XCTAssertTrue(errors([line("nowhere", "51200", "100"), line("nowhere", "10001", "-100")]).contains { $0.contains("choose a trial balance") })
        XCTAssertTrue(errors([line("ashford", "51200", "0"), line("ashford", "10001", "0")]).contains { $0.contains("enter a debit or a credit") })
        XCTAssertTrue(errors([line("ashford", "51200", "100")]).contains { $0.contains("at least two lines") })
        XCTAssertTrue(errors([line("ashford", "51200", "100"), line("ashford", "10001", "-100")], date: "2026-02-30").contains { $0.contains("date") })
        XCTAssertTrue(errors([line("ashford", "51200", "100"), line("ashford", "10001", "-100")], number: " ").contains { $0.contains("needs a number") })

        try e.post(JournalEntry(number: "AJE-1", type: .adjusting, date: "2026-12-31",
                                lines: [line("ashford", "51200", "100"), line("ashford", "10001", "-100")]))
        XCTAssertTrue(errors([line("ashford", "51200", "100"), line("ashford", "10001", "-100")], number: "aje-1").contains { $0.contains("already used") })
        // A rejected entry leaves the file untouched.
        let before = e
        XCTAssertThrowsError(try e.post(JournalEntry(number: "AJE-2", type: .adjusting, date: "2026-12-31", lines: [line("ashford", "51200", "5")])))
        XCTAssertEqual(e, before)
    }

    func testEntryNumbering() throws {
        var e = try sampleEngagement()
        XCTAssertEqual(e.nextEntryNumber(for: .adjusting), "AJE-1")
        try e.post(JournalEntry(number: "AJE-1", type: .adjusting, date: "2026-12-31", lines: [line("ashford", "51200", "1"), line("ashford", "10001", "-1")]))
        try e.post(JournalEntry(number: "AJE-7", type: .adjusting, date: "2026-12-31", lines: [line("ashford", "51200", "1"), line("ashford", "10001", "-1")]))
        XCTAssertEqual(e.nextEntryNumber(for: .adjusting), "AJE-8")
        XCTAssertEqual(e.nextEntryNumber(for: .eliminating), "EJE-1")
        XCTAssertEqual(e.nextEntryNumber(for: .taxOnly), "TJE-1")
    }

    func testEditingAnEntryReplacesIt() throws {
        var e = try sampleEngagement()
        var je = JournalEntry(number: "AJE-1", type: .adjusting, date: "2026-12-31", lines: [line("ashford", "51200", "1"), line("ashford", "10001", "-1")])
        try e.post(je)
        je.lines = [line("ashford", "51200", "250"), line("ashford", "10001", "-250")]
        try e.post(je)
        XCTAssertEqual(e.journalEntries.count, 1)
        XCTAssertEqual(Ledger(e).value(.aje, entity: "ashford", account: "51200"), m("250"))
    }

    func testDeletingAnEntity() throws {
        var e = try sampleEngagement()
        try e.post(JournalEntry(number: "AJE-1", type: .adjusting, date: "2026-12-31", lines: [line("ashford", "51200", "1"), line("ashford", "10001", "-1")]))
        try e.post(JournalEntry(number: "EJE-1", type: .eliminating, date: "2026-12-31", lines: [line("ashford", "51200", "1"), line("brighton", "51200", "-1")]))
        XCTAssertThrowsError(try e.deleteEntity("ashford"))
        XCTAssertEqual(e.entities.count, 5)
        e.deleteEntry(e.journalEntries[1].id)
        try e.deleteEntity("ashford")
        XCTAssertEqual(e.entities.count, 4)
        XCTAssertEqual(e.journalEntries.count, 0)
        XCTAssertEqual(e.issues(), [])
    }

    // MARK: Columns and consolidation

    func testEntryTypesFlowToTheRightColumns() throws {
        var e = try sampleEngagement()
        try e.post(JournalEntry(number: "AJE-1", type: .adjusting, date: "2026-12-31", lines: [line("ashford", "51200", "100"), line("ashford", "10001", "-100")]))
        try e.post(JournalEntry(number: "RJE-1", type: .reclassifying, date: "2026-12-31", lines: [line("ashford", "51200", "10"), line("ashford", "51240", "-10")]))
        try e.post(JournalEntry(number: "TJE-1", type: .taxOnly, date: "2026-12-31", lines: [line("ashford", "51200", "1"), line("ashford", "14299", "-1")]))
        let l = Ledger(e)
        func v(_ c: EntityColumn) -> Money { l.value(c, entity: "ashford", account: "51200") }
        XCTAssertEqual(v(.unadjusted), m("3837.52"))
        XCTAssertEqual(v(.aje), m("100"))
        XCTAssertEqual(v(.adjusted), m("3937.52"))
        XCTAssertEqual(v(.rje), m("10"))
        XCTAssertEqual(v(.book), m("3947.52"))
        XCTAssertEqual(v(.tje), m("1"))
        XCTAssertEqual(v(.tax), m("3948.52"))
        // Other entities are untouched.
        XCTAssertEqual(l.value(.tax, entity: "clayton", account: "51200"), m("8678.31"))
        // Every column of every entity still balances.
        for ent in e.entities {
            for c in EntityColumn.allCases { XCTAssertEqual(l.total(c, entity: ent.id), .zero) }
        }
        // Book consolidation ignores the tax-only entry; tax consolidation includes it.
        XCTAssertEqual(l.consolidated(.book, account: "14299"), m("-173579.55"))
        XCTAssertEqual(l.consolidated(.tax, account: "14299"), m("-173580.55"))
    }

    func investmentElimination() -> JournalEntry {
        JournalEntry(number: "EJE-1", type: .eliminating, date: "2026-12-31",
                     description: "Eliminate investment in subsidiaries",
                     lines: [
                        line("ashford", "32000", "181441.23"), line("brighton", "32000", "1079935.33"),
                        line("clayton", "32000", "177824.67"), line("west-clayton", "32000", "120555.49"),
                        line("parent", "49600", "56864.14"),
                        line("parent", "16100", "-216234.74"), line("parent", "16200", "-628885.54"),
                        line("parent", "16300", "-235583.83"), line("parent", "16400", "-535916.75"),
                     ])
    }

    func testConsolidationWithElimination() throws {
        var e = try sampleEngagement()
        let before = Ledger(e)
        XCTAssertEqual(before.consolidatedTotal(.book), .zero)
        XCTAssertEqual(before.combined(.book, account: "14299"), m("-173579.55"))

        try e.post(investmentElimination())
        let l = Ledger(e)
        XCTAssertEqual(l.eliminationsTotal(), .zero)
        XCTAssertEqual(l.consolidatedTotal(.book), .zero)
        for acct in ["16100", "16200", "16300", "16400", "32000", "49600"] {
            XCTAssertEqual(l.consolidated(.book, account: acct), .zero, acct)
        }
        // Each entity's own trial balance is unchanged by an elimination.
        XCTAssertEqual(l.value(.book, entity: "ashford", account: "32000"), m("-181441.23"))
        // After eliminating the parent's equity pickup, consolidated income is the subsidiaries' income.
        let subs = ["ashford", "brighton", "clayton", "west-clayton"].map { l.netIncome(.book, entity: $0) }.sum()
        XCTAssertEqual(l.consolidatedNetIncome(.book), subs)

        let table = Reports(e).consolidating(basis: .book, hideZero: false)
        XCTAssertEqual(table.columns.map(\.title), ["Account", "Name", "Grp", "Ashford", "Brighton", "Clayton", "West Clayton", "Parent", "Combined", "Eliminations", "Consolidated"])
        let total = table.rows.first { $0.id == "total" }!
        XCTAssertTrue(total.cells.dropFirst(3).allSatisfy { $0 == .money(.zero) })
        XCTAssertEqual(Set(table.rows.map(\.id)).count, table.rows.count)
    }

    func testGroupingSummaryTiesToConsolidation() throws {
        var e = try sampleEngagement()
        try e.post(investmentElimination())
        e.setGrouping("L09B", forAccounts: ["14299"])
        e.setGrouping("802", forAccounts: ["40000", "42000"])
        for detail in [false, true] {
            let t = Reports(e).groupingSummary(basis: .book, detail: detail)
            XCTAssertEqual(Set(t.rows.map(\.id)).count, t.rows.count)
            let row = t.rows.first { $0.id == "g:L09B" }!
            XCTAssertEqual(row.cells.last, .money(m("-173579.55")))
            let total = t.rows.first { $0.id == "total" }!
            XCTAssertEqual(total.cells.last, .money(.zero))
            XCTAssertTrue(t.rows.contains { $0.id == "s:ungrouped" })
        }
    }

    func testGroupingMapAndDefaults() throws {
        var e = try sampleEngagement()
        XCTAssertEqual(e.groupings.count, 75)
        // Every code is used once: the "other" lines of Form 8825 are subgroups of 815.
        XCTAssertEqual(e.groupings.filter { $0.code == "815" }.count, 1)
        XCTAssertEqual(e.subgroups(of: "815").count, 6)
        XCTAssertTrue(e.sharedGroupingCodes.isEmpty)
        let result = e.applyGroupingMap(csv: "Account,Grouping\n10001,L01\n51155 Summit Mgmt - Monthly Fee,815-MGMT\n51160,815\n99999,L01\n40000,802 GROSS RENTS\n51180,815 OTHER - MISCELLANEOUS\n")
        XCTAssertEqual(result.applied, 5)
        XCTAssertEqual(result.warnings.count, 1)  // unknown 99999
        XCTAssertEqual(e.account("51160")?.grouping, "815")
        XCTAssertEqual(e.account("51180")?.grouping, "815-MISC")  // the way older lists spelled it still finds the subgroup
        XCTAssertEqual(e.account("10001")?.grouping, "L01")
        XCTAssertEqual(e.account("51155")?.grouping, "815-MGMT")
        XCTAssertEqual(e.account("40000")?.grouping, "802")
        e.deleteGrouping("L01")
        XCTAssertNil(e.account("10001")?.grouping)
        XCTAssertEqual(e.issues(), [])
    }

    func testTidyDataTiesToConsolidation() throws {
        var e = try sampleEngagement()
        try e.post(investmentElimination())
        let t = Reports(e).tidy()
        let consolidatedColumn = t.columns.firstIndex { $0.title == "Consolidated (Book)" }!
        var sum = Money.zero
        for row in t.rows {
            if case .money(let v) = row.cells[consolidatedColumn] { sum += v }
        }
        XCTAssertEqual(sum, .zero)
        XCTAssertEqual(t.rows.count, 35 + 43 + 37 + 33 + 12)
    }

    // MARK: File format

    func testFileRoundTripIsExactAndStable() throws {
        var e = try sampleEngagement()
        var je = investmentElimination()
        je.references = [FileReference(path: "Workpapers/Investment rollforward.xlsx", note: "tab 2"), FileReference(path: "/tmp/other \"quoted\".pdf")]
        try e.post(je)
        e.setGrouping("L09B", forAccounts: ["14299"])
        let data = Store.encode(e)
        let back = try Store.decode(data)
        XCTAssertEqual(back, e)
        XCTAssertEqual(Store.encode(back), data)
        let text = String(data: data, encoding: .utf8)!
        XCTAssertTrue(text.hasPrefix("{\n  \"fileType\": \"trial-balance\",\n  \"schemaVersion\": 4,"))
        XCTAssertTrue(text.contains("{ \"account\": \"10001\", \"debit\": 12643.59, \"credit\": 0.00 }"))
        // Any standard JSON parser can read it.
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
    }

    func testFileMustIdentifyItselfAsATrialBalance() {
        XCTAssertThrowsError(try Store.decode(Data("{\"name\": \"x\"}".utf8)))
        XCTAssertThrowsError(try Store.decode(Data("{\"fileType\": \"something-else\"}".utf8)))
        XCTAssertThrowsError(try Store.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try Store.decode(Data("{\"fileType\": \"trial-balance\", \"schemaVersion\": 99}".utf8)))
        XCTAssertNoThrow(try Store.decode(Data("{\"fileType\": \"trial-balance\"}".utf8)))
    }

    func testUnknownTopLevelFieldsSurviveASave() throws {
        let json = "{\"fileType\": \"trial-balance\", \"name\": \"X\", \"periodEnd\": \"2026-12-31\", \"myNotes\": {\"reviewer\": \"DB\", \"done\": true, \"hours\": 1.5}}"
        let e = try Store.decode(Data(json.utf8))
        let again = try Store.decode(Store.encode(e))
        XCTAssertEqual(again, e)
        XCTAssertTrue(String(data: Store.encode(e), encoding: .utf8)!.contains("\"myNotes\": { \"done\": true, \"hours\": 1.5, \"reviewer\": \"DB\" }"))
    }

    func testHandEditedFileProblemsAreReported() throws {
        let json = """
        {"fileType": "trial-balance", "name": "X", "periodEnd": "2026-12-31",
         "accounts": [{"number": "1000", "name": "Cash"}, {"number": "3000", "name": "Equity", "grouping": "NOPE"}],
         "entities": [{"id": "a", "name": "A", "balances": [{"account": "1000", "debit": 10}, {"account": "3000", "credit": 9}, {"account": "7777", "debit": 0}]}],
         "journalEntries": [{"number": "AJE-1", "type": "adjusting", "date": "2026-12-31",
           "lines": [{"entity": "a", "account": "1000", "debit": 5}, {"entity": "a", "account": "3000", "credit": 4}]}]}
        """
        let issues = try Store.decode(Data(json.utf8)).issues()
        XCTAssertEqual(issues.count, 4, issues.joined(separator: "\n"))
    }

    func testFileReferencesAreRelativeInsideTheFolder() {
        let folder = URL(fileURLWithPath: "/Clients/Summit")
        let inside = FileReference(file: URL(fileURLWithPath: "/Clients/Summit/Workpapers/Depr.xlsx"), engagementFolder: folder)
        XCTAssertEqual(inside.path, "Workpapers/Depr.xlsx")
        XCTAssertEqual(inside.url(engagementFolder: folder).path, "/Clients/Summit/Workpapers/Depr.xlsx")
        let outside = FileReference(file: URL(fileURLWithPath: "/Clients/Summit-old/Depr.xlsx"), engagementFolder: folder)
        XCTAssertEqual(outside.path, "/Clients/Summit-old/Depr.xlsx")
    }

    // MARK: Exports

    func testCSVExport() throws {
        var e = try sampleEngagement()
        try e.post(investmentElimination())
        let csv = Exporter.csv(Reports(e).consolidating(basis: .book, hideZero: true))
        let rows = TBImporter.parseCSV(csv)
        XCTAssertEqual(rows[0].count, 11)
        XCTAssertTrue(rows.allSatisfy { $0.count == 11 })
        let ffe = rows.first { $0[0] == "14290" }!
        XCTAssertEqual(ffe[1], "Furniture, Fixtures & Equipment - Brighton")
        XCTAssertEqual(ffe[10], "325400.00")
        let equity = rows.first { $0[0] == "32000" }!
        XCTAssertEqual(equity[8], "-1559756.72")
        XCTAssertEqual(equity[9], "1559756.72")
        XCTAssertEqual(equity[10], "0.00")
    }

    func testWorkbookExportIsAValidZipWithEverySheet() throws {
        var e = try sampleEngagement()
        try e.post(investmentElimination())
        let tables = Reports(e).workbook()
        let names = XLSXWriter.sheetNames(tables)
        XCTAssertEqual(names, ["Consolidated", "Groupings", "Grouping Detail", "Ashford", "Brighton", "Clayton", "West Clayton", "Parent", "Journal Entries", "Data", "Accounts"])
        let data = Exporter.xlsx(tables)
        XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4B, 0x03, 0x04])
        XCTAssertEqual(Zip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tbtool-test-\(UUID().uuidString).xlsx")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        p.arguments = ["-tq", tmp.path]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    func testSheetNamesAreLegalAndUnique() {
        func t(_ name: String) -> ReportTable { ReportTable(title: "", subtitle: "", sheetName: name, columns: []) }
        let names = XLSXWriter.sheetNames([t("A/B: North [1]"), t("a/b: north [1]"), t(String(repeating: "x", count: 40)), t("")])
        XCTAssertEqual(names[0], "A-B- North -1-")
        XCTAssertEqual(names[1], "a-b- north -1- (2)")
        XCTAssertEqual(names[2].count, 31)
        XCTAssertEqual(names[3], "Sheet")
    }

    func testAccountLookupFromTypedText() throws {
        let e = try sampleEngagement()
        XCTAssertEqual(e.resolveAccount("14299")?.id, "14299")
        XCTAssertEqual(e.resolveAccount("14299 accumulated depreciation")?.id, "14299")
        XCTAssertEqual(e.resolveAccount("goodwill")?.id, "14750")
        XCTAssertNil(e.resolveAccount("land"))  // several accounts match
        XCTAssertNil(e.resolveAccount(""))
    }
}
