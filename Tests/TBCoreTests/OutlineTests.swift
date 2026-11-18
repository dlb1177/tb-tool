import XCTest
@testable import TBCore

/// Subgroups, the grouping reports, reversing roll forwards, rows brought in by hand on import,
/// the account type filter, and where a missing file was last seen.
final class OutlineTests: XCTestCase {

    func m(_ s: String) -> Money { Money.parse(s)!.value }

    func line(_ entity: String, _ account: String, _ amount: String, _ memo: String = "") -> JELine {
        JELine(entity: entity, account: account, amount: m(amount), memo: memo)
    }

    func sample() throws -> Engagement { try TBCoreTests().sampleEngagement() }

    func money(_ t: ReportTable, row: String, column: String) -> Money {
        let c = t.columns.firstIndex { $0.title == column }!
        if case .money(let v) = t.rows.first(where: { $0.id == row })!.cells[c] { return v }
        return .zero
    }

    /// 808 Legal and professional fees with two subgroups, one account in each and one left directly in the grouping.
    func grouped() throws -> (Engagement, office: Grouping, fees: Grouping) {
        var e = try sample()
        let office = try e.addGrouping(code: "", name: "Office", section: "", parent: "808")
        let fees = try e.addGrouping(code: "808F", name: "Fees", section: "ignored", parent: "808")
        e.setGrouping(office.id, forAccounts: ["51160"])
        e.setGrouping(fees.id, forAccounts: ["51040", "51130"])
        e.setGrouping("808", forAccounts: ["51180"])
        e.setGrouping("802", forAccounts: ["40000"])
        return (e, office, fees)
    }

    // MARK: Subgroups

    func testSubgroupsSitUnderTheirGrouping() throws {
        let (e, office, fees) = try grouped()
        XCTAssertEqual(office.id, "808/OFFICE")
        XCTAssertEqual(office.section, DefaultGroupings.section8825)  // taken from the parent
        XCTAssertEqual(fees.section, DefaultGroupings.section8825)
        XCTAssertEqual(e.subgroups(of: "808").map(\.name), ["Fees", "Office"])  // the one with a code first, then by name
        XCTAssertEqual(e.parentGrouping(of: office)?.id, "808")
        // They follow their parent in the list, and the outline nests them.
        let at = e.groupings.firstIndex { $0.id == "808" }!
        XCTAssertEqual(e.groupings[(at + 1)...(at + 2)].map(\.id), [fees.id, office.id])
        XCTAssertEqual(e.groupingOutline.first { $0.grouping.id == office.id }?.depth, 1)
        XCTAssertEqual(e.groupingOutline.count, e.groupings.count)
        // A blank code reports under the parent's; its own code wins when it has one.
        XCTAssertEqual(e.groupingCode(office.id), "808")
        XCTAssertEqual(e.groupingCode(fees.id), "808F")
        XCTAssertEqual(e.groupingLabel(office.id), "808 · LEGAL AND PROF FEE › Office")
        XCTAssertEqual(e.issues(), [])
        XCTAssertEqual(try Store.decode(Store.encode(e)), e)

        // One level deep, unique names under a parent, and a grouping with subgroups can't be nested.
        var x = e
        XCTAssertThrowsError(try x.addGrouping(code: "", name: "Deeper", section: "", parent: office.id))
        XCTAssertThrowsError(try x.addGrouping(code: "", name: "office", section: "", parent: "808"))
        XCTAssertThrowsError(try x.addGrouping(code: "", name: "No code", section: "8825 Accounts"))
        XCTAssertThrowsError(try x.updateGrouping("808", code: "815", name: "X", section: "", parent: "802"))
        // A subgroup can move to another grouping, taking that grouping's section.
        try x.updateGrouping(fees.id, code: "", name: "Fees", section: "", parent: "L13")
        XCTAssertEqual(x.grouping(fees.id)?.section, DefaultGroupings.sectionL)
        XCTAssertEqual(x.groupingCode(fees.id), "L13")
        XCTAssertEqual(x.groupings[x.groupings.firstIndex { $0.id == "L13" }! + 1].id, fees.id)
        XCTAssertEqual(x.account("51040")?.grouping, fees.id)

        // Deleting a subgroup moves its accounts up; deleting the grouping takes its subgroups with it.
        var d = e
        d.deleteGrouping(office.id)
        XCTAssertEqual(d.account("51160")?.grouping, "808")
        d.deleteGrouping("808")
        XCTAssertNil(d.grouping(fees.id))
        XCTAssertNil(d.account("51040")?.grouping)
        XCTAssertNil(d.account("51160")?.grouping)
        XCTAssertEqual(d.issues(), [])

        // A file edited by hand: a subgroup pointing nowhere is reported and treated as its own grouping.
        var broken = e
        broken.groupings[broken.groupings.firstIndex { $0.id == office.id }!].parent = "NOPE"
        XCTAssertEqual(broken.issues().count, 1)
        XCTAssertNil(broken.parentGrouping(of: broken.grouping(office.id)!))
        XCTAssertTrue(Reports(broken).groupingSummary(basis: .book, detail: false).rows.contains { $0.id == "g:\(office.id)" && $0.parentRowID == nil })
    }

