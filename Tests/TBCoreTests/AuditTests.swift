import XCTest
@testable import TBCore

/// The paper trail: the change log, workpaper sign-offs, and references to a tab and cells of a workbook.
final class AuditTests: XCTestCase {

    let jordan = Actor(name: "Jordan Avery", account: "javery", computer: "Jordan's MacBook Pro", device: "00000000-0000-4000-8000-000000000001")
    let riley = Actor(name: "Riley Chen", account: "rchen", computer: "Riley's iMac", device: "00000000-0000-4000-8000-000000000002")

    func sample() throws -> Engagement { try TBCoreTests().sampleEngagement() }

    func testChangeLogIsChainedAndShowsTampering() throws {
        var e = try sample()
        XCTAssertNil(e.auditLogBreak)
        e.log("Created the file", details: ["Summit.json"], by: jordan, at: "2026-11-18T15:00:00Z")
        e.log("Post AJE-1", details: ["Posted AJE-1"], by: jordan, at: "2026-11-18T15:05:00Z")
        e.log("Mark as Reviewed", by: riley, at: "2026-11-19T09:00:00Z")
        XCTAssertEqual(e.auditLog.map(\.action), ["Created the file", "Post AJE-1", "Mark as Reviewed"])
        XCTAssertEqual(e.auditLog[2].actor, riley)
        XCTAssertEqual(Set(e.auditLog.map(\.hash)).count, 3)
        XCTAssertEqual(e.auditLog[0].hash.count, 64)
        XCTAssertNil(e.auditLogBreak)

        // It is part of the file, and reads back exactly.
        let data = Store.encode(e)
        let back = try Store.decode(data)
        XCTAssertEqual(back.auditLog, e.auditLog)
        XCTAssertEqual(Store.encode(back), data)
        XCTAssertNil(back.auditLogBreak)
        let text = String(data: data, encoding: .utf8)!
        XCTAssertTrue(text.contains("\"auditLog\": ["))
        XCTAssertTrue(text.contains("\"name\": \"Jordan Avery\", \"account\": \"javery\""))

        // A line edited afterwards, a line taken out, and a line put in each break the chain where it happened.
        var edited = e
        edited.auditLog[1].details = ["Posted AJE-1 for less"]
        XCTAssertEqual(edited.auditLogBreak, 1)
        var who = e
        who.auditLog[0].actor.name = "Someone Else"
        XCTAssertEqual(who.auditLogBreak, 0)
        var removed = e
        removed.auditLog.remove(at: 1)
        XCTAssertEqual(removed.auditLogBreak, 1)
        var inserted = e
        inserted.auditLog.insert(AuditEntry(at: "2026-11-18T15:01:00Z", action: "Nothing", details: [], actor: jordan, hash: e.auditLog[0].hash), at: 1)
        XCTAssertEqual(inserted.auditLogBreak, 1)
        // Edited in the text of the file, the same.
        let tampered = try Store.decode(Data(text.replacingOccurrences(of: "\"Post AJE-1\"", with: "\"Post AJE-9\"").utf8))
        XCTAssertEqual(tampered.auditLogBreak, 1)
        // A file from before the log has none, and nothing to say about it.
        XCTAssertFalse(String(data: Store.encode(try sample()), encoding: .utf8)!.contains("auditLog"))
    }

