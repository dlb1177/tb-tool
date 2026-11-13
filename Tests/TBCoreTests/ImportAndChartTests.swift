import XCTest
@testable import TBCore

final class ImportAndChartTests: XCTestCase {
    static let root = TBCoreTests.root
    static let samples = root.appendingPathComponent(".")

    func m(_ s: String) -> Money { Money.parse(s)!.value }

    func originalTB(_ file: String) throws -> ImportedTB {
        try TBImporter.read(url: Self.root.appendingPathComponent(file))
    }

    /// Same account ids and amounts, regardless of row order.
    func assertSameBalances(_ a: ImportedTB, _ b: ImportedTB, file: StaticString = #filePath, line: UInt = #line) {
        func key(_ r: ImportedTB.Row) -> String { r.number.isEmpty ? r.name : r.number }
        let x = Dictionary(a.rows.map { (key($0), $0.amount) }, uniquingKeysWith: +)
        let y = Dictionary(b.rows.map { (key($0), $0.amount) }, uniquingKeysWith: +)
        XCTAssertEqual(x, y, file: file, line: line)
    }

    // MARK: Messy sources

    func testQuickBooksStyleExcel() throws {
        let url = Self.samples.appendingPathComponent("Ashford - QuickBooks style.xlsx")
        let sheets = try SourceReader.read(url: url)
        XCTAssertEqual(sheets.map(\.name), ["Trial Balance", "Notes"])

        let (index, mapping) = TBImporter.bestGuess(sheets: sheets)
        XCTAssertEqual(index, 0)
        XCTAssertEqual(mapping.headerRow, 4)  // Excel row 5, below the title block
        XCTAssertEqual(mapping.roles, [.ignore, .accountCombined, .ignore, .ignore, .balance])  // Ending, not Beginning / Net Change
        XCTAssertEqual(mapping.sign, .debitPositive)

        let p = TBImporter.evaluate(sheets[0], mapping, sourceName: url.lastPathComponent)
        XCTAssertEqual(p.problems, [])
        XCTAssertEqual(p.count(.heading), 5)
        XCTAssertEqual(p.count(.total), 6)
        XCTAssertEqual(p.count(.aboveHeader), 3)  // the title block; the empty row under it is just blank
        XCTAssertEqual(p.tb.warnings, [])
        XCTAssertEqual(p.tb.rows.first?.number, "10001")
        XCTAssertEqual(p.tb.rows.first?.name, "Ashford Checking (1042) - 2")
        assertSameBalances(p.tb, try originalTB("Summit_TB_Ashford_2026-12-31.csv"))
    }

    func testNormalBalancesShownPositiveInATabFile() throws {
        let url = Self.samples.appendingPathComponent("Clayton - normal balances.txt")
        let sheets = try SourceReader.read(url: url)
        XCTAssertEqual(SourceReader.detectSeparator("a\tb,c\nd\te\n"), "\t")
        let mapping = TBImporter.guess(sheets[0])
        XCTAssertEqual(mapping.roles, [.accountNumber, .accountName, .balance])
        XCTAssertEqual(mapping.sign, .natural)  // the only reading that balances
        let p = TBImporter.evaluate(sheets[0], mapping, sourceName: "x")
        XCTAssertEqual(p.tb.warnings, [])
        assertSameBalances(p.tb, try originalTB("Summit_TB_Clayton_2026-12-31.csv"))
    }