    func testGroupingSummaryNestsSubgroupsAndShowsNetIncome() throws {
        let (e, office, fees) = try grouped()
        let ledger = Ledger(e)
        let reports = Reports(e)
        let expected = ["51160", "51040", "51130", "51180"].map { ledger.consolidated(.book, account: $0) }

        let summary = reports.groupingSummary(basis: .book, detail: false)
        XCTAssertEqual(Set(summary.rows.map(\.id)).count, summary.rows.count)
        let ids = summary.rows.map(\.id)
        let at = ids.firstIndex(of: "g:808")!
        // The grouping, then its subgroups indented, then what it holds outside them.
        XCTAssertEqual(Array(ids[at...(at + 3)]), ["g:808", "g:\(fees.id)", "g:\(office.id)", "g:808:direct"])
        XCTAssertEqual(summary.rows[at].cells[1], .text("LEGAL AND PROF FEE"))
        XCTAssertEqual(summary.rows[at + 2].cells[1], .text("    Office"))
        XCTAssertEqual(summary.rows[at + 3].cells[1], .text("    Not in a subgroup"))
        XCTAssertEqual(summary.rows[at].groupingID, "808")
        XCTAssertEqual(summary.rows[at + 1].groupingID, fees.id)
        XCTAssertEqual(summary.rows[at + 1].parentRowID, "g:808")
        XCTAssertEqual(money(summary, row: "g:808", column: "Consolidated"), expected.sum())
        XCTAssertEqual(money(summary, row: "g:\(office.id)", column: "Consolidated"), expected[0])
        XCTAssertEqual(money(summary, row: "g:\(fees.id)", column: "Consolidated"), expected[1] + expected[2])
        XCTAssertEqual(money(summary, row: "g:808:direct", column: "Consolidated"), expected[3])

        // Net income in every column, matching the consolidating trial balance.
        let consolidating = reports.consolidating(basis: .book, hideZero: true)
        XCTAssertEqual(summary.rows.last?.id, "income")
        XCTAssertEqual(summary.rows[summary.rows.count - 2].id, "total")
        XCTAssertEqual(Array(summary.rows.last!.cells.dropFirst(2)), Array(consolidating.rows.last!.cells.dropFirst(3)))
        XCTAssertEqual(money(summary, row: "income", column: "Consolidated"), ledger.consolidatedNetIncome(.book))
        XCTAssertFalse(ledger.consolidatedNetIncome(.book).isZero)
        XCTAssertEqual(money(summary, row: "total", column: "Consolidated"), .zero)

        // Filtering a summary doesn't count a subgroup twice when its grouping is shown too.
        let shown = summary.filtered("", filters: FilterSet(conditions: [FilterCondition(column: "Code", op: .startsWith, value: "808")]))
        XCTAssertEqual(shown.rows.filter { $0.style == .normal }.map(\.id), ["g:808", "g:\(fees.id)"])
        XCTAssertEqual(money(shown, row: "filtered-total", column: "Consolidated"), expected.sum())
        let onlySub = summary.filtered("", filters: FilterSet(conditions: [FilterCondition(column: "Grouping", op: .equals, value: "fees")]))
        XCTAssertEqual(onlySub.rows.filter { $0.style == .normal }.map(\.id), ["g:\(fees.id)"])
        XCTAssertEqual(money(onlySub, row: "filtered-total", column: "Consolidated"), expected[1] + expected[2])

        // Detail: the same outline with each grouping and subgroup opened to its accounts.
        let detail = reports.groupingSummary(basis: .book, detail: true)
        XCTAssertEqual(Set(detail.rows.map(\.id)).count, detail.rows.count)
        let d = detail.rows.map(\.id)
        let from = d.firstIndex(of: "g:808")!
        XCTAssertEqual(Array(d[from...(from + 7)]), [
            "g:808", "g:\(fees.id)", "g:\(fees.id):a:51040", "g:\(fees.id):a:51130", "g:\(office.id)", "g:\(office.id):a:51160",
            "g:808:direct", "g:808:a:51180",
        ])
        XCTAssertEqual(detail.rows[from].style, .subtotal)
        XCTAssertEqual(detail.rows[from + 5].style, .normal)
        XCTAssertEqual(detail.rows[from + 5].accountID, "51160")
        XCTAssertEqual(detail.rows[from + 5].cells[1], .text("        Office Supplies"))
        XCTAssertEqual(money(detail, row: "g:808", column: "Consolidated"), expected.sum())
        XCTAssertEqual(detail.rows.last?.id, "income")
        // A grouping with no subgroups lists its accounts straight under it.
        let rents = d.firstIndex(of: "g:802")!
        XCTAssertEqual(d[rents + 1], "g:802:a:40000")
        // The account rows of the detail add up to the grand total (zero).
        var sum = Money.zero
        let last = detail.columns.count - 1
        for r in detail.rows where r.style == .normal { if case .money(let v) = r.cells[last] { sum += v } }
        XCTAssertEqual(sum, .zero)
    }

    func testGroupingDrillDownListsTheAccounts() throws {
        let (e, office, fees) = try grouped()
        let ledger = Ledger(e)
        let reports = Reports(e)
        let t = reports.groupingAccounts(groupingID: "808", basis: .book)
        XCTAssertEqual(t.title, "808 · LEGAL AND PROF FEE")
        XCTAssertEqual(t.columns.map(\.title).suffix(3), ["Combined", "Eliminations", "Consolidated"])
        XCTAssertEqual(t.columns.count, 2 + e.entities.count + 3)
        XCTAssertEqual(t.rows.map(\.id), ["g:\(fees.id)", "a:51040", "a:51130", "g:\(office.id)", "a:51160", "direct", "a:51180", "total"])
        let total = ["51160", "51040", "51130", "51180"].map { ledger.consolidated(.book, account: $0) }.sum()
        XCTAssertEqual(money(t, row: "total", column: "Consolidated"), total)
        XCTAssertEqual(money(t, row: "total", column: "Consolidated"), money(reports.groupingSummary(basis: .book, detail: false), row: "g:808", column: "Consolidated"))
        XCTAssertEqual(t.rows[1].accountID, "51040")
        // A subgroup on its own, and a grouping with none: a plain list.
        let sub = reports.groupingAccounts(groupingID: fees.id, basis: .book)
        XCTAssertEqual(sub.title, "808 · LEGAL AND PROF FEE › Fees")
        XCTAssertEqual(sub.rows.map(\.id), ["a:51040", "a:51130", "total"])
        XCTAssertEqual(reports.groupingAccounts(groupingID: "802", basis: .book).rows.map(\.id), ["a:40000", "total"])
        // An entry posted to an account in the grouping shows up in it.
        var posted = e
        try posted.post(JournalEntry(number: "AJE-1", type: .adjusting, date: "2026-12-31",
                                     lines: [line("ashford", "51040", "250"), line("ashford", "23000", "-250")]))
        XCTAssertEqual(money(Reports(posted).groupingAccounts(groupingID: "808", basis: .book), row: "total", column: "Consolidated"), total + m("250"))
        // With prior years, the PP columns follow.
        XCTAssertEqual(reports.groupingAccounts(groupingID: "802", basis: .book, prior: 2).columns.count, t.columns.count)
    }

    func testHideZeroRowsEverywhere() throws {
        var (e, office, _) = try grouped()
        // An account that is on a trial balance at zero, in a subgroup of its own.
        _ = try e.addAccount(number: "51999", name: "Unused Expense", type: .expense)
        e.entities[e.entities.firstIndex { $0.id == "ashford" }!].balances.append(Balance(account: "51999", amount: .zero))
        let lone = try e.addGrouping(code: "", name: "Empty", section: "", parent: "808")
        e.setGrouping(lone.id, forAccounts: ["51999"])
        XCTAssertEqual(e.issues(), [])
        let reports = Reports(e)

        for detail in [false, true] {
            let hidden = reports.groupingSummary(basis: .book, detail: detail, hideZero: true)
            let shown = reports.groupingSummary(basis: .book, detail: detail, hideZero: false)
            XCTAssertFalse(hidden.rows.contains { $0.id == "g:\(lone.id)" })
            XCTAssertTrue(shown.rows.contains { $0.id == "g:\(lone.id)" })
            XCTAssertEqual(shown.rows.contains { $0.accountID == "51999" }, detail)
            XCTAssertEqual(money(hidden, row: "total", column: "Consolidated"), .zero)
            XCTAssertEqual(money(shown, row: "g:808", column: "Consolidated"), money(hidden, row: "g:808", column: "Consolidated"))
            XCTAssertEqual(shown.rows.last, hidden.rows.last)  // net income doesn't depend on what is hidden
        }
        XCTAssertFalse(reports.groupingAccounts(groupingID: "808", basis: .book, hideZero: true).rows.contains { $0.id == "g:\(lone.id)" })
        XCTAssertTrue(reports.groupingAccounts(groupingID: "808", basis: .book, hideZero: false).rows.contains { $0.accountID == "51999" })
        XCTAssertTrue(reports.workbook(hideZero: false)[0].rows.contains { $0.accountID == "51999" })
        XCTAssertFalse(reports.workbook()[0].rows.contains { $0.accountID == "51999" })

        // The long-format data: every row unless asked, and never a row with an amount in it dropped.
        let tidy = reports.tidy(), trimmed = reports.tidy(hideZero: true)
        func allZero(_ r: ReportRow) -> Bool { r.cells.allSatisfy { if case .money(let v) = $0 { return v.isZero }; return true } }
        XCTAssertTrue(tidy.rows.contains { $0.accountID == "51999" })
        XCTAssertFalse(trimmed.rows.contains { $0.accountID == "51999" })
        XCTAssertEqual(trimmed.rows.map(\.id), tidy.rows.filter { !allZero($0) }.map(\.id))
        // It names the grouping an account rolls up to and its subgroup.
        let row = tidy.rows.first { $0.accountID == "51160" }!
        let col = { (title: String) in row.cells[tidy.columns.firstIndex { $0.title == title }!] }
        XCTAssertEqual(col("Grouping Code"), .text("808"))
        XCTAssertEqual(col("Grouping"), .text("LEGAL AND PROF FEE"))
        XCTAssertEqual(col("Subgroup"), .text("Office"))
        XCTAssertEqual(office.name, "Office")
    }