    func testWhatAChangeDidIsDescribed() throws {
        let before = try sample()
        XCTAssertEqual(before.changes(since: before), [])

        var e = before
        var je = JournalEntry(number: "AJE-1", type: .adjusting, date: "2026-12-31", description: "Accrue audit fee")
        je.lines = [JELine(entity: "ashford", account: "10001", amount: Money.parse("-500")!.value),
                    JELine(entity: "ashford", account: "14150", amount: Money.parse("500")!.value)]
        try e.post(je)
        XCTAssertEqual(e.changes(since: before), ["Posted AJE-1 (adjusting, Ashford): Accrue audit fee — debits 500.00"])
        XCTAssertEqual(before.changes(since: e), ["Deleted AJE-1 (adjusting): Accrue audit fee — debits 500.00"])

        var named = e
        try named.setActivityNumber("12", for: "ashford")
        try named.renameEntity("brighton", to: "Brighton Storage")
        XCTAssertEqual(named.changes(since: e), ["Ashford: activity number (none) → 12", "Renamed trial balance “Brighton” to “Brighton Storage”"])

        var regrouped = e
        _ = try regrouped.addGrouping(code: "X1", name: "STORAGE UNITS", section: DefaultGroupings.sectionOther)
        regrouped.setGrouping("X1", forAccounts: ["14150"])
        let lines = regrouped.changes(since: e)
        XCTAssertTrue(lines.contains { $0.hasPrefix("Grouping changed on 1 account: 14150: ") && $0.hasSuffix("→ X1 · STORAGE UNITS") }, "\(lines)")
        XCTAssertTrue(lines.contains("Added 1 grouping: X1 · STORAGE UNITS"), "\(lines)")

        var balances = e
        try balances.setBalances([Balance(account: "10001", amount: Money.parse("1")!.value), Balance(account: "32000", amount: Money.parse("-1")!.value)], for: "clayton")
        let changed = balances.changes(since: e)
        XCTAssertEqual(changed.count, 1)
        XCTAssertTrue(changed[0].hasPrefix("Clayton: unadjusted balances changed by hand — "), changed[0])

        var deleted = e
        try deleted.deleteEntity("west-clayton")
        XCTAssertTrue(deleted.changes(since: e).contains("Deleted trial balance “West Clayton”"))
    }

    func testSignOffs() throws {
        var e = try sample()
        let gl = "2000 Client Financials/2000.02 GL.xlsx", tb = "2000 Client Financials/2000.01 TB.xlsx"
        e.setSignOff(.reviewed, for: gl, by: riley, fileHash: "aa", at: "2026-11-19T09:00:00Z")
        e.setSignOff(.prepared, for: gl, by: jordan, fileHash: "aa", at: "2026-11-18T15:00:00Z")
        e.setSignOff(.prepared, for: tb, by: jordan, fileHash: "bb", at: "2026-11-18T15:01:00Z")
        // In order by workpaper, then prepared, reviewed, second reviewed.
        XCTAssertEqual(e.signOffs.map { "\(($0.path as NSString).lastPathComponent) \($0.level.short) \($0.actor.account)" },
                       ["2000.01 TB.xlsx P javery", "2000.02 GL.xlsx P javery", "2000.02 GL.xlsx R rchen"])
        XCTAssertEqual(e.signOff(.reviewed, for: gl)?.actor, riley)
        XCTAssertNil(e.signOff(.secondReviewed, for: gl))
        XCTAssertEqual(SignOffLevel.allCases.map(\.label), ["Prepared", "Reviewed", "Second Reviewed"])

        // Signing again replaces the mark; the fingerprint is the file's as it is now.
        e.setSignOff(.prepared, for: gl, by: riley, fileHash: "cc", at: "2026-11-20T10:00:00Z")
        XCTAssertEqual(e.signOffs(for: gl).count, 2)
        XCTAssertEqual(e.signOff(.prepared, for: gl)?.fileHash, "cc")

        // In the file, and back.
        let data = Store.encode(e)
        XCTAssertEqual(try Store.decode(data).signOffs, e.signOffs)
        XCTAssertEqual(Store.encode(try Store.decode(data)), data)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("\"level\": \"reviewed\""))

        // What the log says about a mark going on and coming off.
        var marked = e
        marked.setSignOff(.secondReviewed, for: gl, by: jordan, fileHash: "cc", at: "2026-11-21T10:00:00Z")
        XCTAssertEqual(marked.changes(since: e), ["Marked “\(gl)” as second reviewed"])
        var cleared = e
        cleared.clearSignOff(.reviewed, for: gl)
        XCTAssertEqual(cleared.changes(since: e), ["Removed the reviewed mark from “\(gl)” (it was Riley Chen, 2026-11-19T09:00:00Z)"])

        // Marks follow a workpaper that is renamed, renumbered or moved, and a folder that is renamed.
        var moved = e
        moved.relink(after: [BinderRename(from: gl, to: "2000 Client Financials/2000.05 GL.xlsx"),
                             BinderRename(from: "2000 Client Financials", to: "2100 Financials", isFolder: true)])
        XCTAssertEqual(Set(moved.signOffs.map(\.path)), ["2000 Client Financials/2000.05 GL.xlsx", "2100 Financials/2000.01 TB.xlsx"])
        XCTAssertEqual(moved.changes(since: e).filter { $0.hasPrefix("Removed") }, [])