    func testAccountsWithNoNumbers() throws {
        let url = Self.samples.appendingPathComponent("West Clayton - names only.csv")
        let tb = try TBImporter.read(url: url)
        XCTAssertTrue(tb.rows.allSatisfy { $0.number.isEmpty })
        XCTAssertEqual(tb.rows.count, 33)
        XCTAssertEqual(tb.totalDebits, m("713953.42"))
        XCTAssertEqual(tb.warnings, [])  // the Total line ties

        var e = Engagement(name: "X", periodEnd: "2026-12-31")
        let id = try e.addEntity(named: "West Clayton")
        _ = try e.importTrialBalance(tb, into: id)
        XCTAssertNotNil(e.account("Reimbursement Receivable"))
        XCTAssertEqual(e.account("Reimbursement Receivable")?.type, .asset)
        XCTAssertEqual(e.account("Customer Deposits - West Clayton")?.type, .liability)
        XCTAssertEqual(e.account("Rent/Lease Income")?.type, .revenue)
        XCTAssertEqual(e.account("Accumulated Depreciation")?.type, .asset)
        XCTAssertEqual(e.account("West Clayton Checking (6474) - 2")?.type, .asset)  // bank last four
        XCTAssertEqual(e.account("Bank Charges & Fees")?.type, .expense)
        // With types right, net income matches the numbered original.
        XCTAssertEqual(Ledger(e).netIncome(.unadjusted, entity: id), m("415361.26"))
        try e.post(JournalEntry(number: "AJE-1", type: .adjusting, date: "2026-12-31",
                                lines: [JELine(entity: id, account: "Utilities", amount: m("10")),
                                        JELine(entity: id, account: "West Clayton Checking (6474) - 2", amount: m("-10"))]))
        XCTAssertEqual(e.issues(), [])
    }

    func testOriginalSamplesStillReadTheSame() throws {
        for file in TBCoreTests.sampleFiles {
            let sheets = try SourceReader.read(url: Self.root.appendingPathComponent(file))
            let mapping = TBImporter.guess(sheets[0])
            XCTAssertEqual(mapping.headerRow, 0, file)
            XCTAssertEqual(mapping.roles, [.accountCombined, .debit, .credit], file)
        }
    }