    func testSubgroupsTravelWithGroupingLists() throws {
        let (e, office, fees) = try grouped()
        let list = GroupingTransfer.list(of: e)
        XCTAssertEqual(try GroupingTransfer.decodeJSON(GroupingTransfer.json(list), name: "x").groupings, e.groupings)
        XCTAssertEqual(try GroupingTransfer.fromTable(TBImporter.parseCSV(GroupingTransfer.csv(list)), name: "x").groupings, e.groupings)

        // A list written by hand: the parent named by its code, the subgroup's own code left blank.
        let sheet = "Section,Code,Name,Subgroup Of\nPage 1,S19,OTHER DEDUCTIONS,\n,,Travel,S19\n,S19B,Meals,S19\nPage 1,S7,OFFICER COMP,\n,,Orphan,NOPE\n"
        let scorp = try GroupingTransfer.fromTable(TBImporter.parseCSV(sheet), name: "S Corp").groupings
        // Whatever order the sheet was in, the list is kept by code: S7 before S19, the subgroup with a code first.
        XCTAssertEqual(scorp.map(\.name), ["OFFICER COMP", "OTHER DEDUCTIONS", "Meals", "Travel", "Orphan"])
        XCTAssertEqual(scorp.map(\.parent), [nil, nil, "S19", "S19", nil])
        XCTAssertEqual(scorp[3].id, "S19/TRAVEL")
        XCTAssertEqual(Set(scorp.map(\.id)).count, 5)

        // Imported into another file: the subgroups arrive under their grouping, assignments kept.
        var other = try sample()
        other.setGrouping("808", forAccounts: ["51160"])
        let plan = other.planGroupingImport(list, mode: .merge)
        XCTAssertEqual(plan.added.map(\.id), [fees.id, office.id])
        other.applyGroupingImport(plan)
        XCTAssertEqual(other.subgroups(of: "808").map(\.id), [fees.id, office.id])
        XCTAssertEqual(other.issues(), [])

        // A chart export carries an account's subgroup into a file that doesn't have it yet.
        var third = try sample()
        let chart = try ChartTransfer.decodeJSON(ChartTransfer.json(ChartTransfer.chart(of: e)), name: "x")
        third.applyChartImport(third.planChartImport(chart))
        XCTAssertEqual(third.account("51160")?.grouping, office.id)
        XCTAssertEqual(third.parentGrouping(of: third.grouping(office.id)!)?.id, "808")
        XCTAssertEqual(third.issues(), [])
    }

    // MARK: Groupings keep themselves in order

    func testGroupingsSortByCodeWhereverTheyAreShown() throws {
        var e = try sample()
        func codes(_ section: String) -> [String] { e.topGroupings(in: section).map(\.code) }
        // A new grouping falls into place by its code instead of landing at the end of its section.
        _ = try e.addGrouping(code: "802B", name: "OTHER RENTAL RECEIPTS", section: DefaultGroupings.section8825)
        XCTAssertEqual(Array(codes(DefaultGroupings.section8825).prefix(4)), ["802", "802B", "803", "804"])
        let stored = e.groupings.map(\.id)
        XCTAssertEqual(stored.firstIndex(of: "802B"), stored.firstIndex(of: "802")! + 1)  // and the file keeps it there
        // Numbers are read as numbers: 2 before 10, K13A before K13V before K13W.
        _ = try e.addGrouping(code: "3", name: "GROSS PROFIT", section: DefaultGroupings.sectionPage1)
        XCTAssertEqual(Array(codes(DefaultGroupings.sectionPage1).prefix(6)), ["1A", "1B", "2", "3", "7", "9"])
        XCTAssertEqual(codes(DefaultGroupings.sectionPage1).last, "20")
        XCTAssertEqual(codes(DefaultGroupings.sectionK).filter { $0.hasPrefix("K13") }, ["K13A", "K13V", "K13W"])
        // Changing a code moves it; the sections themselves stay in the order they were set up.
        try e.updateGrouping("802B", code: "816", name: "OTHER RENTAL RECEIPTS", section: "")
        XCTAssertEqual(codes(DefaultGroupings.section8825).last, "816")
        XCTAssertEqual(e.groupingSections, [DefaultGroupings.section8825, DefaultGroupings.sectionK, DefaultGroupings.sectionPage1,
                                            DefaultGroupings.sectionL, DefaultGroupings.sectionOther])
        // Subgroups without codes go by name.
        XCTAssertEqual(e.subgroups(of: "815").map(\.name), ["AMORTIZATION", "GUARANTEED PAYMENTS", "LAWN CARE", "MANAGEMENT FEES", "MISCELLANEOUS", "OFFICE EXPENSE"])
        _ = try e.addGrouping(code: "", name: "Bank fees", section: "", parent: "815")
        XCTAssertEqual(e.subgroups(of: "815").map(\.name).prefix(2), ["AMORTIZATION", "Bank fees"])
        XCTAssertEqual(e.groupingOutline.map(\.grouping.id), e.groupings.map(\.id))  // what is shown is what is stored
        XCTAssertEqual(e.issues(), [])

        // The reports follow the same order.
        e.setGrouping("802B", forAccounts: ["40000"])  // its id is still the one it was created with; its code is now 816
        e.setGrouping("803", forAccounts: ["51000"])
        e.setGrouping("802", forAccounts: ["42000"])
        func reportCodes(_ x: Engagement) -> [String] {
            Reports(x).groupingSummary(basis: .book, detail: false).rows.compactMap(\.groupingID).map { x.groupingCode($0) }
        }
        XCTAssertEqual(reportCodes(e), ["802", "803", "816"])

        // A file whose list was saved out of order (by an earlier version, or by hand) is shown in order anyway.
        var old = e
        old.groupings = e.groupingSections.flatMap { section in e.groupings.filter { $0.section == section }.reversed() }
        XCTAssertNotEqual(old.groupings, e.groupings)
        XCTAssertEqual(old.groupingOutline.map(\.grouping.id), e.groupingOutline.map(\.grouping.id))
        XCTAssertEqual(reportCodes(old), ["802", "803", "816"])
        XCTAssertEqual(Reports(old).groupingSummary(basis: .book, detail: true).rows.map(\.id), Reports(e).groupingSummary(basis: .book, detail: true).rows.map(\.id))
    }

    // MARK: Groupings and account types go together

