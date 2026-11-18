import XCTest
@testable import TBCore

/// The binder folder: reading it, index numbers, renumbering, and rolling it forward.
final class BinderTests: XCTestCase {

    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tbtool-binder-\(UUID().uuidString)/[SS1] Summit Storage, LLC/2026").standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent())
    }

    @discardableResult
    func make(_ path: String, _ text: String = "x") throws -> URL {
        let url = root.appendingPathComponent(path)
        if path.hasSuffix("/") {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return url
    }

    func names(_ dir: String = "") -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(dir).path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// A small binder in the usual layout.
    func sampleBinder() throws -> BinderTree {
        try Store.save(Engagement(name: "Summit Storage", periodEnd: "2026-12-31"), to: root.appendingPathComponent("Summit Storage 2026 Trial Balance.json"))
        try make("TB Backups/Summit Storage 2026 Trial Balance 2026-11-18 084715.json")
        try make("0000 Binder Notes/")
        try make("2000 Client Financials/2000.01 Trial Balance.xlsx")
        try make("2000 Client Financials/2000.02 GL.xlsx")
        try make("2000 Client Financials/2000.03 Income Stmt.xlsx")
        try make("4000 Support/4000.01 Organizer.pdf")
        try make("4000 Support/Bank statement.pdf")
        try make("5000 Permanent Files/5010 PY Tax Returns/")
        try make("5000 Permanent Files/5020 Entity Formation Documents/5020.01 Partners.xlsx")
        try make("5000 Permanent Files/Scans/")
        try make("Engagement letter.pdf")
        try make(".DS_Store")
        return BinderScanner.scan(root)
    }

    // MARK: Index numbers

    func testIndexNumbersAreReadFromNames() {
        func file(_ n: String) -> (String?, String) { let p = BinderIndex.parse(n, isFolder: false); return (p.index?.text, p.title) }
        func folder(_ n: String) -> (String?, String) { let p = BinderIndex.parse(n, isFolder: true); return (p.index?.text, p.title) }
        XCTAssertEqual(file("2000.02 SSG GL.xlsx").0, "2000.02")
        XCTAssertEqual(file("2000.02 SSG GL.xlsx").1, "SSG GL.xlsx")
        XCTAssertEqual(file("4000.1 Statement.pdf").0, "4000.1")
        XCTAssertEqual(file("5020.01 Summit Storage, LLC Partners.xlsx").1, "Summit Storage, LLC Partners.xlsx")
        // A file needs the whole number.number form; anything else is unindexed.
        XCTAssertNil(file("2025 Organizer.pdf").0)
        XCTAssertNil(file("Bank statement.pdf").0)
        XCTAssertNil(file("v2.01 notes.txt").0)
        XCTAssertNil(file("2000.02.pdf").0)
        XCTAssertEqual(folder("2000 Client Financials").0, "2000")
        XCTAssertEqual(folder("2000 Client Financials").1, "Client Financials")
        XCTAssertEqual(folder("0000 Binder Notes").0, "0000")
        XCTAssertNil(folder("Scans").0)
        // What a person types.
        XCTAssertEqual(BinderIndex(typed: "2000.3", isFolder: false)?.text, "2000.03")
        XCTAssertEqual(BinderIndex(typed: " 2000.12 ", isFolder: false)?.text, "2000.12")
        XCTAssertEqual(BinderIndex(typed: "2000.104", isFolder: false)?.text, "2000.104")
        XCTAssertNil(BinderIndex(typed: "2000", isFolder: false))
        XCTAssertNil(BinderIndex(typed: "2000.0", isFolder: false))
        XCTAssertNil(BinderIndex(typed: "abc.01", isFolder: false))
        XCTAssertEqual(BinderIndex(typed: "5030", isFolder: true)?.text, "5030")
        XCTAssertNil(BinderIndex(typed: "5030.01", isFolder: true))
    }

    // MARK: Reading the folder

    func testScanningABinder() throws {
        let tree = try sampleBinder()
        XCTAssertFalse(tree.truncated)
        // The trial balance, the backups and hidden files aren't workpapers.
        XCTAssertEqual(tree.items.map(\.name), ["0000 Binder Notes", "2000 Client Financials", "4000 Support", "5000 Permanent Files", "Engagement letter.pdf"])
        XCTAssertEqual(tree.all.count, 14)
        XCTAssertEqual(tree.item("2000 Client Financials/2000.02 GL.xlsx")?.index?.text, "2000.02")
        XCTAssertEqual(tree.item("2000 Client Financials/2000.02 GL.xlsx")?.depth, 1)
        XCTAssertEqual(tree.item("5000 Permanent Files")?.children.map(\.name), ["5010 PY Tax Returns", "5020 Entity Formation Documents", "Scans"])
        // What needs attention.
        XCTAssertEqual(tree.unfiled.map(\.name), ["Engagement letter.pdf"])
        XCTAssertEqual(tree.unindexed.map(\.path), ["4000 Support/Bank statement.pdf", "5000 Permanent Files/Scans"])
        XCTAssertTrue(tree.duplicateIndexes.isEmpty)
        try make("4000 Support/4000.01 Second organizer.pdf")
        let again = BinderScanner.scan(root)
        XCTAssertEqual(again.duplicateIndexes.map(\.index), ["4000.01"])
        XCTAssertEqual(again.duplicateIndexes[0].items.count, 2)
        // A person's general folders aren't treated as a binder.
        XCTAssertTrue(BinderScanner.isLikelyBinder(root))
        XCTAssertFalse(BinderScanner.isLikelyBinder(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")))
        // A huge folder is read only so far.
        XCTAssertTrue(BinderScanner.scan(root, limit: 3).truncated)
    }

    // MARK: Renumbering

    func testIndexingKeepsEveryNumberUnique() throws {
        var tree = try sampleBinder()
        func apply(_ renames: [BinderRename]) throws {
            try BinderFileOps.apply(renames, root: root)
            tree = BinderScanner.scan(root)
        }
        let fin = "2000 Client Financials", support = "4000 Support"
        // The next number for a folder builds on the folder's own.
        XCTAssertEqual(BinderIndexer.nextFileIndex(in: fin, tree: tree)?.text, "2000.04")
        XCTAssertEqual(BinderIndexer.nextFileIndex(in: support, tree: tree)?.text, "4000.02")
        XCTAssertNil(BinderIndexer.nextFileIndex(in: "5000 Permanent Files/Scans", tree: tree))  // the folder has no number yet
        XCTAssertEqual(BinderIndexer.suggestedFolderIndex(for: "5000 Permanent Files/Scans", tree: tree)?.text, "5030")

        // Index everything that can be: the bank statement gets 4000.02.
        try apply(BinderIndexer.indexUnindexed(under: "", in: tree))
        XCTAssertEqual(names(support), ["4000.01 Organizer.pdf", "4000.02 Bank statement.pdf"])
        XCTAssertEqual(tree.unindexed.map(\.path), ["5000 Permanent Files/Scans"])

        // Insert: giving the income statement 2000.01 moves the others up by one. No two share a number.
        try apply(BinderIndexer.setIndex(BinderIndex(typed: "2000.01", isFolder: false)!, on: "\(fin)/2000.03 Income Stmt.xlsx", in: tree, conflict: .insert))
        XCTAssertEqual(names(fin), ["2000.01 Income Stmt.xlsx", "2000.02 Trial Balance.xlsx", "2000.03 GL.xlsx"])
        XCTAssertTrue(tree.duplicateIndexes.isEmpty)
        // With a gap after it, only what is in the way moves.
        try make("\(fin)/2000.07 Notes.docx")
        try make("\(fin)/Late arrival.pdf")
        tree = BinderScanner.scan(root)
        try apply(BinderIndexer.setIndex(BinderIndex(typed: "2000.03", isFolder: false)!, on: "\(fin)/Late arrival.pdf", in: tree, conflict: .insert))
        XCTAssertEqual(names(fin), ["2000.01 Income Stmt.xlsx", "2000.02 Trial Balance.xlsx", "2000.03 Late arrival.pdf", "2000.04 GL.xlsx", "2000.07 Notes.docx"])
        // Replace: the file that had the number loses its index instead.
        try apply(BinderIndexer.setIndex(BinderIndex(typed: "2000.02", isFolder: false)!, on: "\(fin)/2000.07 Notes.docx", in: tree, conflict: .replace))
        XCTAssertEqual(names(fin), ["2000.01 Income Stmt.xlsx", "2000.02 Notes.docx", "2000.03 Late arrival.pdf", "2000.04 GL.xlsx", "Trial Balance.xlsx"])
        XCTAssertEqual(tree.unindexed.map(\.name), ["Trial Balance.xlsx", "Scans"])
        // Removing an index, and closing the gaps left behind.
        try apply(BinderIndexer.removeIndex(from: "\(fin)/2000.01 Income Stmt.xlsx", in: tree))
        try apply(BinderIndexer.closeGaps(in: fin, tree: tree))
        XCTAssertEqual(names(fin), ["2000.01 Notes.docx", "2000.02 Late arrival.pdf", "2000.03 GL.xlsx", "Income Stmt.xlsx", "Trial Balance.xlsx"])

        // A loose file is filed into a folder and takes its next number.
        try apply(BinderIndexer.file("Engagement letter.pdf", into: "0000 Binder Notes", in: tree))
        XCTAssertEqual(names("0000 Binder Notes"), ["0000.01 Engagement letter.pdf"])
        XCTAssertEqual(tree.unfiled, [])

        // Numbering a folder; renumbering one carries the files that bear its number.
        try apply(BinderIndexer.setIndex(BinderIndex(typed: "5030", isFolder: true)!, on: "5000 Permanent Files/Scans", in: tree))
        XCTAssertEqual(names("5000 Permanent Files"), ["5010 PY Tax Returns", "5020 Entity Formation Documents", "5030 Scans"])
        try apply(BinderIndexer.setIndex(BinderIndex(typed: "5040", isFolder: true)!, on: "5000 Permanent Files/5020 Entity Formation Documents", in: tree))
        XCTAssertEqual(names("5000 Permanent Files"), ["5010 PY Tax Returns", "5030 Scans", "5040 Entity Formation Documents"])
        XCTAssertEqual(names("5000 Permanent Files/5040 Entity Formation Documents"), ["5040.01 Partners.xlsx"])
        // A folder number that is taken: the folder in the way moves up, files and all.
        try apply(BinderIndexer.setIndex(BinderIndex(typed: "5040", isFolder: true)!, on: "5000 Permanent Files/5030 Scans", in: tree, conflict: .insert))
        XCTAssertEqual(names("5000 Permanent Files"), ["5010 PY Tax Returns", "5040 Scans", "5041 Entity Formation Documents"])
        XCTAssertEqual(names("5000 Permanent Files/5041 Entity Formation Documents"), ["5041.01 Partners.xlsx"])
        XCTAssertTrue(tree.duplicateIndexes.isEmpty)
    }

    func testRenamesNeverOverwriteAndLinksFollow() throws {
        let tree = try sampleBinder()
        // Something outside the change is in the way: refused, and nothing is left half done.
        let clash = [BinderRename(from: "2000 Client Financials/2000.01 Trial Balance.xlsx", to: "2000 Client Financials/2000.02 GL.xlsx")]
        XCTAssertThrowsError(try BinderFileOps.apply(clash, root: root))
        XCTAssertEqual(names("2000 Client Financials"), ["2000.01 Trial Balance.xlsx", "2000.02 GL.xlsx", "2000.03 Income Stmt.xlsx"])
        XCTAssertThrowsError(try BinderFileOps.apply([BinderRename(from: "nope.pdf", to: "x.pdf")], root: root))
        // A swap goes through, because both are part of the change.
        try BinderFileOps.apply([BinderRename(from: "2000 Client Financials/2000.01 Trial Balance.xlsx", to: "2000 Client Financials/2000.02 Trial Balance.xlsx"),
                                 BinderRename(from: "2000 Client Financials/2000.02 GL.xlsx", to: "2000 Client Financials/2000.01 GL.xlsx")], root: root)
        XCTAssertEqual(names("2000 Client Financials"), ["2000.01 GL.xlsx", "2000.02 Trial Balance.xlsx", "2000.03 Income Stmt.xlsx"])

        // Journal entries that link a workpaper keep pointing at it through a rename, a move, and a folder rename.
        var e = Engagement(name: "Summit Storage", periodEnd: "2026-12-31")
        _ = try e.addEntity(named: "Ashford")
        _ = try e.addAccount(number: "1000", name: "Cash", type: .asset)
        _ = try e.addAccount(number: "3000", name: "Equity", type: .equity)
        try e.post(JournalEntry(number: "AJE-1", type: .adjusting, date: "2026-12-31",
                                lines: [JELine(entity: "ashford", account: "1000", amount: Money(cents: 100)), JELine(entity: "ashford", account: "3000", amount: Money(cents: -100))],
                                references: [FileReference(path: "2000 Client Financials/2000.02 GL.xlsx"), FileReference(path: "Engagement letter.pdf"),
                                             FileReference(path: "5000 Permanent Files/5020 Entity Formation Documents/5020.01 Partners.xlsx"),
                                             FileReference(path: "/somewhere/else.pdf")]))
        let renames = [BinderRename(from: "2000 Client Financials/2000.02 GL.xlsx", to: "2000 Client Financials/2000.05 GL.xlsx"),
                       BinderRename(from: "Engagement letter.pdf", to: "0000 Binder Notes/0000.01 Engagement letter.pdf"),
                       BinderRename(from: "5000 Permanent Files/5020 Entity Formation Documents", to: "5000 Permanent Files/5040 Entity Formation Documents", isFolder: true),
                       BinderRename(from: "5000 Permanent Files/5020 Entity Formation Documents/5020.01 Partners.xlsx",
                                    to: "5000 Permanent Files/5040 Entity Formation Documents/5040.01 Partners.xlsx")]
        XCTAssertEqual(e.relink(after: renames), 3)
        XCTAssertEqual(e.journalEntries[0].references.map(\.path), ["2000 Client Financials/2000.05 GL.xlsx", "0000 Binder Notes/0000.01 Engagement letter.pdf",
                                                                    "5000 Permanent Files/5040 Entity Formation Documents/5040.01 Partners.xlsx", "/somewhere/else.pdf"])
        _ = tree
    }

    // MARK: Rolling forward

    func testRollingTheBinderForward() throws {
        let tree = try sampleBinder()
        let gl = root.appendingPathComponent("2000 Client Financials/2000.02 GL.xlsx")
        try (gl as NSURL).setResourceValue(["Reviewed", "Green"], forKey: .tagNamesKey)
        XCTAssertEqual(BinderScanner.scan(root).item("2000 Client Financials/2000.02 GL.xlsx")?.tags.sorted(), ["Green", "Reviewed"])

        let dest = BinderRoller.defaultDestination(for: root, fromYear: 2026, toYear: 2027)
        XCTAssertEqual(dest.lastPathComponent, "2027")
        XCTAssertEqual(dest.deletingLastPathComponent().path, root.deletingLastPathComponent().path)
        XCTAssertEqual(BinderRoller.defaultDestination(for: URL(fileURLWithPath: "/x/Client binder"), fromYear: 2026, toYear: 2027).lastPathComponent, "Client binder 2027")

        var choices = BinderRoller.defaultChoices(tree)
        XCTAssertTrue(choices.values.allSatisfy { $0 == .copy })
        choices["2000 Client Financials/2000.01 Trial Balance.xlsx"] = .placeholder   // a document to ask for again
        choices["2000 Client Financials/2000.03 Income Stmt.xlsx"] = .skip
        choices["4000 Support"] = .skip                                                // the folder and all that is in it
        choices["Engagement letter.pdf"] = .placeholder
        XCTAssertEqual(BinderRoller.effective("4000 Support/4000.01 Organizer.pdf", choices), .skip)

        let result = try BinderRoller.roll(tree, to: dest, choices: choices)
        XCTAssertEqual(result, BinderRollResult(folders: 6, copied: 2, placeholders: 2, alreadyThere: []))
        func there(_ dir: String = "") -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: dest.appendingPathComponent(dir).path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }
        // The folders, with their index numbers; no trial balance, no backups, nothing that was skipped.
        XCTAssertEqual(there(), ["0000 Binder Notes", "2000 Client Financials", "5000 Permanent Files", "Engagement letter.pdf (placeholder).txt"])
        XCTAssertEqual(there("2000 Client Financials"), ["2000.01 Trial Balance.xlsx (placeholder).txt", "2000.02 GL.xlsx"])
        XCTAssertEqual(there("5000 Permanent Files"), ["5010 PY Tax Returns", "5020 Entity Formation Documents", "Scans"])
        XCTAssertEqual(there("5000 Permanent Files/5020 Entity Formation Documents"), ["5020.01 Partners.xlsx"])
        // A placeholder is empty but for where last year's file is, and keeps the index.
        let placeholder = dest.appendingPathComponent("2000 Client Financials/2000.01 Trial Balance.xlsx (placeholder).txt")
        XCTAssertEqual(try String(contentsOf: placeholder, encoding: .utf8), root.appendingPathComponent("2000 Client Financials/2000.01 Trial Balance.xlsx").path + "\n")
        // A copied file comes without its Finder tags; the original keeps them.
        let copied = dest.appendingPathComponent("2000 Client Financials/2000.02 GL.xlsx")
        XCTAssertEqual(try String(contentsOf: copied, encoding: .utf8), "x")
        XCTAssertEqual(try copied.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? [], [])
        XCTAssertEqual((try gl.resourceValues(forKeys: [.tagNamesKey]).tagNames ?? []).sorted(), ["Green", "Reviewed"])
        // Last year's binder is untouched.
        XCTAssertEqual(BinderScanner.scan(root).all.map(\.path), tree.all.map(\.path))

        // The new binder reads as one: indexed, with its placeholders known as such.
        let next = BinderScanner.scan(dest)
        XCTAssertEqual(next.item("2000 Client Financials/2000.01 Trial Balance.xlsx (placeholder).txt")?.index?.text, "2000.01")
        XCTAssertEqual(next.files.filter(\.isPlaceholder).count, 2)
        XCTAssertEqual(next.item("2000 Client Financials/2000.02 GL.xlsx")?.tags, [])
        // Rolled again, a stand-in that was never replaced stays one (not "placeholder (placeholder)") and
        // remembers where the real document last was. Running a roll twice never overwrites.
        XCTAssertEqual(BinderRoller.defaultChoices(next)["2000 Client Financials/2000.01 Trial Balance.xlsx (placeholder).txt"], .placeholder)
        let third = BinderRoller.defaultDestination(for: dest, fromYear: 2027, toYear: 2028)
        try BinderRoller.roll(next, to: third, choices: BinderRoller.defaultChoices(next))
        let carried = try String(contentsOf: third.appendingPathComponent("2000 Client Financials/2000.01 Trial Balance.xlsx (placeholder).txt"), encoding: .utf8)
        XCTAssertEqual(carried.split(separator: "\n").map(String.init), [placeholder.path, root.appendingPathComponent("2000 Client Financials/2000.01 Trial Balance.xlsx").path])
        let again = try BinderRoller.roll(next, to: third, choices: BinderRoller.defaultChoices(next))
        XCTAssertEqual(again.copied + again.placeholders + again.folders, 0)
        XCTAssertEqual(again.alreadyThere.count, 4)
    }
}