    func testDeflatedAndStoredWorkbooksBothRead() throws {
        // Our own export is a stored (uncompressed) zip; re-zip it with deflate like Excel does.
        let e = try TBCoreTests().sampleEngagement()
        let data = Exporter.xlsx([Reports(e).entityTrialBalance(entityID: "ashford", hideZero: false)])
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tbtool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let stored = tmp.appendingPathComponent("stored.xlsx")
        try data.write(to: stored)
        func run(_ tool: String, _ args: [String], in dir: URL) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.currentDirectoryURL = dir
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0)
        }
        let unpacked = tmp.appendingPathComponent("x")
        try run("/usr/bin/unzip", ["-q", stored.path, "-d", unpacked.path], in: tmp)
        let deflated = tmp.appendingPathComponent("deflated.xlsx")
        try run("/usr/bin/zip", ["-q", "-r", "-9", deflated.path, "."], in: unpacked)

        let a = try SourceReader.read(url: stored), b = try SourceReader.read(url: deflated)
        XCTAssertEqual(a, b)
        // Three heading lines (client, report, year end) and a blank row sit above the column titles.
        XCTAssertEqual(a[0].rows[0].first, "Summit")
        XCTAssertEqual(a[0].rows[4].prefix(4), ["Account", "Name", "Grp", "Unadjusted"])
        XCTAssertEqual(a[0].rows[5].prefix(4), ["10001", "Ashford Checking (1042) - 2", "", "12643.59"])  // not grouped yet
    }

    func testUnreadableFormatsExplainWhatToDo() {
        for ext in ["xls", "pdf", "numbers"] {
            XCTAssertThrowsError(try SourceReader.read(url: URL(fileURLWithPath: "/tmp/x.\(ext)"))) { error in
                XCTAssertTrue(error.localizedDescription.contains("Paste") || error.localizedDescription.contains("Save As"))
            }
        }
    }

    func testPastedCellsFromExcel() throws {
        let pasted = "Acct\tDescription\tDebit\tCredit\n1000\tCash\t1,500.00\t\n3000\tOwner's Equity\t\t1,500.00\n"
        let tb = try TBImporter.parse(text: pasted, sourceName: "Pasted")
        XCTAssertEqual(tb.rows.map(\.number), ["1000", "3000"])
        XCTAssertEqual(tb.rows[1].name, "Owner's Equity")
        XCTAssertEqual(tb.total, .zero)
    }

    func testCreditsShownNegativeInTheCreditColumn() throws {
        let tb = try TBImporter.parse(text: "Account,Debit,Credit\n1000 Cash,100,\n3000 Equity,,-100\n", sourceName: "x")
        XCTAssertEqual(tb.rows[1].amount, m("-100"))
        XCTAssertEqual(tb.warnings, [])
    }

    func testNoHeaderRowAtAll() throws {
        let tb = try TBImporter.parse(text: "1000 Cash,250.00,\n2000 Loan,,250.00\n", sourceName: "x")
        XCTAssertEqual(tb.rows.map(\.number), ["1000", "2000"])
        XCTAssertEqual(tb.total, .zero)
    }

    /// The layout of property-management exports (AppFolio / Buildium style): account type column,
    /// sub-accounts shown as paths, and beginning / period debit / period credit / net / ending columns.
    func testPropertyManagementTrialBalance() throws {
        let rows: [[String]] = [
            ["", "Trial Balance Consolidated", "", "", "Prepared By: Manager"],
            ["For", "Some Fund"],
            [],
            ["Account type", "Account name", "Beginning balance", "Total debit", "Total credit", "Net activity", "Ending balance"],
            ["Asset", "1100 Operating Trust", "500", "4100000.00", "3588500.00", "511500.00", "512000.00"],
            ["Asset", "1100 Operating Trust - Pending EFTs", "0", "26500.50", "0", "26500.50", "26500.50"],
            ["Liability", "2320.0055 Mortgages - 2320.0047 Mortgage Payable - 100 Main St NW", "0", "0", "500000", "-500000", "-500000"],
            ["Liability", "2320.0055 Mortgages - 2321.0000 Maple Court Mortgage 1234", "0", "0", "38500.50", "-38500.50", "-38500.50"],
            ["Liability", "20100 Central Bill Account - 7120 - 4", "0", "0", "1000", "-1000", "-1000"],
            ["Expense", "6500 Repairs & Maintenance", "0", "1080", "0", "1080", "1080"],
            ["Expense", "6500 Repairs & Maintenance - 6515.0010 Maintenance - Supplies", "0", "77557.27", "19.99", "77537.28", "77537.28"],
            ["Expense", "6500 Repairs & Maintenance - 6520.0050 Plumbing", "0", "11792.95", "450", "11342.95", "11342.95"],
            ["Equity", "3210.0000 Retained Earnings", "-500", "0", "88460.23", "-88460.23", "-88960.23"],
            ["Total for Some Fund", "", "", "999", "999"],
        ]
        let sheet = RawSheet(name: "TB", rows: rows)
        let mapping = TBImporter.guess(sheet)
        XCTAssertEqual(mapping.headerRow, 3)
        XCTAssertEqual(mapping.roles, [.accountType, .accountCombined, .ignore, .ignore, .ignore, .ignore, .balance])  // Ending, not the period's debits/credits
        let p = TBImporter.evaluate(sheet, mapping, sourceName: "x")
        XCTAssertEqual(p.tb.total, .zero)
        let accounts = p.tb.rows.map { $0.number.isEmpty ? $0.name : "\($0.number) \($0.name)" }
        XCTAssertEqual(accounts, [
            "1100 Operating Trust",
            "1100 Operating Trust - Pending EFTs",  // no number of its own: kept by full name
            "2320.0047 Mortgage Payable - 100 Main St NW",  // the address isn't an account number
            "2321.0000 Maple Court Mortgage 1234",
            "20100 Central Bill Account - 7120 - 4",
            "6500 Repairs & Maintenance",
            "6515.0010 Maintenance - Supplies",
            "6520.0050 Plumbing",
            "3210.0000 Retained Earnings",
        ])
        XCTAssertEqual(p.tb.accountCount, 9)
        // Types come from the file's own column.
        var e = Engagement(name: "X", periodEnd: "2025-12-31")
        let id = try e.addEntity(named: "Fund")
        _ = try e.importTrialBalance(p.tb, into: id)
        XCTAssertEqual(e.account("20100")?.type, .liability)  // "2…" by number would agree; this one says so outright
        XCTAssertEqual(e.account("1100 Operating Trust - Pending EFTs")?.type, .asset)  // no number: only the column knows
    }

    /// A GL detail export: one row per posting, many columns, camelCase headings, True/False flags.
    func testGeneralLedgerDetailSumsToATrialBalance() throws {
        let header = ["Id", "EntryDate", "PostingMemo", "Amount", "IsCashPosting", "GlAccountId", "GLAccountName", "ParentGLAccountName",
                      "IsBankAccount", "GLAccountTypeName", "GLAccountNameRaw", "AccountNumber"]
        let rows = [header,
                    ["1", "1/1/2026", "Utilities", "-4210.50", "1", "1001", "1100 Operating Trust", "", "True", "Asset", "Operating Trust", "1100"],
                    ["1", "1/1/2026", "Utilities", "4210.50", "1", "1002", "6453 Power / Water", "6400 Utilities", "False", "Expense", "Power / Water", "6453"],
                    ["2", "1/3", "Rent", "-800.00", "1", "3", "5120.4001 Rent Income", "5100 Income", "False", "Income", "Rent Income", "5120.4001"],
                    ["2", "1/3", "Rent", "800.00", "1", "1001", "1100 Operating Trust", "", "True", "Asset", "Operating Trust", "1100"]]
        let tb = try TBImporter.parse(text: rows.map { $0.joined(separator: ",") }.joined(separator: "\n"), sourceName: "gl.csv")
        XCTAssertEqual(tb.accountCount, 3)
        XCTAssertEqual(tb.rows.count, 4)
        XCTAssertEqual(tb.netByAccount["1100"], m("-3410.50"))
        XCTAssertEqual(tb.total, .zero)
        XCTAssertTrue(tb.warnings.contains { $0.contains("more than one row") })
        XCTAssertEqual(TBImporter.words("GLAccountNameRaw"), ["gl", "account", "name", "raw"])
        XCTAssertEqual(tb.rows.first?.type, .asset)  // from GLAccountTypeName
    }

    // MARK: Confirming and changing the guess

    func testExcludingAndForcingRows() throws {
        let sheet = RawSheet(name: "s", rows: TBImporter.parseCSV("Account,Debit,Credit\n1000 Cash,100,\n3000 Equity,,100\n9999 Suspense,5,\nTotal,105,100\n"))
        var mapping = TBImporter.guess(sheet)
        var p = TBImporter.evaluate(sheet, mapping, sourceName: "x")
        XCTAssertEqual(p.includedCount, 3)
        mapping.excluded = [3]
        p = TBImporter.evaluate(sheet, mapping, sourceName: "x")
        XCTAssertEqual(p.includedCount, 2)
        XCTAssertEqual(p.rows[3].note, "Left out")
        XCTAssertEqual(p.tb.total, .zero)
        XCTAssertEqual(p.rows[4].kind, .total)
        // Any row but the header can be checked by hand — even one read as a total line.
        XCTAssertTrue(p.rows[4].toggleable)
        XCTAssertFalse(p.rows[0].toggleable)
        mapping.setIncluded(true, row: p.rows[4])
        p = TBImporter.evaluate(sheet, mapping, sourceName: "x")
        XCTAssertEqual(p.includedCount, 3)
        XCTAssertEqual(p.tb.rows.last?.name, "Total")
        XCTAssertEqual(p.tb.rows.last?.amount, m("5"))
    }

    func testChangingRolesKeepsThemConsistent() {
        var mapping = ImportMapping(headerRow: 0, roles: [.accountCombined, .debit, .credit, .ignore])
        mapping.setRole(.balance, for: 3)
        XCTAssertEqual(mapping.roles, [.accountCombined, .ignore, .ignore, .balance])
        mapping.setRole(.accountCombined, for: 2)
        XCTAssertEqual(mapping.roles, [.ignore, .ignore, .accountCombined, .balance])
        XCTAssertEqual(mapping.problems, [])
        mapping.setRole(.ignore, for: 3)
        XCTAssertEqual(mapping.problems.count, 1)
    }

    func testSavedLayoutIsRecognizedNextTime() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("layouts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let header = ["Acct", "Desc", "Dec 31, 25", "Notes"]
        let sheet = RawSheet(name: "s", rows: [header, ["1000", "Cash", "50", ""], ["3000", "Equity", "(50)", "x"]])
        var mapping = ImportMapping(headerRow: 0, roles: [.accountNumber, .accountName, .balance, .ignore])
        mapping.sign = .debitPositive
        ImportProfiles.remember(mapping, header: header, to: url)

        // Next year the date in the heading has changed; the layout still matches.
        var next = sheet
        next.rows[0][2] = "Dec 31, 26"
        let guessed = TBImporter.guess(next, profiles: ImportProfiles.load(url))
        XCTAssertTrue(guessed.fromSavedLayout)
        XCTAssertEqual(guessed.roles, mapping.roles)
        XCTAssertEqual(ImportProfiles.signature(["", "  ", "x"]), "")
    }

    // MARK: Balances live in the JSON, not the source file

    func testBalancesSurviveTheSourceFileBeingDeleted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tbtool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("Ashford.xlsx")
        try FileManager.default.copyItem(at: Self.samples.appendingPathComponent("Ashford - QuickBooks style.xlsx"), to: source)
        let jsonURL = dir.appendingPathComponent("TB.json")

        var e = Engagement(name: "X", periodEnd: "2026-12-31")
        let id = try e.addEntity(named: "Ashford")
        _ = try e.importTrialBalance(try TBImporter.read(url: source), into: id)
        try Store.save(e, to: jsonURL)
        try FileManager.default.removeItem(at: source)

        let reopened = try Store.load(jsonURL)
        XCTAssertEqual(reopened.entity(id)?.balances.count, 35)
        XCTAssertEqual(Ledger(reopened).value(.unadjusted, entity: id, account: "14150"), m("372000.00"))
        XCTAssertEqual(reopened.issues(), [])
    }

    // MARK: Chart of accounts

    func groupedEngagement() throws -> Engagement {
        var e = try TBCoreTests().sampleEngagement()
        _ = e.applyGroupingMap(csv: try String(contentsOf: Self.root.appendingPathComponent("grouping-map.csv"), encoding: .utf8))
        return e
    }

    func testChartRoundTripsThroughJSONAndCSV() throws {
        let source = try groupedEngagement()
        let chart = ChartTransfer.chart(of: source)
        let fromJSON = try ChartTransfer.decodeJSON(ChartTransfer.json(chart), name: "c")
        XCTAssertEqual(fromJSON.accounts, chart.accounts)
        XCTAssertEqual(fromJSON.groupings, chart.groupings)
        let fromCSV = try ChartTransfer.fromTable(TBImporter.parseCSV(ChartTransfer.csv(chart)), name: "c")
        XCTAssertEqual(fromCSV.accounts.map(\.id), chart.accounts.map(\.id))
        XCTAssertEqual(fromCSV.accounts.map(\.groupingID), chart.accounts.map(\.groupingID))
    }

    func testChartImportIntoAnotherFile() throws {
        let source = ChartTransfer.chart(of: try groupedEngagement())
        var target = try TBCoreTests().sampleEngagement()  // same accounts, nothing grouped
        target.setGrouping("L13", forAccounts: ["10001"])  // one decision already made here

        var plan = target.planChartImport(source)
        XCTAssertEqual(plan.matched, 75)
        XCTAssertEqual(plan.keptExisting, ["10001 Ashford Checking (1042) - 2"])
        XCTAssertEqual(plan.unmatched, [])
        XCTAssertEqual(plan.groupingChanges, 74)

        var o = ChartImportOptions()
        o.overwriteGroupings = true
        plan = target.planChartImport(source, options: o)
        XCTAssertEqual(plan.groupingChanges, 75)
        target.applyChartImport(plan)
        XCTAssertEqual(target.account("10001")?.grouping, "L01")
        XCTAssertEqual(target.account("Unapplied Cash Bill Payment Expense")?.grouping, "815-MISC")  // matched by name
        XCTAssertTrue(target.accounts.allSatisfy { $0.grouping != nil })
        XCTAssertEqual(target.issues(), [])
        XCTAssertTrue(target.planChartImport(source, options: o).isEmpty)  // applying again changes nothing
    }

    func testChartImportBringsAcrossCustomGroupingsAndNewAccounts() throws {
        var source = try groupedEngagement()
        let custom = try source.addGrouping(code: "X1", name: "STORAGE UNITS", section: "Other Accounts")
        source.setGrouping(custom.id, forAccounts: ["14150"])
        _ = try source.addAccount(number: "", name: "Petty Cash Box", type: .asset)
        source.setGrouping("L01", forAccounts: ["Petty Cash Box"])

        var target = Engagement(name: "Other client", periodEnd: "2026-12-31")
        _ = try target.addAccount(number: "14150", name: "Storage Building", type: nil)
        var o = ChartImportOptions()
        o.addMissing = true
        let plan = target.planChartImport(ChartTransfer.chart(of: source), options: o)
        XCTAssertEqual(plan.newGroupings.map(\.code), ["X1"])
        XCTAssertTrue(plan.added.contains { $0.id == "Petty Cash Box" && $0.grouping == "L01" })
        target.applyChartImport(plan)
        XCTAssertEqual(target.grouping(target.account("14150")?.grouping)?.name, "STORAGE UNITS")
        XCTAssertEqual(target.account("14150")?.name, "Storage Building")  // names here are kept
        XCTAssertEqual(target.issues(), [])
    }

    func testTwoColumnGroupingSheet() throws {
        let chart = try ChartTransfer.fromTable([["10001", "L01"], ["Unapplied Cash Bill Payment Expense", "815-MISC"], ["51160", "815"]], name: "m")
        var e = try TBCoreTests().sampleEngagement()
        let plan = e.planChartImport(chart)
        XCTAssertEqual(plan.groupingChanges, 3)
        XCTAssertEqual(plan.unresolved, [])  // a code names one grouping, so "815" alone is enough
        e.applyChartImport(plan)
        XCTAssertEqual(e.account("51160")?.grouping, "815")
        XCTAssertEqual(e.account("Unapplied Cash Bill Payment Expense")?.grouping, "815-MISC")
    }

    // MARK: Grids

    func testFilteringAndSortingAReport() throws {
        let t = Reports(try TBCoreTests().sampleEngagement()).consolidating(basis: .book, hideZero: true)
        let f = t.filtered("land")
        XCTAssertEqual(f.rows.filter { $0.style == .normal }.map { $0.cells[0] }, [.text("14100"), .text("14200"), .text("14295")])
        XCTAssertEqual(f.rows.last?.cells[1], .text("Total of 3 shown rows"))
        XCTAssertEqual(f.rows.last?.cells.last, .money(m("292100.00")))
        XCTAssertEqual(t.filtered("accumulated depr").rows.count, 2)
        XCTAssertEqual(t.filtered("  ").rows, t.rows)

        let consolidated = t.columns.count - 1
        let s = t.sorted(by: consolidated, ascending: false)
        XCTAssertEqual(s.rows.first?.cells[0], .text("51400"))  // largest debit: Brighton's lease payment
        XCTAssertEqual(s.rows.last?.style, .total)
        let byName = t.sorted(by: 1, ascending: true)
        XCTAssertEqual(byName.rows.first?.cells[1], .text("Accumulated Amortization"))
        XCTAssertEqual(byName.rows.count, t.rows.count - 1)  // the net income subtotal drops out while sorted
    }
}