    func testGroupingsCarryAnAccountTypeAndAccountsFollowIt() throws {
        var e = try sample()
        // The built-in list says what belongs where; a subgroup uses its grouping's type; a memo line takes anything.
        XCTAssertEqual(e.groupingType("L01"), .asset)
        XCTAssertEqual(e.groupingType("L15"), .liability)
        XCTAssertEqual(e.groupingType("L21"), .equity)
        XCTAssertEqual(e.groupingType("802"), .revenue)
        XCTAssertEqual(e.groupingType("815"), .expense)
        XCTAssertNil(e.grouping("815-MGMT")?.type)
        XCTAssertEqual(e.groupingType("815-MGMT"), .expense)
        XCTAssertNil(e.groupingType("MEM"))
        XCTAssertTrue(DefaultGroupings.list.filter { $0.parent == nil && $0.type == nil }.map(\.id) == ["MEM"])

        // Putting an account in a grouping gives it the grouping's type.
        XCTAssertEqual(e.account("51040")?.type, .expense)
        XCTAssertEqual(e.setGrouping("L01", forAccounts: ["51040", "10001"]), 1)  // 10001 was an asset already
        XCTAssertEqual(e.account("51040")?.type, .asset)
        XCTAssertEqual(e.setGrouping("815-MGMT", forAccounts: ["51040"]), 1)
        XCTAssertEqual(e.account("51040")?.type, .expense)
        XCTAssertEqual(e.setGrouping("MEM", forAccounts: ["51040"]), 0)          // any type: left alone
        XCTAssertEqual(e.setGrouping(nil, forAccounts: ["51040"]), 0)
        XCTAssertEqual(e.account("51040")?.type, .expense)
        _ = e.applyGroupingMap(csv: "49600,L08\n")
        XCTAssertEqual(e.account("49600")?.type, .asset)
        XCTAssertEqual(e.issues(), [])

        // A new grouping is given its type; a subgroup never has one of its own.
        let deposits = try e.addGrouping(code: "L18", name: "TENANT DEPOSITS", section: DefaultGroupings.sectionL, type: .liability)
        XCTAssertEqual(deposits.type, .liability)
        let sub = try e.addGrouping(code: "", name: "Security", section: "", parent: deposits.id, type: .asset)
        XCTAssertNil(sub.type)
        XCTAssertEqual(e.groupingType(sub.id), .liability)
        e.setGrouping(sub.id, forAccounts: ["23250"])
        e.setGrouping(deposits.id, forAccounts: ["23000"])
        // Changing the grouping's type carries its accounts, and its subgroups' accounts, with it.
        try e.updateGrouping(deposits.id, code: "L18", name: "TENANT DEPOSITS", section: "", parent: nil, type: .asset)
        XCTAssertEqual(e.account("23000")?.type, .asset)
        XCTAssertEqual(e.account("23250")?.type, .asset)
        try e.updateGrouping(deposits.id, code: "L18", name: "TENANT DEPOSITS", section: "", parent: nil, type: .liability)
        XCTAssertEqual(e.account("23250")?.type, .liability)
        // Editing something else leaves the type alone.
        try e.updateGrouping(deposits.id, code: "L18", name: "DEPOSITS HELD", section: "")
        XCTAssertEqual(e.grouping(deposits.id)?.type, .liability)
        XCTAssertEqual(try Store.decode(Store.encode(e)), e)
        XCTAssertTrue(String(data: Store.encode(e), encoding: .utf8)!.contains("\"section\": \"Sch. L Accounts\", \"type\": \"liability\""))
        // Lists travel with their types, as JSON and as a sheet with an Account Type column.
        let list = GroupingTransfer.list(of: e)
        XCTAssertEqual(try GroupingTransfer.decodeJSON(GroupingTransfer.json(list), name: "x").groupings, e.groupings)
        XCTAssertEqual(try GroupingTransfer.fromTable(TBImporter.parseCSV(GroupingTransfer.csv(list)), name: "x").groupings, e.groupings)
    }

