import XCTest
@testable import TBCore

/// Deleting an account that is in use, reordering journal entries, and importing names whole.
final class DeleteReorderSplitTests: XCTestCase {

    func m(_ s: String) -> Money { Money.parse(s)!.value }

    func tb(_ csv: String) -> ImportedTB {
        let sheet = RawSheet(name: "s", rows: TBImporter.parseCSV(csv))
        return TBImporter.evaluate(sheet, TBImporter.guess(sheet), sourceName: "x").tb
    }

    /// One trial balance with a prior year. Account 1500 has only a prior-year balance.
    func books() throws -> (Engagement, String) {
        var e = Engagement(name: "Summit Storage", periodEnd: "2026-12-31")
        let id = try e.addEntity(named: "Ashford")
        _ = try e.importTrialBalance(tb("Account,Debit,Credit\n1000 Cash,100,\n3000 Equity,,100\n"), into: id)
        _ = try e.importPriorPeriod(tb("Account,Debit,Credit\n1000 Cash,60,\n1500 Old Deposit,40,\n3000 Equity,,100\n"), into: id, year: 2025)
        return (e, id)
    }

    func entry(_ number: String, _ type: JEType = .adjusting, _ entity: String, _ lines: [(String, String)]) -> JournalEntry {
        JournalEntry(number: number, type: type, date: "2026-12-31", description: "Test \(number)",
                     lines: lines.map { JELine(entity: entity, account: $0.0, amount: m($0.1)) })
    }

    // MARK: Delete anyway

    func testAnAccountInUseSaysWhatIsInTheWay() throws {
        var (e, id) = try books()
        try e.post(entry("AJE-1", .adjusting, id, [("1500", "25"), ("1000", "-25")]))
        let uses = e.accountUses("1500")
        XCTAssertEqual(uses.count, 2)
        XCTAssertTrue(uses[0].hasPrefix("Ashford: PP1 2025 balance of 40.00"), uses[0])
        XCTAssertTrue(uses[1].hasPrefix("AJE-1: 1 line of 25.00"), uses[1])
        XCTAssertThrowsError(try e.deleteAccount("1500")) { error in
            XCTAssertTrue(error.localizedDescription.contains("PP1 2025"))
            XCTAssertTrue(error.localizedDescription.contains("AJE-1"))
        }
        XCTAssertNotNil(e.account("1500"))
        // An account nothing refers to has nothing in the way.
        try e.addAccount(number: "1999", name: "Unused", type: .asset)
        XCTAssertEqual(e.accountUses("1999"), [])
        XCTAssertEqual(try e.deleteAccount("1999"), [])
        XCTAssertNil(e.account("1999"))
    }

    func testDeleteAnywayRemovesBalancesAndLinesAndSaysWhatIsOutOfBalance() throws {
        var (e, id) = try books()
        try e.post(entry("AJE-1", .adjusting, id, [("1500", "25"), ("1000", "-25")]))
        try e.post(entry("AJE-2", .adjusting, id, [("1500", "10"), ("1500", "-10")]))
        try e.post(entry("AJE-3", .adjusting, id, [("1000", "5"), ("3000", "-5")]))
        let notes = try e.deleteAccount("1500", force: true)
        XCTAssertTrue(notes.contains("Ashford: PP1 2025 is now out of balance by (40.00)"), "\(notes)")
        XCTAssertTrue(notes.contains("AJE-1 is now out of balance by (25.00)"), "\(notes)")
        XCTAssertTrue(notes.contains("AJE-2 had no other lines and was removed"), "\(notes)")
        XCTAssertEqual(notes.count, 3)

        XCTAssertNil(e.account("1500"))
        XCTAssertEqual(e.accountUses("1500"), [])
        XCTAssertEqual(e.journalEntries.map(\.number).sorted(), ["AJE-1", "AJE-3"])
        XCTAssertEqual(e.journalEntries.first { $0.number == "AJE-1" }?.lines.count, 1)
        XCTAssertEqual(e.journalEntries.first { $0.number == "AJE-3" }?.lines.count, 2)
        let prior = e.entities[0].priorPeriods.first { $0.year == 2025 }!
        XCTAssertFalse(prior.balances.contains { $0.account == "1500" })
        XCTAssertEqual(prior.balances.map(\.book).sum(), m("-40"))
        // This year's trial balance never had the account, so it still balances.
        XCTAssertEqual(e.entities[0].unadjustedTotal, .zero)
    }

    func testDeleteAnywaySaysWhenThisYearGoesOutOfBalance() throws {
        var (e, _) = try books()
        let notes = try e.deleteAccount("1000", force: true)
        XCTAssertTrue(notes.contains("Ashford: the 2026 unadjusted trial balance is now out of balance by (100.00)"), "\(notes)")
        XCTAssertTrue(notes.contains("Ashford: PP1 2025 is now out of balance by (60.00)"), "\(notes)")
    }

    // MARK: Reordering entries

    func threeEntries(_ numbers: [String]) throws -> (Engagement, [String]) {
        var (e, id) = try books()
        for n in numbers { try e.post(entry(n, .adjusting, id, [("1000", "5"), ("3000", "-5")])) }
        try e.post(entry("RJE-1", .reclassifying, id, [("1000", "7"), ("3000", "-7")]))
        let ids = numbers.map { n in e.journalEntries.first { $0.number == n }!.id }
        return (e, ids)
    }