        // The report: one row per workpaper, a pair of columns per mark.
        let report = Reports(e).signOffs()
        XCTAssertEqual(report.columns.map(\.title), ["Index", "Workpaper", "Folder", "Prepared by", "Prepared (UTC)", "Reviewed by", "Reviewed (UTC)", "Second Reviewed by", "Second Reviewed (UTC)"])
        XCTAssertEqual(report.rows.count, 2)
        XCTAssertEqual(report.rows[1].cells.prefix(7).map { cell -> String in if case .text(let s) = cell { return s }; return "" },
                       ["2000.02", "GL.xlsx", "2000 Client Financials", "Riley Chen", "2026-11-20T10:00:00Z", "Riley Chen", "2026-11-19T09:00:00Z"])

        // Next year starts with nothing signed off, and a log of its own.
        e.log("Created the file", by: jordan)
        var o = RollForwardOptions()
        o.sourceName = "Summit 2026.json"
        o.actor = riley
        let next = try e.rolledForward(o)
        XCTAssertEqual(next.signOffs, [])
        XCTAssertEqual(next.auditLog.map(\.action), ["Rolled forward from 2026"])
        XCTAssertEqual(next.auditLog[0].actor, riley)
        XCTAssertNil(next.auditLogBreak)
        XCTAssertEqual(try e.rolledForward().auditLog, [])
    }

    func testFileFingerprint() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tbtool-print-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)
        XCTAssertEqual(FileFingerprint.sha256(of: url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try Data("abd".utf8).write(to: url)
        XCTAssertNotEqual(FileFingerprint.sha256(of: url), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertNil(FileFingerprint.sha256(of: url.appendingPathExtension("missing")))
    }

    func testReferencesToATabAndCellsOfAWorkbook() throws {
        // What counts as a workbook.
        for name in ["GL.xlsx", "GL.XLSM", "old.xls", "big.xlsb", "template.xltx"] { XCTAssertTrue(FileReference(path: name).isWorkbook, name) }
        for name in ["Statement.pdf", "GL.csv", "notes.txt", "xlsx"] { XCTAssertFalse(FileReference(path: name).isWorkbook, name) }

        // Cells as typed, tidied to what Excel expects.
        XCTAssertEqual(WorkbookTabs.cells(""), "")
        XCTAssertEqual(WorkbookTabs.cells("b4"), "B4")
        XCTAssertEqual(WorkbookTabs.cells(" $B$4 : d10 "), "B4:D10")
        XCTAssertEqual(WorkbookTabs.cells("B:D"), "B:D")
        XCTAssertEqual(WorkbookTabs.cells("4:10"), "4:10")
        XCTAssertEqual(WorkbookTabs.cells("a1:b2, d5"), "A1:B2,D5")
        for bad in ["B", "4", "B4:", "B4:D", "B:4", "hello", "B4;D10", "ABCD1", "B0", "A1:B2:C3"] { XCTAssertNil(WorkbookTabs.cells(bad), bad) }

        // The tabs of a workbook, in order — and nothing for a file that isn't one.
        let fixtures = TBCoreTests.root
        let tabs = try XCTUnwrap(WorkbookTabs.names(of: fixtures.appendingPathComponent("Ashford - QuickBooks style.xlsx")))
        XCTAssertEqual(tabs, try SourceReader.read(url: fixtures.appendingPathComponent("Ashford - QuickBooks style.xlsx")).map(\.name))
        XCTAssertFalse(tabs.isEmpty)
        XCTAssertNil(WorkbookTabs.names(of: fixtures.appendingPathComponent("grouping-map.csv")))
        XCTAssertNil(WorkbookTabs.names(of: fixtures.appendingPathComponent("not there.xlsx")))

        // On an entry, in the file, and in the journal report.
        var e = try sample()
        var je = JournalEntry(number: "AJE-1", type: .adjusting, date: "2026-12-31", description: "Depreciation")
        je.lines = [JELine(entity: "ashford", account: "10001", amount: Money.parse("-500")!.value),
                    JELine(entity: "ashford", account: "14150", amount: Money.parse("500")!.value)]
        je.references = [FileReference(path: "3000 Standard Workpapers/3000.02 Depreciation.xlsx", note: "see total", sheet: "2026 Additions", cells: "B4:D10"),
                         FileReference(path: "3000 Standard Workpapers/3000.02 Depreciation.xlsx", sheet: "Summary"),
                         FileReference(path: "4000 Support/4000.01 Invoice.pdf", note: "page 2")]
        try e.post(je)
        XCTAssertEqual(je.references.map(\.location), ["'2026 Additions'!B4:D10", "Summary", ""])
        let data = Store.encode(e)
        let back = try Store.decode(data)
        XCTAssertEqual(back.journalEntries[0].references, je.references)
        XCTAssertEqual(Store.encode(back), data)
        let text = String(data: data, encoding: .utf8)!
        XCTAssertTrue(text.contains("\"sheet\": \"2026 Additions\", \"cells\": \"B4:D10\""))
        XCTAssertTrue(text.contains("{ \"path\": \"4000 Support/4000.01 Invoice.pdf\", \"note\": \"page 2\" }"))
        // As data (the JSON export): references by file name, and no next-year column.
        let records = Reports(e).journalEntries()
        XCTAssertEqual(records.columns.map(\.title), ["Entry", "Type", "Date", "Description", "Trial Balance", "Account", "Account Name", "Debit", "Credit", "Memo", "References"])
        guard case .text(let shown) = records.rows[0].cells[10] else { return XCTFail() }
        XCTAssertEqual(shown, "3000.02 Depreciation.xlsx; 3000.02 Depreciation.xlsx; 4000.01 Invoice.pdf")

        // Moving the same workbook's two references doesn't fold them into one.
        var relinked = e
        XCTAssertEqual(relinked.relink("3000 Standard Workpapers/3000.02 Depreciation.xlsx", to: "3000 Standard Workpapers/3000.05 Depreciation.xlsx"), 2)
        XCTAssertEqual(relinked.journalEntries[0].references.count, 3)
    }

    func testOneTrialBalanceByGrouping() throws {
        var e = try sample()
        e.applyGroupingMap(csv: try String(contentsOf: TBCoreTests.root.appendingPathComponent("grouping-map.csv"), encoding: .utf8))
        let reports = Reports(e)
        let plain = reports.entityTrialBalance(entityID: "ashford", hideZero: true, prior: 0)
        let grouped = reports.entityByGrouping(entityID: "ashford", hideZero: true, prior: 0)
        // The same amount columns, under Code and Grouping instead of Account, Name and Grp.
        XCTAssertEqual(grouped.columns.prefix(2).map(\.title), ["Code", "Grouping"])
        XCTAssertEqual(grouped.columns.dropFirst(2).map(\.title), plain.columns.dropFirst(3).map(\.title))
        // Every account is there once, under a section and a grouping total, for this trial balance.
        let accounts = grouped.rows.filter { $0.accountID != nil }
        XCTAssertEqual(Set(accounts.compactMap(\.accountID)), Set(plain.rows.compactMap(\.accountID)))
        XCTAssertEqual(accounts.count, plain.rows.filter { $0.accountID != nil }.count)
        XCTAssertTrue(accounts.allSatisfy { $0.entityID == "ashford" })
        XCTAssertTrue(grouped.rows.contains { $0.style == .section })
        XCTAssertTrue(grouped.rows.contains { $0.groupingID != nil && $0.style == .subtotal })
        // The totals and net income are the plain trial balance's.
        func amounts(_ t: ReportTable, _ id: String, skip: Int) -> [ReportCell] { Array(t.rows.first { $0.id == id }!.cells.dropFirst(skip)) }
        XCTAssertEqual(amounts(grouped, "total", skip: 2), amounts(plain, "total", skip: 3))
        XCTAssertEqual(amounts(grouped, "income", skip: 2), amounts(plain, "income", skip: 3))
        // A grouping's total is the sum of the accounts under it.
        let group = try XCTUnwrap(grouped.rows.first { $0.groupingID != nil && $0.parentRowID == nil })
        let inside = grouped.rows.filter { $0.id.hasPrefix(group.id + ":a:") }
        XCTAssertFalse(inside.isEmpty)
        func first(_ r: ReportRow) -> Money { if case .money(let v) = r.cells[2] { return v }; return .zero }
        let subs = grouped.rows.filter { $0.parentRowID == group.id }
        XCTAssertEqual(first(group), (inside + subs).map(first).sum())
    }

    func testTheJournalIsSetOutEntryByEntry() throws {
        var e = try sample()
        func entry(_ number: String, _ type: JEType, _ entity: String, _ description: String) -> JournalEntry {
            var je = JournalEntry(number: number, type: type, date: "2026-12-31", description: description)
            je.lines = [JELine(entity: entity, account: "14150", amount: Money.parse("500")!.value, memo: "Why"),
                        JELine(entity: entity, account: "10001", amount: Money.parse("-500")!.value)]
            je.rollForward = .reversal
            return je
        }
        var first = entry("AJE-1", .adjusting, "ashford", "Accrue audit fee")
        first.references = [FileReference(path: "3000 Standard Workpapers/3000.02 Accrual.xlsx", note: "see total", sheet: "Summary", cells: "B4"),
                            FileReference(path: "4000 Support/4000.01 Invoice.pdf")]
        try e.post(first)
        try e.post(entry("AJE-2", .adjusting, "ashford", "Second"))
        try e.post(entry("TJE-1", .taxOnly, "ashford", "Tax only"))
        var waiting = entry("RJE-1", .reclassifying, "ashford", "Rolled forward without amounts")
        waiting.pending = true
        e.journalEntries.append(waiting)

        let t = Reports(e).journalReport()
        XCTAssertEqual(t.title, "Journal Entries")
        XCTAssertEqual(t.columns.map(\.title), ["Entry", "Trial Balance", "Account", "Account Name", "Debit", "Credit", "Memo"])
        func texts(_ row: ReportRow) -> [String] { row.cells.map { cell in
            switch cell { case .empty: return ""; case .text(let s): return s; case .money(let m): return m.plain }
        } }
        // A heading for each kind there is, in order; an entry still waiting for amounts posts nothing and isn't listed.
        XCTAssertEqual(t.rows.filter { $0.style == .section }.map { texts($0)[0] }, ["ADJUSTING JOURNAL ENTRIES", "TAX JOURNAL ENTRIES"])
        // Each entry: its number, date and description once, above its lines.
        let head = try XCTUnwrap(t.rows.first { $0.id == "h:\(first.id)" })
        XCTAssertEqual(head.style, .heading)
        XCTAssertEqual(texts(head), ["AJE-1", "12/31/2026", "Accrue audit fee"])
        // Then what it refers to: the index and file name, never the path, the tab or the note.
        let notes = t.rows.filter { $0.style == .note && $0.entryID == first.id }.map { texts($0)[2] }
        XCTAssertEqual(notes, ["Ref: 3000.02 Accrual.xlsx", "Ref: 4000.01 Invoice.pdf"])
        // Then its lines, with nothing repeated on them, and its total.
        let lines = t.rows.filter { $0.style == .normal && $0.entryID == first.id }.map(texts)
        XCTAssertEqual(lines, [["", "Ashford", "14150", "Storage Building - Ashford", "500.00", "", "Why"],
                               ["", "Ashford", "10001", "Ashford Checking (1042) - 2", "", "500.00", ""]])
        XCTAssertEqual(texts(try XCTUnwrap(t.rows.first { $0.id == "e:\(first.id)" })), ["", "", "", "Total AJE-1", "500.00", "500.00", ""])
        // The rows of an entry are one block (kept on one page when printed), with a gap after.
        let mine = t.rows.filter { $0.block == first.id }
        XCTAssertEqual(mine.map(\.style), [.heading, .note, .note, .normal, .normal, .subtotal])
        XCTAssertEqual(t.rows[t.rows.firstIndex { $0.id == "e:\(first.id)" }! + 1].style, .blank)
        // A total for each kind, and one for everything.
        XCTAssertEqual(texts(try XCTUnwrap(t.rows.first { $0.id == "tt:adjusting" })).suffix(4), ["Total adjusting journal entries", "1000.00", "1000.00", ""])
        XCTAssertEqual(texts(try XCTUnwrap(t.rows.last)).suffix(4), ["Total, all journal entries", "1500.00", "1500.00", ""])
        // Nothing about next year, and no path, anywhere in what is exported.
        let csv = Exporter.csv(t, heading: true)
        XCTAssertFalse(csv.lowercased().contains("revers"))
        XCTAssertFalse(csv.contains("3000 Standard Workpapers"))
        XCTAssertFalse(csv.contains("Summary"))
        XCTAssertTrue(csv.contains("AJE-1,12/31/2026,Accrue audit fee\n,,Ref: 3000.02 Accrual.xlsx\n"))

        // One kind on its own.
        let tax = Reports(e).journalReport(types: [.taxOnly])
        XCTAssertEqual(tax.title, "Tax Journal Entries")
        XCTAssertEqual(tax.sheetName, "TJEs")
        XCTAssertEqual(tax.rows.filter { $0.style == .heading }.count, 1)
        XCTAssertNil(tax.rows.first { $0.id == "total" })
        // The workbook: every entry on one sheet, then a sheet for each kind there is.
        let sheets = XLSXWriter.sheetNames(Reports(e).workbook())
        XCTAssertTrue(sheets.contains("Journal Entries") && sheets.contains("AJEs") && sheets.contains("TJEs"))
        XCTAssertFalse(sheets.contains("RJEs") || sheets.contains("EJEs"))
        XCTAssertNoThrow(Exporter.xlsx(Reports(e).workbook()))
        // No entries at all still makes a report.
        XCTAssertEqual(Reports(try sample()).journalReport().rows.map(\.style), [.note])
    }

    func testExportsShadeSectionsGroupingsAndTotals() throws {
        var e = try sample()
        e.applyGroupingMap(csv: try String(contentsOf: TBCoreTests.root.appendingPathComponent("grouping-map.csv"), encoding: .utf8))
        let detail = Reports(e).groupingSummary(basis: .book, detail: true)
        func band(_ id: String) -> ReportBand { ReportBand(detail.rows.first { $0.id == id }!) }
        // A section, a grouping that heads its accounts, an account, a grand total.
        let section = try XCTUnwrap(detail.rows.first { $0.style == .section })
        XCTAssertEqual(ReportBand(section), .section)
        let group = try XCTUnwrap(detail.rows.first { $0.groupingID != nil && $0.style == .subtotal && $0.parentRowID == nil })
        XCTAssertEqual(ReportBand(group), .group)
        XCTAssertEqual(ReportBand(try XCTUnwrap(detail.rows.first { $0.accountID != nil })), .none)
        XCTAssertEqual(band("total"), .total)
        // A section's own total is a ruled line, not a band; a subgroup is a shade lighter than its grouping.
        XCTAssertEqual(ReportBand(try XCTUnwrap(detail.rows.first { $0.id.hasPrefix("st:") })), .none)
        var sub = group
        sub.parentRowID = group.id
        XCTAssertEqual(ReportBand(sub), .subgroup)
        XCTAssertEqual(Set(ReportBand.allCases.map(\.hex)).count, ReportBand.allCases.count)

        // The workbook is still a valid one, and its style sheet lists exactly the styles the sheets use.
        let data = Exporter.xlsx(Reports(e).workbook())
        let zip = try ZipReader(data)
        let styles = String(decoding: try XCTUnwrap(zip.entry("xl/styles.xml")), as: UTF8.self)
        for band in ReportBand.allCases.dropFirst() { XCTAssertTrue(styles.contains("FF\(band.hex)"), band.hex) }
        let declared = Int(try XCTUnwrap(styles.range(of: #"cellXfs count="(\d+)""#, options: .regularExpression).map { styles[$0].filter(\.isNumber) }))!
        XCTAssertEqual(styles.components(separatedBy: "<xf numFmtId").count - 2, declared)   // one more belongs to cellStyleXfs
        var highest = 0
        for n in 1...20 {
            guard let sheet = zip.entry("xl/worksheets/sheet\(n).xml") else { break }
            let xml = String(decoding: sheet, as: UTF8.self)
            for part in xml.components(separatedBy: " s=\"").dropFirst() { highest = max(highest, Int(part.prefix { $0.isNumber }) ?? 0) }
        }
        XCTAssertEqual(highest, declared - 1)
        // It reads back as the same figures.
        let sheets = try XLSXReader.read(data, name: "workbook.xlsx")
        XCTAssertEqual(sheets.first?.name, "Consolidated")
        XCTAssertTrue(sheets.contains { $0.name == "Grouping Detail" && $0.rows.contains { $0.contains("Total (zero when in balance)") } })
    }
}