    func testAnAccountsTypeCanOnlyComeFromItsGrouping() throws {
        var e = try sample()
        e.setGrouping("L01", forAccounts: ["10001", "10003"])
        e.setGrouping("815-MGMT", forAccounts: ["51155"])
        /// True when every grouped account has exactly its grouping's type.
        func consistent(_ x: Engagement) -> Bool {
            x.accounts.allSatisfy { a in x.groupingType(a.grouping).map { $0 == a.type } ?? true }
        }
        XCTAssertTrue(consistent(e))

        // There is no way to give a grouped account another type: the grouping's stands.
        e.updateAccount("10003") { $0.type = .expense }
        XCTAssertEqual(e.account("10003")?.type, .asset)
        e.updateAccount("51155") {
            $0.type = .asset
            $0.name = "Management Fee"
        }
        XCTAssertEqual(e.account("51155")?.type, .expense)
        XCTAssertEqual(e.account("51155")?.name, "Management Fee")  // everything else about the account can change
        // Moving the account to another grouping is what changes its type.
        e.updateAccount("51155") { $0.grouping = "L13" }
        XCTAssertEqual(e.account("51155")?.type, .asset)
        XCTAssertTrue(consistent(e))

        // Every way the grouping list can change as a whole leaves the accounts in step with it.
        var source = try sample()
        source.setGrouping("L15", forAccounts: ["10001"])          // the other file calls it a payable
        source.setGrouping("807", forAccounts: ["51080"])
        var viaChart = e
        var o = ChartImportOptions()
        o.overwriteGroupings = true
        let plan = viaChart.planChartImport(ChartTransfer.chart(of: source), options: o)
        XCTAssertEqual(plan.changes.first { $0.accountID == "10001" }?.newType, .liability)  // and the preview says so
        viaChart.applyChartImport(plan)
        XCTAssertEqual(viaChart.account("10001")?.type, .liability)
        XCTAssertTrue(consistent(viaChart))

        var relisted = e
        var list = GroupingTransfer.list(of: e)
        list.groupings[list.groupings.firstIndex { $0.id == "L01" }!].type = .equity
        relisted.applyGroupingImport(relisted.planGroupingImport(list, mode: .replace))
        XCTAssertEqual(relisted.account("10001")?.type, .equity)
        XCTAssertTrue(consistent(relisted))
        relisted.resetGroupingsToDefault()
        XCTAssertEqual(relisted.account("10001")?.type, .asset)
        XCTAssertTrue(consistent(relisted))

        // A file that says otherwise — edited by hand, or from before the type came from the grouping —
        // is put right when it is opened. A grouping with no type leaves its accounts as they are.
        var old = try sample()
        _ = try old.addGrouping(code: "X1", name: "STORAGE UNITS", section: DefaultGroupings.sectionOther)
        old.setGrouping("L01", forAccounts: ["10001"])
        old.setGrouping("X1", forAccounts: ["14150"])
        var json = String(data: Store.encode(old), encoding: .utf8)!
        json = json.replacingOccurrences(of: "\"schemaVersion\": 5", with: "\"schemaVersion\": 3")
        json = json.replacingOccurrences(of: #", "type": "(asset|liability|equity|revenue|expense)" \}"#, with: " }", options: .regularExpression)
        json = json.replacingOccurrences(of: "\"name\": \"Ashford Checking (1042) - 2\", \"type\": \"asset\"", with: "\"name\": \"Ashford Checking (1042) - 2\", \"type\": \"expense\"")
        XCTAssertFalse(json.contains("\"section\": \"Sch. L Accounts\", \"type\""))
        let asWritten = try Store.decode(Data(json.utf8), aligningTypes: false)
        XCTAssertEqual(asWritten.account("10001")?.type, .expense)
        XCTAssertEqual(asWritten.grouping("L01")?.type, .asset)  // the built-in groupings take the built-in types
        XCTAssertNil(asWritten.grouping("X1")?.type)             // one of your own is "any type" until you say
        var counted = asWritten
        XCTAssertEqual(counted.alignAccountTypes(), 1)
        let opened = try Store.decode(Data(json.utf8))
        XCTAssertEqual(opened.account("10001")?.type, .asset)
        XCTAssertEqual(opened.account("14150")?.type, .asset)
        XCTAssertTrue(consistent(opened))
        XCTAssertEqual(opened, counted)
        XCTAssertEqual(opened.issues(), [])
        // Types decide what counts as income, so the file's figures follow the groupings.
        XCTAssertNotEqual(Ledger(asWritten).netIncome(.book, entity: "ashford"), Ledger(opened).netIncome(.book, entity: "ashford"))
        XCTAssertEqual(Ledger(opened).netIncome(.book, entity: "ashford"), Ledger(try sample()).netIncome(.book, entity: "ashford"))
    }

    // MARK: Accounts with no grouping

    func testUngroupedAccountsAreListed() throws {
        var e = try sample()
        XCTAssertEqual(e.ungroupedAccounts.count, e.accounts.count)  // nothing is grouped straight after an import
        XCTAssertEqual(e.ungroupedAccounts.map(\.id), e.sortedAccounts.map(\.id))
        _ = e.applyGroupingMap(csv: try String(contentsOf: TBCoreTests.root.appendingPathComponent("grouping-map.csv"), encoding: .utf8))
        XCTAssertEqual(e.ungroupedAccounts, [])
        // Clearing a grouping, deleting one, or adding an account brings the alert back.
        e.setGrouping(nil, forAccounts: ["10001"])
        e.deleteGrouping("807")
        _ = try e.addAccount(number: "59999", name: "Brand New", type: .expense)
        XCTAssertEqual(e.ungroupedAccounts.map(\.id), ["10001", "51080", "59999"])
        XCTAssertEqual(e.issues(), [])  // work left to do, not a fault in the file
        e.setGrouping("815-MISC", forAccounts: ["59999"])
        XCTAssertEqual(e.ungroupedAccounts.map(\.id), ["10001", "51080"])
    }

    // MARK: One code, one grouping

    func testGroupingCodesMustBeUnique() throws {
        var e = try sample()
        // Adding: a code that a grouping or a subgroup already has is refused, in any case.
        XCTAssertThrowsError(try e.addGrouping(code: "L01", name: "MORE CASH", section: "Sch. L Accounts")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Code L01 is already used by “L01 · CASH”"), error.localizedDescription)
        }
        XCTAssertThrowsError(try e.addGrouping(code: "l01", name: "Petty cash", section: "", parent: "L02"))
        let sub = try e.addGrouping(code: "L01P", name: "Petty cash", section: "", parent: "L01")
        XCTAssertThrowsError(try e.addGrouping(code: "L01P", name: "Another", section: "Sch. L Accounts"))
        XCTAssertThrowsError(try e.addGrouping(code: "L01P", name: "Another", section: "", parent: "L02"))
        // Subgroups may leave the code blank as often as they like: they use their grouping's.
        _ = try e.addGrouping(code: "", name: "Sweep accounts", section: "", parent: "L01")
        _ = try e.addGrouping(code: "", name: "Escrow", section: "", parent: "L01")
        // Editing: the code can't be changed to one in use; everything else can be.
        XCTAssertThrowsError(try e.updateGrouping("L02", code: "L01", name: "A/R", section: ""))
        XCTAssertThrowsError(try e.updateGrouping(sub.id, code: "L03", name: "Petty cash", section: "", parent: "L01"))
        try e.updateGrouping("L02", code: "L02", name: "ACCOUNTS RECEIVABLE", section: "")
        try e.updateGrouping("L02", code: "L02X", name: "ACCOUNTS RECEIVABLE", section: "")
        XCTAssertTrue(e.sharedGroupingCodes.isEmpty)
        XCTAssertEqual(e.issues(), [])
        XCTAssertTrue(Engagement.sharedCodes(DefaultGroupings.list).isEmpty)
    }

    func testFilesFromBeforeUniqueCodesAreFlaggedAndCombinedInOneStep() throws {
        // The list as it used to ship: six groupings sharing code 815.
        var e = try sample()
        let lines = [("815-AMORT", "AMORTIZATION"), ("815-OFFICE", "OFFICE EXPENSE"), ("815-MGMT", "MANAGEMENT FEES"),
                     ("815-LAWN", "LAWN CARE"), ("815-MISC", "MISCELLANEOUS"), ("815-GP", "GUARANTEED PAYMENTS")]
        e.groupings.removeAll { $0.id == "815" || $0.parent == "815" }
        let at = e.groupings.firstIndex { $0.id == "814" }! + 1
        e.groupings.insert(contentsOf: lines.map { Grouping(id: $0.0, code: "815", name: "OTHER - \($0.1)", section: DefaultGroupings.section8825) }, at: at)
        e.setGrouping("815-MGMT", forAccounts: ["51155"])
        e.setGrouping("815-MISC", forAccounts: ["51180"])
        let before = Reports(e).groupingSummary(basis: .book, detail: false)

        // It still opens and reports; the data check says what is wrong and how to fix it.
        XCTAssertEqual(e.sharedGroupingCodes.map(\.code), ["815"])
        XCTAssertEqual(e.issues().count, 1)
        XCTAssertTrue(e.issues()[0].hasPrefix("Code 815 is used by 6 groupings"))
        XCTAssertEqual(try Store.decode(Store.encode(e)), e)
        // An old shared code can be left alone while its grouping is renamed, but no new one can join it.
        try e.updateGrouping("815-LAWN", code: "815", name: "OTHER - LAWN AND SNOW", section: "")
        try e.updateGrouping("815-LAWN", code: "815", name: "OTHER - LAWN CARE", section: "")
        XCTAssertThrowsError(try e.addGrouping(code: "815", name: "OTHER - SECURITY", section: DefaultGroupings.section8825))

        // One step: a single 815 grouping with the six as its subgroups. Nothing an account points at moves.
        XCTAssertEqual(e.mergeSharedGroupingCodes(), 6)
        XCTAssertEqual(e.groupings, DefaultGroupings.list)
        XCTAssertEqual(e.account("51155")?.grouping, "815-MGMT")
        XCTAssertEqual(e.groupingCode("815-MGMT"), "815")
        XCTAssertEqual(e.groupingLabel("815-MGMT"), "815 · OTHER › MANAGEMENT FEES")
        XCTAssertEqual(e.issues(), [])
        XCTAssertEqual(e.mergeSharedGroupingCodes(), 0)  // nothing left to do
        // The report now shows one 815 line with the same total the separate lines added up to.
        let after = Reports(e).groupingSummary(basis: .book, detail: false)
        let old = money(before, row: "g:815-MGMT", column: "Consolidated") + money(before, row: "g:815-MISC", column: "Consolidated")
        XCTAssertEqual(money(after, row: "g:815", column: "Consolidated"), old)
        XCTAssertEqual(money(after, row: "g:815-MGMT", column: "Consolidated"), money(before, row: "g:815-MGMT", column: "Consolidated"))
        XCTAssertEqual(after.rows.first { $0.id == "g:815-MGMT" }?.parentRowID, "g:815")

        // Names with nothing in common still combine, under a plainly labelled grouping.
        let odd = Engagement.mergingSharedCodes([Grouping(id: "A", code: "7", name: "RENT", section: "P"), Grouping(id: "B", code: "7", name: "OTHER INCOME", section: "P"),
                                                 Grouping(id: "C", code: "9", name: "WAGES", section: "P")])
        XCTAssertEqual(odd.map(\.name), ["7 (combined)", "OTHER INCOME", "RENT", "WAGES"])
        XCTAssertEqual(odd.map(\.parent), [nil, "7", "7", nil])
        XCTAssertTrue(Engagement.sharedCodes(odd).isEmpty)
        // A subgroup that repeats its grouping's code simply uses it.
        let echo = Engagement.mergingSharedCodes([Grouping(id: "A", code: "7", name: "RENT", section: "P"), Grouping(id: "A1", code: "7", name: "Sub", section: "P", parent: "A")])
        XCTAssertEqual(echo.map(\.code), ["7", ""])
        // A list exported before the change comes back in as the current one.
        let legacy = GroupingList(name: "Old", groupings: DefaultGroupings.list.filter { $0.id != "815" }.map { g in
            g.parent == "815" ? Grouping(id: g.id, code: "815", name: "OTHER - \(g.name)", section: g.section) : g
        })
        XCTAssertEqual(try GroupingTransfer.decodeJSON(GroupingTransfer.json(legacy), name: "x").groupings, DefaultGroupings.list)
        XCTAssertTrue(try sample().planGroupingImport(legacy, mode: .replace).isEmpty)
        XCTAssertTrue(try sample().planGroupingImport(legacy, mode: .merge).isEmpty)
    }

    // MARK: Standard lists kept on this Mac

    func testStandardGroupingListsByEntityType() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tbtool-standards-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let partnership = Binder.entityTypes[0], scorp = Binder.entityTypes[1]
        // Out of the box: the built-in list, standard for partnerships and the fallback for everything else.
        XCTAssertEqual(GroupingLibrary.all(in: dir).map(\.name), [GroupingList.standardName])
        XCTAssertFalse(GroupingLibrary.isStandardChanged(in: dir))
        XCTAssertEqual(GroupingLibrary.list(forEntityType: partnership, in: dir).groupings, DefaultGroupings.list)
        XCTAssertEqual(GroupingLibrary.list(forEntityType: scorp, in: dir).name, GroupingList.standardName)
        XCTAssertEqual(GroupingLibrary.list(forEntityType: "", in: dir).name, GroupingList.standardName)

        // A list of your own, made the standard for S corporations.
        var mine = GroupingList(name: "S Corporation 2026", groupings: [Grouping(id: "S1A", code: "S1A", name: "GROSS RECEIPTS", section: "Page 1"),
                                                                        Grouping(id: "S19", code: "S19", name: "OTHER DEDUCTIONS", section: "Page 1")])
        try GroupingLibrary.save(mine, in: dir)
        try GroupingLibrary.setStandard(mine.name, forEntityType: scorp, in: dir)
        XCTAssertEqual(GroupingLibrary.list(forEntityType: scorp, in: dir).name, "S Corporation 2026")
        XCTAssertEqual(GroupingLibrary.list(forEntityType: scorp.uppercased(), in: dir).groupings, mine.groupings)
        XCTAssertEqual(GroupingLibrary.list(forEntityType: partnership, in: dir).name, GroupingList.standardName)
        XCTAssertEqual(GroupingLibrary.all(in: dir).map(\.name), [GroupingList.standardName, "S Corporation 2026"])

        // Updating the built-in list for a new year keeps a changed copy; it can be put back as shipped.
        var standard = GroupingLibrary.standard(in: dir)
        standard.groupings.append(Grouping(id: "K20", code: "K20", name: "OTHER INFORMATION", section: DefaultGroupings.sectionK))
        try GroupingLibrary.save(standard, in: dir)
        XCTAssertTrue(GroupingLibrary.isStandardChanged(in: dir))
        XCTAssertEqual(GroupingLibrary.standard(in: dir).groupings.count, DefaultGroupings.list.count + 1)
        XCTAssertEqual(GroupingLibrary.standard(in: dir).entityTypes, [partnership])
        // Saved lists are kept in order too: the new line sits at the end of Schedule K, not at the end of the list.
        let saved = GroupingLibrary.list(forEntityType: partnership, in: dir).groupings
        XCTAssertEqual(saved.last { $0.section == DefaultGroupings.sectionK }?.code, "K20")
        XCTAssertEqual(saved.last?.code, "MEM")
        GroupingLibrary.delete(named: GroupingList.standardName, in: dir)
        XCTAssertFalse(GroupingLibrary.isStandardChanged(in: dir))
        XCTAssertEqual(GroupingLibrary.standard(in: dir).groupings, DefaultGroupings.list)

        // Moving a type from one list to another leaves it on exactly one; clearing leaves the fallback.
        try GroupingLibrary.setStandard(GroupingList.standardName, forEntityType: scorp, in: dir)
        XCTAssertEqual(GroupingLibrary.list(forEntityType: scorp, in: dir).name, GroupingList.standardName)
        XCTAssertEqual(GroupingLibrary.all(in: dir).filter { $0.entityTypes.contains(scorp) }.count, 1)
        try GroupingLibrary.setStandard(nil, forEntityType: scorp, in: dir)
        XCTAssertEqual(GroupingLibrary.all(in: dir).filter { $0.entityTypes.contains(scorp) }.count, 0)
        // A list with a code used twice can't be saved as a standard.
        mine.groupings.append(Grouping(id: "S19B", code: "S19", name: "MORE", section: "Page 1"))
        XCTAssertThrowsError(try GroupingLibrary.save(mine, in: dir))
    }