    func testAnUnbrokenRunRenumbersOneWay() throws {
        var (e, ids) = try threeEntries(["AJE-1", "AJE-2", "AJE-3"])
        let plan = try XCTUnwrap(e.planReorder(moving: [ids[2]], target: ids[0], after: false))
        XCTAssertEqual(plan.order, [ids[2], ids[0], ids[1]])
        XCTAssertEqual(plan.fromOne, ["AJE-1", "AJE-2", "AJE-3"])
        XCTAssertFalse(plan.ambiguous)
        try e.applyReorder(plan, numbers: plan.fromOne)
        XCTAssertEqual(e.entry(ids[2])?.number, "AJE-1")
        XCTAssertEqual(e.entry(ids[0])?.number, "AJE-2")
        XCTAssertEqual(e.entry(ids[1])?.number, "AJE-3")
        // Entries of another kind are left alone.
        XCTAssertTrue(e.journalEntries.contains { $0.number == "RJE-1" })
        XCTAssertEqual(Reports(e).sortedEntries().filter { $0.type == .adjusting }.map(\.id), plan.order)
    }

    func testSeveralEntriesMoveTogetherKeepingTheirOrder() throws {
        let (e, ids) = try threeEntries(["AJE-1", "AJE-2", "AJE-3"])
        let plan = try XCTUnwrap(e.planReorder(moving: [ids[0], ids[1]], target: ids[2], after: true))
        XCTAssertEqual(plan.order, [ids[2], ids[0], ids[1]])
        // Dropping an entry where it already is moves nothing.
        XCTAssertNil(e.planReorder(moving: [ids[0]], target: ids[1], after: false))
        XCTAssertNil(e.planReorder(moving: [ids[1]], target: ids[1], after: true))
    }

    func testGapsInTheNumbersLeaveAChoice() throws {
        var (e, ids) = try threeEntries(["AJE-1", "AJE-2", "AJE-5"])
        let plan = try XCTUnwrap(e.planReorder(moving: [ids[2]], target: ids[0], after: false))
        XCTAssertTrue(plan.ambiguous)
        XCTAssertEqual(plan.sameNumbers, ["AJE-1", "AJE-2", "AJE-5"])
        XCTAssertEqual(plan.fromOne, ["AJE-1", "AJE-2", "AJE-3"])
        try e.applyReorder(plan, numbers: try XCTUnwrap(plan.sameNumbers))
        XCTAssertEqual(e.entry(ids[2])?.number, "AJE-1")
        XCTAssertEqual(e.entry(ids[1])?.number, "AJE-5")
    }

    func testNumbersThatArentASeriesCanOnlyBeNumberedAfresh() throws {
        let (e, ids) = try threeEntries(["AJE-1", "Depreciation", "AJE-3"])
        let moving = e.journalEntries.first { $0.number == "Depreciation" }!.id
        let plan = try XCTUnwrap(e.planReorder(moving: [moving], target: ids[0], after: false))
        XCTAssertNil(plan.sameNumbers)
        XCTAssertTrue(plan.ambiguous)
        XCTAssertEqual(plan.fromOne, ["AJE-1", "AJE-2", "AJE-3"])
    }

    func testAnEntryCantBeDraggedIntoAnotherKind() throws {
        var (e, ids) = try threeEntries(["AJE-1", "AJE-2", "AJE-3"])
        let rje = e.journalEntries.first { $0.number == "RJE-1" }!.id
        XCTAssertNil(e.planReorder(moving: [rje], target: ids[0], after: false))
        // A plan can't hand out a number another entry already has.
        let plan = try XCTUnwrap(e.planReorder(moving: [ids[2]], target: ids[0], after: false))
        XCTAssertThrowsError(try e.applyReorder(plan, numbers: ["RJE-1", "AJE-2", "AJE-3"]))
        XCTAssertThrowsError(try e.applyReorder(plan, numbers: ["AJE-1", "AJE-1", "AJE-3"]))
    }

    // MARK: Importing names whole

    func testNumbersAreSplitFromNamesUnlessToldNotTo() throws {
        let sheet = RawSheet(name: "s", rows: TBImporter.parseCSV("Account,Debit,Credit\n1000 Cash,100,\n2024 Bonus Accrual,,100\n"))
        var mapping = TBImporter.guess(sheet)
        XCTAssertTrue(mapping.splitNumbers)
        var rows = TBImporter.evaluate(sheet, mapping, sourceName: "x").tb.rows
        XCTAssertEqual(rows.map(\.number), ["1000", "2024"])
        XCTAssertEqual(rows.map(\.name), ["Cash", "Bonus Accrual"])

        mapping.splitNumbers = false
        rows = TBImporter.evaluate(sheet, mapping, sourceName: "x").tb.rows
        XCTAssertEqual(rows.map(\.number), ["", ""])
        XCTAssertEqual(rows.map(\.name), ["1000 Cash", "2024 Bonus Accrual"])
        XCTAssertEqual(rows.map(\.amount), [m("100"), m("-100")])
    }

    func testASavedLayoutRemembersNamesKeptWhole() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("layouts-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let header = ["Account", "Debit", "Credit"]
        let sheet = RawSheet(name: "s", rows: [header, ["1000 Cash", "100", ""], ["2024 Bonus Accrual", "", "100"]])
        var mapping = TBImporter.guess(sheet)
        mapping.splitNumbers = false
        ImportProfiles.remember(mapping, header: header, to: url)
        let guessed = TBImporter.guess(sheet, profiles: ImportProfiles.load(url))
        XCTAssertTrue(guessed.fromSavedLayout)
        XCTAssertFalse(guessed.splitNumbers)
        // A layout saved before the switch existed splits, as it always did.
        let old = try JSONDecoder().decode(ImportProfile.self, from: Data(#"{"signature":"a|b","roles":["accountName","balance"],"sign":"debitPositive","savedAt":"2025-01-31T00:00:00Z"}"#.utf8))
        XCTAssertNil(old.splitNumbers)
    }
}