    // MARK: Roll forward as a reversal

    func testRollForwardAsReversal() throws {
        var e = try sample()
        var accrual = JournalEntry(number: "AJE-1", type: .adjusting, date: "2026-12-31", description: "Accrue interest",
                                   lines: [line("ashford", "51100", "900", "December interest"), line("ashford", "24100", "-900")],
                                   references: [FileReference(path: "Workpapers/Interest.xlsx")])
        accrual.rollForward = .reversal
        var recurring = JournalEntry(number: "AJE-2", type: .adjusting, date: "2026-12-31", description: "Recurring",
                                     lines: [line("ashford", "51040", "10"), line("ashford", "23000", "-10")])
        recurring.rollForward = .withAmounts
        try e.post(accrual)
        try e.post(recurring)

        let summary = try e.rollForwardSummary()
        XCTAssertEqual(summary.reversed.map(\.number), ["AJE-1"])
        XCTAssertEqual(summary.withAmounts.map(\.number), ["AJE-2"])
        XCTAssertEqual(summary.entryCounts, "1 with amounts · 1 as a reversal · 0 left behind")

        let next = try e.rolledForward()
        let reversed = next.journalEntries.first { $0.number == "AJE-1" }!
        XCTAssertEqual(reversed.lines.map(\.amount), [m("-900"), m("900")])
        XCTAssertEqual(reversed.lines.map(\.memo), ["[Reversal from 2026] December interest", "[Reversal from 2026]"])
        XCTAssertEqual(reversed.lines.map(\.account), ["51100", "24100"])
        XCTAssertEqual(reversed.description, "Accrue interest")
        XCTAssertEqual(reversed.date, "2027-01-01")
        XCTAssertEqual(reversed.type, .adjusting)
        XCTAssertFalse(reversed.pending)
        XCTAssertEqual(reversed.rollForward, .none)  // it won't reverse itself again the year after
        XCTAssertEqual(reversed.references, [])
        XCTAssertNotEqual(reversed.id, accrual.id)
        XCTAssertEqual(Ledger(next).value(.aje, entity: "ashford", account: "51100"), m("-900"))
        XCTAssertEqual(next.issues(), [])
        XCTAssertEqual(try Store.decode(Store.encode(next)), next)
        XCTAssertEqual(try Store.decode(Store.encode(e)).entry(accrual.id)?.rollForward, .reversal)

        // Nothing to reverse on an entry that is still waiting for its amounts.
        var waiting = next
        var blank = JournalEntry(number: "AJE-9", type: .adjusting, date: "2027-12-31",
                                 lines: [line("ashford", "51100", "0"), line("ashford", "24100", "0")])
        blank.pending = true
        blank.rollForward = .reversal
        waiting.journalEntries.append(blank)
        XCTAssertEqual(try waiting.rollForwardSummary().reversed, [])
        XCTAssertTrue(try waiting.rollForwardSummary().notRolled.contains { $0.number == "AJE-9" })
    }

    // MARK: Import: any row can be checked or unchecked

    func testAnyImportRowCanBeBroughtInOrLeftOut() throws {
        let csv = """
        Client Co,,
        Opening adjustment,25.00,
        Account,Debit,Credit
        1000 Cash,100.00,
        ASSETS,,
        Total Fees,,60.00
        ,,65.00
        4000 Sales,,1.2.3
        ,,
        TOTAL,100.00,125.00
        """
        let sheet = RawSheet(name: "x", rows: TBImporter.parseCSV(csv))
        var mapping = ImportMapping(headerRow: 2, roles: [.accountCombined, .debit, .credit])
        var p = TBImporter.evaluate(sheet, mapping, sourceName: "x")
        XCTAssertEqual(p.rows.map(\.kind), [.aboveHeader, .aboveHeader, .header, .account, .heading, .total, .noAccount, .badAmount, .blank, .total])
        XCTAssertEqual(p.rows.map(\.included), [false, false, false, true, false, false, false, false, false, false])
        // Everything with something on it can be switched, except the header.
        XCTAssertEqual(p.rows.map(\.toggleable), [true, true, false, true, true, true, true, true, false, true])

        // Check every row that wasn't read as an account.
        for r in p.rows where r.kind != .account { mapping.setIncluded(true, row: r) }
        XCTAssertEqual(mapping.forced, [0, 1, 4, 5, 6, 7, 9])
        p = TBImporter.evaluate(sheet, mapping, sourceName: "x")
        XCTAssertEqual(p.rows.map(\.included), [true, true, false, true, true, true, true, true, false, true])
        XCTAssertEqual(p.rows.map(\.kind), [.aboveHeader, .aboveHeader, .header, .account, .heading, .total, .noAccount, .badAmount, .blank, .total])
        let got = Dictionary(uniqueKeysWithValues: p.tb.rows.map { ($0.number.isEmpty ? $0.name : $0.number, $0.amount) })
        XCTAssertEqual(got["Client Co"], .zero)                 // a heading comes in at zero
        XCTAssertEqual(got["Opening adjustment"], m("25"))      // a row above the header
        XCTAssertEqual(got["1000"], m("100"))
        XCTAssertEqual(got["ASSETS"], .zero)
        XCTAssertEqual(got["Total Fees"], m("-60"))             // an account that merely looks like a total
        XCTAssertEqual(got["Unnamed (row 7)"], m("-65"))        // an amount with no account gets a name
        XCTAssertEqual(got["4000"], .zero)                      // an unreadable amount is brought in as zero, and says so
        XCTAssertEqual(got["TOTAL"], m("-25"))
        XCTAssertTrue(p.rows[7].note.contains("Read as 0.00"))
        XCTAssertTrue(p.rows[6].note.hasPrefix("Brought in"))

        // Unchecking puts each one back, and an account row can still be left out.
        for r in p.rows { mapping.setIncluded(false, row: r) }
        XCTAssertEqual(mapping.forced, [])
        XCTAssertEqual(mapping.excluded, [3])
        p = TBImporter.evaluate(sheet, mapping, sourceName: "x")
        XCTAssertEqual(p.tb.rows.count, 0)
        XCTAssertEqual(p.rows[3].note, "Left out")
        XCTAssertEqual(p.rows[0].kind, .aboveHeader)
    }

    // MARK: An account named differently in a file than in the chart

    func testAccountNameConflictsAreFoundAndResolved() throws {
        var e = try sample()
        e.setGrouping("L01", forAccounts: ["10001"])
        e.setGrouping("807", forAccounts: ["51080"])
        // A new file for Ashford: three accounts carry a different name, one differs only in capitals,
        // one is new, and one appears on two rows.
        let csv = """
        Account,Debit,Credit
        10001 Operating Account,500.00,
        51080 Property Insurance,40.00,
        51080 Property Insurance,60.00,
        51100 Loan Interest,25.00,
        51040 BANK CHARGES   & fees,5.00,
        59999 Brand New Account,10.00,
        32000 Member's Equity - Summit Storage LLC,,640.00
        """
        let tb = try TBImporter.parse(text: csv, sourceName: "Ashford revised.csv")
        let conflicts = e.accountNameConflicts(in: tb)
        XCTAssertEqual(conflicts.map(\.number), ["10001", "51080", "51100"])
        XCTAssertEqual(conflicts[0].chartName, "Ashford Checking (1042) - 2")
        XCTAssertEqual(conflicts[0].fileName, "Operating Account")
        XCTAssertEqual(conflicts[0].grouping, "L01")
        XCTAssertEqual(conflicts[0].usedBy, ["Ashford"])
        XCTAssertEqual(conflicts[1].amount, m("100"))  // both rows
        XCTAssertEqual(conflicts[1].usedBy.count, 4)   // every property has insurance
        XCTAssertNil(conflicts[2].grouping)

        // The preview of each choice, before anything is imported.
        XCTAssertEqual(e.outcome(of: AccountNameResolution(.keepChartName), for: conflicts[0]),
                       AccountNameOutcome(number: "10001", name: "Ashford Checking (1042) - 2", grouping: "L01", isNew: false, problem: nil))
        XCTAssertEqual(e.outcome(of: AccountNameResolution(.useFileName, keepGrouping: false), for: conflicts[0]),
                       AccountNameOutcome(number: "10001", name: "Operating Account", grouping: nil, isNew: false, problem: nil))
        XCTAssertEqual(e.outcome(of: AccountNameResolution(.separateAccount(number: "10009")), for: conflicts[0]),
                       AccountNameOutcome(number: "10009", name: "Operating Account", grouping: "L01", isNew: true, problem: nil))
        XCTAssertNotNil(e.outcome(of: AccountNameResolution(.separateAccount(number: "10001")), for: conflicts[0]).problem)  // the same number
        XCTAssertNotNil(e.outcome(of: AccountNameResolution(.separateAccount(number: "14100")), for: conflicts[0]).problem)  // taken by Land
        XCTAssertNil(e.outcome(of: AccountNameResolution(.separateAccount(number: "")), for: conflicts[0]).problem)          // kept by name

        // With no decisions, the chart's names stand and the import says so (what the command line does).
        var plain = e
        let notes = try plain.importTrialBalance(tb, into: "ashford")
        XCTAssertEqual(notes.filter { $0.contains("Kept the chart name") }.count, 3)
        XCTAssertEqual(plain.account("10001")?.name, "Ashford Checking (1042) - 2")

        // Decided one way each: keep the chart's name but drop the grouping; take the file's name and keep
        // the grouping; and bring the third in as a different account that starts with the same grouping.
        var decided = e
        decided.setGrouping("809", forAccounts: ["51100"])
        let quiet = try decided.importTrialBalance(tb, into: "ashford", resolving: [
            "10001": AccountNameResolution(.keepChartName, keepGrouping: false),
            "51080": AccountNameResolution(.useFileName),
            "51100": AccountNameResolution(.separateAccount(number: "51105")),
        ])
        XCTAssertFalse(quiet.contains { $0.contains("Kept the chart name") })
        XCTAssertEqual(decided.account("10001")?.name, "Ashford Checking (1042) - 2")
        XCTAssertNil(decided.account("10001")?.grouping)
        XCTAssertEqual(decided.account("51080")?.name, "Property Insurance")  // renamed for every trial balance
        XCTAssertEqual(decided.account("51080")?.grouping, "807")
        XCTAssertEqual(decided.account("51100")?.name, "Interest Expenses")   // the original is untouched
        XCTAssertEqual(decided.account("51105")?.name, "Loan Interest")
        XCTAssertEqual(decided.account("51105")?.grouping, "809")
        XCTAssertEqual(decided.account("51105")?.type, .expense)
        XCTAssertEqual(decided.account("51040")?.name, "Bank Charges & Fees") // capitals and spacing aren't a conflict
        let l = Ledger(decided)
        XCTAssertEqual(l.value(.unadjusted, entity: "ashford", account: "51080"), m("100"))
        XCTAssertEqual(l.value(.unadjusted, entity: "ashford", account: "51105"), m("25"))
        XCTAssertEqual(l.value(.unadjusted, entity: "ashford", account: "51100"), .zero)
        XCTAssertEqual(l.value(.unadjusted, entity: "clayton", account: "51100"), Ledger(e).value(.unadjusted, entity: "clayton", account: "51100"))
        XCTAssertEqual(l.total(.unadjusted, entity: "ashford"), .zero)
        XCTAssertEqual(decided.issues(), [])
        XCTAssertEqual(decided.accountNameConflicts(in: tb).map(\.number), ["10001", "51100"])  // importing it again would ask again
        XCTAssertEqual(try Store.decode(Store.encode(decided)), decided)

        // A separate account with no number is kept by name, ungrouped if asked.
        var byName = e
        _ = try byName.importTrialBalance(tb, into: "ashford", resolving: ["51100": AccountNameResolution(.separateAccount(number: ""), keepGrouping: false)])
        XCTAssertEqual(byName.account("Loan Interest")?.number, "")
        XCTAssertNil(byName.account("Loan Interest")?.grouping)
        XCTAssertEqual(Ledger(byName).value(.unadjusted, entity: "ashford", account: "Loan Interest"), m("25"))

        // A number that is taken is refused, and nothing changes.
        var refused = e
        XCTAssertThrowsError(try refused.importTrialBalance(tb, into: "ashford", resolving: [
            "51080": AccountNameResolution(.useFileName), "51100": AccountNameResolution(.separateAccount(number: "14100")),
        ]))
        XCTAssertEqual(refused, e)

        // The same decisions apply to a prior year's balances.
        var prior = e
        _ = try prior.importPriorPeriod(tb, into: "ashford", year: 2025, resolving: [
            "10001": AccountNameResolution(.useFileName), "51100": AccountNameResolution(.separateAccount(number: "51105"), keepGrouping: false),
        ])
        XCTAssertEqual(prior.account("10001")?.name, "Operating Account")
        XCTAssertEqual(prior.account("10001")?.grouping, "L01")
        XCTAssertEqual(Ledger(prior).prior(.book, year: 2025, entity: "ashford", account: "51105"), m("25"))
        XCTAssertEqual(Ledger(prior).prior(.book, year: 2025, entity: "ashford", account: "51100"), .zero)
        XCTAssertEqual(prior.account("51080")?.name, "Insurance")  // not decided: the chart's name stands
    }

    // MARK: Filters

    func testAccountTypeFilter() throws {
        let (e, _, _) = try grouped()
        let reports = Reports(e)
        let t = reports.consolidating(basis: .book, hideZero: true)
        func ids(_ table: ReportTable, _ rule: FilterCondition) -> [String] {
            table.filtered("", filters: FilterSet(conditions: [rule])).rows.filter { $0.style == .normal }.compactMap(\.accountID)
        }
        let column = FilterCondition.accountTypeColumn
        let expenses = ids(t, FilterCondition(column: column, op: .equals, value: "Expense"))
        XCTAssertFalse(expenses.isEmpty)
        XCTAssertTrue(expenses.allSatisfy { e.account($0)?.type == .expense })
        XCTAssertEqual(Set(expenses), Set(e.accounts.filter { $0.type == .expense && Ledger(e).activeAccounts.contains($0.id) }.map(\.id)))
        let notExpenses = ids(t, FilterCondition(column: column, op: .notEquals, value: "Expense"))
        XCTAssertEqual(expenses.count + notExpenses.count, t.rows.filter { $0.style == .normal }.count)
        XCTAssertTrue(notExpenses.allSatisfy { e.account($0)?.type != .expense })
        // The filtered total is the net of what's shown: revenue and expenses together are net income, sign flipped.
        let income = t.filtered("", filters: FilterSet(matchAll: false, conditions: [
            FilterCondition(column: column, op: .equals, value: "Revenue"), FilterCondition(column: column, op: .equals, value: "Expense"),
        ]))
        XCTAssertEqual(money(income, row: "filtered-total", column: "Consolidated"), -Ledger(e).consolidatedNetIncome(.book))

        // It works on every table of accounts: one trial balance, the grouping detail, the journal.
        let one = reports.entityTrialBalance(entityID: "ashford", hideZero: false)
        XCTAssertTrue(ids(one, FilterCondition(column: column, op: .equals, value: "Asset")).allSatisfy { e.account($0)?.type == .asset })
        let detail = reports.groupingSummary(basis: .book, detail: true)
        XCTAssertEqual(Set(ids(detail, FilterCondition(column: column, op: .equals, value: "Revenue"))),
                       Set(e.accounts.filter { $0.type == .revenue && !Ledger(e).consolidated(.book, account: $0.id).isZero }.map(\.id)))
        // Rows that aren't accounts (the groupings of the summary) never match a type.
        XCTAssertEqual(ids(reports.groupingSummary(basis: .book, detail: false), FilterCondition(column: column, op: .equals, value: "Expense"))
                        .filter { e.account($0)?.type != .expense }, [])
        // "Is not" on text columns too.
        XCTAssertEqual(ids(t, FilterCondition(column: "Account", op: .notEquals, value: "51160")).count, t.rows.filter { $0.style == .normal }.count - 1)
    }

    // MARK: Where a missing file was last seen

    func testLocateStartsWhereTheFileLastWas() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent("tbtool-locate-\(UUID().uuidString)").standardizedFileURL
        try fm.createDirectory(at: folder.appendingPathComponent("Workpapers/2026"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        func last(_ path: String) -> String? { LinkFinder.lastKnownFolder(for: FileReference(path: path), folder: folder)?.standardizedFileURL.path }
        let base = folder.resolvingSymlinksInPath().path
        func resolved(_ path: String) -> String? { last(path).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } }
        // The folder the link pointed into, while it still exists.
        XCTAssertEqual(resolved("Workpapers/2026/Depreciation.xlsx"), base + "/Workpapers/2026")
        // That folder is gone: the nearest one above it that is still there.
        XCTAssertEqual(resolved("Workpapers/2026/Old/Deep/Accruals.xlsx"), base + "/Workpapers/2026")
        XCTAssertEqual(resolved("Renamed Folder/Accruals.xlsx"), base)
        // An absolute link outside the client folder.
        XCTAssertEqual(resolved(folder.appendingPathComponent("Workpapers/x.pdf").path), base + "/Workpapers")
    }
}
