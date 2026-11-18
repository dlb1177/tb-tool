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
        XCTAssertEqual([result.folders, result.copied, result.placeholders, result.alreadyThere.count], [6, 2, 2, 0])
        // A document left as a placeholder has a different name in the new binder; links follow it there.
        XCTAssertEqual(result.renamed, [
            BinderRename(from: "2000 Client Financials/2000.01 Trial Balance.xlsx", to: "2000 Client Financials/2000.01 (PLACEHOLDER) Trial Balance.xlsx.txt"),
            BinderRename(from: "Engagement letter.pdf", to: "(PLACEHOLDER) Engagement letter.pdf.txt"),
        ])
        func there(_ dir: String = "") -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: dest.appendingPathComponent(dir).path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }
        // The folders, with their index numbers; no trial balance, no backups, nothing that was skipped.
        XCTAssertEqual(there(), ["(PLACEHOLDER) Engagement letter.pdf.txt", "0000 Binder Notes", "2000 Client Financials", "5000 Permanent Files"])
        XCTAssertEqual(there("2000 Client Financials"), ["2000.01 (PLACEHOLDER) Trial Balance.xlsx.txt", "2000.02 GL.xlsx"])
        XCTAssertEqual(there("5000 Permanent Files"), ["5010 PY Tax Returns", "5020 Entity Formation Documents", "Scans"])
        XCTAssertEqual(there("5000 Permanent Files/5020 Entity Formation Documents"), ["5020.01 Partners.xlsx"])
        // A placeholder is empty but for where last year's file is, and keeps the index.
        let placeholder = dest.appendingPathComponent("2000 Client Financials/2000.01 (PLACEHOLDER) Trial Balance.xlsx.txt")
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
        XCTAssertEqual(next.item("2000 Client Financials/2000.01 (PLACEHOLDER) Trial Balance.xlsx.txt")?.index?.text, "2000.01")
        XCTAssertEqual(next.files.filter(\.isPlaceholder).count, 2)
        XCTAssertEqual(next.item("2000 Client Financials/2000.02 GL.xlsx")?.tags, [])
        // Rolled again, a stand-in that was never replaced stays one (not "placeholder (placeholder)") and
        // remembers where the real document last was. Running a roll twice never overwrites.
        XCTAssertEqual(BinderRoller.defaultChoices(next)["2000 Client Financials/2000.01 (PLACEHOLDER) Trial Balance.xlsx.txt"], .placeholder)
        let third = BinderRoller.defaultDestination(for: dest, fromYear: 2027, toYear: 2028)
        try BinderRoller.roll(next, to: third, choices: BinderRoller.defaultChoices(next))
        let carried = try String(contentsOf: third.appendingPathComponent("2000 Client Financials/2000.01 (PLACEHOLDER) Trial Balance.xlsx.txt"), encoding: .utf8)
        XCTAssertEqual(carried.split(separator: "\n").map(String.init), [placeholder.path, root.appendingPathComponent("2000 Client Financials/2000.01 Trial Balance.xlsx").path])
        let again = try BinderRoller.roll(next, to: third, choices: BinderRoller.defaultChoices(next))
        XCTAssertEqual(again.copied + again.placeholders + again.folders, 0)
        XCTAssertEqual(again.alreadyThere.count, 4)
    }

    func testPlaceholderNames() throws {
        // The index stays in front, then the marker, then the document's own name.
        XCTAssertEqual(BinderPlaceholder.name(for: "4000.03 BANK STATEMENT - SSG MM Stmt.pdf"), "4000.03 (PLACEHOLDER) BANK STATEMENT - SSG MM Stmt.pdf.txt")
        XCTAssertEqual(BinderPlaceholder.name(for: "Engagement letter.pdf"), "(PLACEHOLDER) Engagement letter.pdf.txt")
        // A placeholder keeps its name; one named the way versions before 1.5 named them takes the present form.
        XCTAssertEqual(BinderPlaceholder.name(for: "4000.03 (PLACEHOLDER) Stmt.pdf.txt"), "4000.03 (PLACEHOLDER) Stmt.pdf.txt")
        XCTAssertEqual(BinderPlaceholder.name(for: "4000.03 Stmt.pdf (placeholder).txt"), "4000.03 (PLACEHOLDER) Stmt.pdf.txt")
        XCTAssertTrue(BinderPlaceholder.isPlaceholder("4000.03 (PLACEHOLDER) Stmt.pdf.txt"))
        XCTAssertTrue(BinderPlaceholder.isPlaceholder("(PLACEHOLDER) Stmt.pdf.txt"))
        XCTAssertTrue(BinderPlaceholder.isPlaceholder("4000.03 Stmt.pdf (placeholder).txt"))
        XCTAssertFalse(BinderPlaceholder.isPlaceholder("4000.03 Stmt.pdf"))
        XCTAssertFalse(BinderPlaceholder.isPlaceholder("4000.03 (PLACEHOLDER) Stmt.pdf"))
        XCTAssertFalse(BinderPlaceholder.isPlaceholder("4000.03 Notes on the (PLACEHOLDER) files.txt"))

        try make("4000 Support/4000.01 (PLACEHOLDER) Organizer.pdf.txt")
        try make("4000 Support/4000.02 K-1.pdf (placeholder).txt", "/last/year/K-1.pdf\n")
        let tree = BinderScanner.scan(root)
        let new = try XCTUnwrap(tree.item("4000 Support/4000.01 (PLACEHOLDER) Organizer.pdf.txt"))
        XCTAssertTrue(new.isPlaceholder)
        XCTAssertEqual(new.index?.text, "4000.01")
        XCTAssertEqual(new.displayTitle, "Organizer.pdf")
        XCTAssertEqual(tree.item("4000 Support/4000.02 K-1.pdf (placeholder).txt")?.displayTitle, "K-1.pdf")
        // Rolled forward, both stay placeholders, the older one under the present name.
        let dest = BinderRoller.defaultDestination(for: root, fromYear: 2026, toYear: 2027)
        let result = try BinderRoller.roll(tree, to: dest, choices: BinderRoller.defaultChoices(tree))
        XCTAssertEqual(result.placeholders, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dest.appendingPathComponent("4000 Support").path).sorted(),
                       ["4000.01 (PLACEHOLDER) Organizer.pdf.txt", "4000.02 (PLACEHOLDER) K-1.pdf.txt"])
        XCTAssertEqual(result.renamed, [BinderRename(from: "4000 Support/4000.02 K-1.pdf (placeholder).txt", to: "4000 Support/4000.02 (PLACEHOLDER) K-1.pdf.txt")])
    }

    // MARK: Dragging

    /// Five files in 4000 Support (01–03, 05, one unindexed) and the usual others.
    func dragBinder() throws -> BinderTree {
        try make("2000 Client Financials/2000.01 TB.xlsx")
        try make("2000 Client Financials/2000.02 GL.xlsx")
        try make("4000 Support/4000.01 A.pdf")
        try make("4000 Support/4000.02 B.pdf")
        try make("4000 Support/4000.03 C.pdf")
        try make("4000 Support/4000.05 E.pdf")
        try make("4000 Support/Loose.pdf")
        try make("5000 Permanent Files/")
        return BinderScanner.scan(root)
    }

    func pairs(_ renames: [BinderRename]) -> [String] {
        renames.map { "\(($0.from as NSString).lastPathComponent) > \($0.to)" }.sorted()
    }

    func testDraggingWithinAFolderRenumbersOnlyWhatLiesBetween() throws {
        let tree = try dragBinder()
        let a = "4000 Support/4000.01 A.pdf", b = "4000 Support/4000.02 B.pdf", c = "4000 Support/4000.03 C.pdf", e = "4000 Support/4000.05 E.pdf"
        // A below B: B moves up a place and A takes B's number. C and E are left alone.
        XCTAssertEqual(pairs(BinderIndexer.move(a, .after(b), in: tree)),
                       ["4000.01 A.pdf > 4000 Support/4000.02 A.pdf", "4000.02 B.pdf > 4000 Support/4000.01 B.pdf"])
        // Above C is the same place as below B.
        XCTAssertEqual(BinderIndexer.move(a, .before(c), in: tree), BinderIndexer.move(a, .after(b), in: tree))
        // Between C and E the number 04 is free: A takes it, and nothing else is renamed.
        XCTAssertEqual(pairs(BinderIndexer.move(a, .after(c), in: tree)), ["4000.01 A.pdf > 4000 Support/4000.04 A.pdf"])
        XCTAssertEqual(BinderIndexer.move(a, .before(e), in: tree), BinderIndexer.move(a, .after(c), in: tree))
        XCTAssertEqual(BinderIndexer.freeIndex(at: .after(c), in: tree)?.text, "4000.04")
        XCTAssertEqual(BinderIndexer.freeIndex(at: .before(e), in: tree)?.text, "4000.04")
        XCTAssertNil(BinderIndexer.freeIndex(at: .after(a), in: tree))
        XCTAssertNil(BinderIndexer.freeIndex(at: .after(e), in: tree))
        XCTAssertNil(BinderIndexer.freeIndex(at: .onto(c), in: tree))
        // E above A: everything before it moves down one; the run keeps the numbers 01, 02, 03, 05.
        XCTAssertEqual(pairs(BinderIndexer.move(e, .before(a), in: tree)),
                       ["4000.01 A.pdf > 4000 Support/4000.02 A.pdf", "4000.02 B.pdf > 4000 Support/4000.03 B.pdf",
                        "4000.03 C.pdf > 4000 Support/4000.05 C.pdf", "4000.05 E.pdf > 4000 Support/4000.01 E.pdf"])
        // Let go where it already is: nothing to do.
        XCTAssertEqual(BinderIndexer.move(b, .after(a), in: tree), [])
        XCTAssertEqual(BinderIndexer.move(b, .before(c), in: tree), [])
        XCTAssertEqual(BinderIndexer.move(b, .onto(b), in: tree), [])

        try BinderFileOps.apply(BinderIndexer.move(a, .after(b), in: tree), root: root)
        XCTAssertEqual(names("4000 Support"), ["4000.01 B.pdf", "4000.02 A.pdf", "4000.03 C.pdf", "4000.05 E.pdf", "Loose.pdf"])
        XCTAssertTrue(BinderScanner.scan(root).duplicateIndexes.isEmpty)
    }

    func testDraggingInFromElsewhereMakesRoom() throws {
        let tree = try dragBinder()
        let gl = "2000 Client Financials/2000.02 GL.xlsx", loose = "4000 Support/Loose.pdf"
        // From another folder, above B: it becomes 4000.02; B and C move up; E, past the gap, stays.
        XCTAssertEqual(pairs(BinderIndexer.move(gl, .before("4000 Support/4000.02 B.pdf"), in: tree)),
                       ["2000.02 GL.xlsx > 4000 Support/4000.02 GL.xlsx", "4000.02 B.pdf > 4000 Support/4000.03 B.pdf", "4000.03 C.pdf > 4000 Support/4000.04 C.pdf"])
        // An unindexed file below C takes the free 04: nothing else moves.
        XCTAssertEqual(pairs(BinderIndexer.move(loose, .after("4000 Support/4000.03 C.pdf"), in: tree)), ["Loose.pdf > 4000 Support/4000.04 Loose.pdf"])
        // Below the last file.
        XCTAssertEqual(pairs(BinderIndexer.move(gl, .after("4000 Support/4000.05 E.pdf"), in: tree)), ["2000.02 GL.xlsx > 4000 Support/4000.06 GL.xlsx"])
        // Onto a folder: filed there with its next index. A folder with no files starts at 01.
        XCTAssertEqual(pairs(BinderIndexer.move(gl, .onto("4000 Support"), in: tree)), ["2000.02 GL.xlsx > 4000 Support/4000.06 GL.xlsx"])
        XCTAssertEqual(pairs(BinderIndexer.move(gl, .onto("5000 Permanent Files"), in: tree)), ["2000.02 GL.xlsx > 5000 Permanent Files/5000.01 GL.xlsx"])
        XCTAssertEqual(BinderIndexer.move(gl, .onto("2000 Client Financials"), in: tree), [])
        // Beside a file with no index there is no number to take: it is filed with the folder's next one.
        XCTAssertEqual(pairs(BinderIndexer.move(gl, .before(loose), in: tree)), ["2000.02 GL.xlsx > 4000 Support/4000.06 GL.xlsx"])
        // Folders aren't dragged.
        XCTAssertEqual(BinderIndexer.move("4000 Support", .onto("5000 Permanent Files"), in: tree), [])

        let renames = BinderIndexer.move(gl, .before("4000 Support/4000.02 B.pdf"), in: tree)
        try BinderFileOps.apply(renames, root: root)
        XCTAssertEqual(names("4000 Support"), ["4000.01 A.pdf", "4000.02 GL.xlsx", "4000.03 B.pdf", "4000.04 C.pdf", "4000.05 E.pdf", "Loose.pdf"])
        XCTAssertEqual(names("2000 Client Financials"), ["2000.01 TB.xlsx"])
        XCTAssertTrue(BinderScanner.scan(root).duplicateIndexes.isEmpty)
    }

    func testDroppingOntoAFileTakesItsIndex() throws {
        let tree = try dragBinder()
        let gl = "2000 Client Financials/2000.02 GL.xlsx", b = "4000 Support/4000.02 B.pdf"
        // The file dropped takes the number and the place; the file that had it stays, with no index.
        XCTAssertEqual(pairs(BinderIndexer.move(gl, .onto(b), in: tree)), ["2000.02 GL.xlsx > 4000 Support/4000.02 GL.xlsx", "4000.02 B.pdf > 4000 Support/B.pdf"])
        XCTAssertEqual(pairs(BinderIndexer.move("4000 Support/4000.01 A.pdf", .onto(b), in: tree)), ["4000.01 A.pdf > 4000 Support/4000.02 A.pdf", "4000.02 B.pdf > 4000 Support/B.pdf"])
        try BinderFileOps.apply(BinderIndexer.move(gl, .onto(b), in: tree), root: root)
        let after = BinderScanner.scan(root)
        XCTAssertEqual(names("4000 Support"), ["4000.01 A.pdf", "4000.02 GL.xlsx", "4000.03 C.pdf", "4000.05 E.pdf", "B.pdf", "Loose.pdf"])
        XCTAssertNil(after.item("4000 Support/B.pdf")?.index)
        XCTAssertTrue(after.duplicateIndexes.isEmpty)

        // Journal entry links and sign-offs follow a drag.
        var e = Engagement(name: "Summit Storage", periodEnd: "2026-12-31")
        var je = JournalEntry(number: "AJE-1", type: .adjusting, date: "2026-12-31")
        je.references = [FileReference(path: gl, sheet: "GL", cells: "B4:D10"), FileReference(path: b)]
        e.journalEntries = [je]
        e.setSignOff(.prepared, for: b, by: Actor(name: "Jordan Avery", account: "javery", computer: "Mac", device: "D1"), fileHash: "h")
        e.relink(after: BinderIndexer.move(gl, .onto(b), in: tree))
        XCTAssertEqual(e.journalEntries[0].references.map(\.path), ["4000 Support/4000.02 GL.xlsx", "4000 Support/B.pdf"])
        XCTAssertEqual(e.journalEntries[0].references[0].location, "'GL'!B4:D10")
        XCTAssertEqual(e.signOffs.map(\.path), ["4000 Support/B.pdf"])
    }

    func testIndexingASelectionAndClosingGaps() throws {
        try make("4000 Support/Invoice B.pdf")
        try make("4000 Support/Invoice A.pdf")
        try make("3000 Workpapers/Recon.xlsx")
        try make("Scans/Unnumbered folder file.pdf")
        try make("Engagement letter.pdf")
        var tree = try dragBinder()
        // Each selected file with no index takes the next number of its own folder, in the order
        // listed. Files that have an index, loose files, and files in a folder with no number are left.
        let picked: Set<String> = ["4000 Support/Invoice A.pdf", "4000 Support/Invoice B.pdf", "4000 Support/4000.01 A.pdf",
                                   "3000 Workpapers/Recon.xlsx", "Scans/Unnumbered folder file.pdf", "Engagement letter.pdf"]
        XCTAssertEqual(pairs(BinderIndexer.index(picked, in: tree)),
                       ["Invoice A.pdf > 4000 Support/4000.06 Invoice A.pdf", "Invoice B.pdf > 4000 Support/4000.07 Invoice B.pdf",
                        "Recon.xlsx > 3000 Workpapers/3000.01 Recon.xlsx"])
        XCTAssertEqual(BinderIndexer.index(["4000 Support/4000.01 A.pdf"], in: tree), [])
        try BinderFileOps.apply(BinderIndexer.index(picked, in: tree), root: root)
        tree = BinderScanner.scan(root)

        // Closing the gaps renumbers the indexed files 01, 02, 03… in order. Unindexed files stay unindexed.
        XCTAssertEqual(pairs(BinderIndexer.closeGaps(in: "4000 Support", tree: tree)),
                       ["4000.05 E.pdf > 4000 Support/4000.04 E.pdf", "4000.06 Invoice A.pdf > 4000 Support/4000.05 Invoice A.pdf",
                        "4000.07 Invoice B.pdf > 4000 Support/4000.06 Invoice B.pdf"])
        try BinderFileOps.apply(BinderIndexer.closeGaps(in: "4000 Support", tree: tree), root: root)
        XCTAssertEqual(names("4000 Support"), ["4000.01 A.pdf", "4000.02 B.pdf", "4000.03 C.pdf", "4000.04 E.pdf", "4000.05 Invoice A.pdf", "4000.06 Invoice B.pdf", "Loose.pdf"])
        XCTAssertEqual(BinderIndexer.closeGaps(in: "4000 Support", tree: BinderScanner.scan(root)), [])
    }

    func testNewFoldersAndRenaming() throws {
        let tree = try sampleBinder()
        // At the top: the next thousand. Inside a folder: ten past the highest beside it, or past the folder's own number.
        XCTAssertEqual(BinderIndexer.newFolderIndex(in: "", tree: tree)?.text, "6000")
        XCTAssertEqual(BinderIndexer.newFolderIndex(in: "5000 Permanent Files", tree: tree)?.text, "5030")
        XCTAssertEqual(BinderIndexer.newFolderIndex(in: "4000 Support", tree: tree)?.text, "4010")
        XCTAssertEqual(BinderIndexer.newFolderIndex(in: "5000 Permanent Files/5010 PY Tax Returns", tree: tree)?.text, "5030")
        XCTAssertNil(BinderIndexer.newFolderIndex(in: "5000 Permanent Files/Scans", tree: tree))
        XCTAssertEqual(BinderIndexer.newFolderIndex(in: "", tree: BinderTree(root: root))?.text, "1000")

        // Renaming keeps the index in front, on files and folders.
        XCTAssertEqual(BinderIndexer.retitle("2000 Client Financials/2000.02 GL.xlsx", to: "General ledger.xlsx", in: tree),
                       [BinderRename(from: "2000 Client Financials/2000.02 GL.xlsx", to: "2000 Client Financials/2000.02 General ledger.xlsx")])
        XCTAssertEqual(BinderIndexer.retitle("4000 Support", to: "Client Support", in: tree), [BinderRename(from: "4000 Support", to: "4000 Client Support", isFolder: true)])
        XCTAssertEqual(BinderIndexer.retitle("4000 Support/Bank statement.pdf", to: "Statement.pdf", in: tree),
                       [BinderRename(from: "4000 Support/Bank statement.pdf", to: "4000 Support/Statement.pdf")])
        XCTAssertEqual(BinderIndexer.retitle("4000 Support", to: "Support", in: tree), [])
        XCTAssertEqual(BinderIndexer.retitle("4000 Support", to: "A/B", in: tree), [])
        XCTAssertEqual(BinderIndexer.retitle("4000 Support", to: "  ", in: tree), [])
        // A renamed folder takes its files with it.
        try BinderFileOps.apply(BinderIndexer.retitle("4000 Support", to: "Client Support", in: tree), root: root)
        XCTAssertEqual(names("4000 Client Support"), ["4000.01 Organizer.pdf", "Bank statement.pdf"])
    }

    func testPlacingNewFilesInAFolder() throws {
        let tree = try dragBinder()
        let next = try XCTUnwrap(BinderIndexer.nextFileIndex(in: "4000 Support", tree: tree))
        XCTAssertEqual(next.text, "4000.06")
        // The default: the folder's next numbers, in the order given. A number a file arrives with is dropped.
        var plan = BinderIndexer.place(["Statement.pdf", "2000.09 Old index.pdf"], at: next, in: tree)
        XCTAssertEqual(plan.names, ["4000.06 Statement.pdf", "4000.07 Old index.pdf"])
        XCTAssertEqual(plan.renames, [])
        // A number of your choosing: what is there, and what follows without a gap, moves up past the new files.
        plan = BinderIndexer.place(["X.pdf", "Y.pdf"], at: BinderIndex(typed: "4000.02", isFolder: false), in: tree)
        XCTAssertEqual(plan.names, ["4000.02 X.pdf", "4000.03 Y.pdf"])
        XCTAssertEqual(pairs(plan.renames), ["4000.02 B.pdf > 4000 Support/4000.04 B.pdf", "4000.03 C.pdf > 4000 Support/4000.05 C.pdf", "4000.05 E.pdf > 4000 Support/4000.06 E.pdf"])
        plan = BinderIndexer.place(["X.pdf"], at: BinderIndex(typed: "4000.04", isFolder: false), in: tree)
        XCTAssertEqual(plan.names, ["4000.04 X.pdf"])
        XCTAssertEqual(plan.renames, [])
        // No index.
        plan = BinderIndexer.place(["X.pdf"], at: nil, in: tree)
        XCTAssertEqual(plan.names, ["X.pdf"])
        XCTAssertEqual(plan.renames, [])
    }

    func testEveryIndexedFileInIndexOrder() throws {
        try make("4000 Support/4000.10 Ten.pdf")
        try make("4000 Support/4000.02 Two.pdf")
        try make("5000 Permanent Files/5010 PY Tax Returns/5010.01 Return.pdf")
        try make("2000 Client Financials/2000.01 TB.xlsx")
        try make("2000 Client Financials/Loose.pdf")
        try make("0000 Binder Notes/0000.01 Notes.docx")
        // Whatever folder they are in, and by number, not by spelling (10 after 2).
        XCTAssertEqual(BinderScanner.scan(root).indexedFiles.map(\.name),
                       ["0000.01 Notes.docx", "2000.01 TB.xlsx", "4000.02 Two.pdf", "4000.10 Ten.pdf", "5010.01 Return.pdf"])
    }

    // MARK: The folders a new binder starts with

    func testStandardBinderLayout() throws {
        let layout = BinderLayout.standard
        XCTAssertEqual(layout.paths, [
            "0000 Binder Notes", "2000 Client Financials", "3000 Standard Workpapers", "3050 Additional Workpapers", "4000 Support",
            "5000 Permanent Files", "5000 Permanent Files/5010 PY Tax Returns", "5000 Permanent Files/5020 Entity Formation Documents",
            "5000 Permanent Files/5030 Tax Resolution & Notices",
        ])
        XCTAssertEqual(layout.problems(), [])
        // The outline is what the settings screen edits, and it reads back the same.
        XCTAssertEqual(BinderLayout(outline: layout.outline), layout)
        XCTAssertTrue(layout.outline.contains("5000 Permanent Files\n    5010 PY Tax Returns"))
        // Tabs indent too; blank lines are ignored; a line can't sit two levels under the one before.
        let typed = BinderLayout(outline: "1000 A\n\t1010 B\n\t\t1011 C\n\n2000 D\n            2010 E\n")
        XCTAssertEqual(typed.paths, ["1000 A", "1000 A/1010 B", "1000 A/1010 B/1011 C", "2000 D", "2000 D/2010 E"])
        XCTAssertEqual(BinderLayout(outline: "1000 A\n1000 B\n1000 A\nBad/Name").problems().count, 4)

        XCTAssertEqual(try layout.create(in: root), 9)
        XCTAssertEqual(names(), ["0000 Binder Notes", "2000 Client Financials", "3000 Standard Workpapers", "3050 Additional Workpapers", "4000 Support", "5000 Permanent Files"])
        XCTAssertEqual(names("5000 Permanent Files"), ["5010 PY Tax Returns", "5020 Entity Formation Documents", "5030 Tax Resolution & Notices"])
        // What is already there is left alone.
        try make("4000 Support/4000.01 Organizer.pdf")
        XCTAssertEqual(try layout.create(in: root), 0)
        XCTAssertEqual(names("4000 Support"), ["4000.01 Organizer.pdf"])
        // The new binder reads as one, with nothing to flag.
        let tree = BinderScanner.scan(root)
        XCTAssertEqual(tree.folders.count, 9)
        XCTAssertTrue(tree.unindexed.isEmpty && tree.duplicateIndexes.isEmpty)
    }

    func testBinderLayoutsByEntityType() throws {
        let file = root.appendingPathComponent("Binder Layouts.json")
        // Nothing saved: every entity type gets the built-in layout.
        var layouts = BinderLayouts.load(from: file)
        XCTAssertEqual(layouts.layout(forEntityType: "S Corporation (Form 1120-S)"), .standard)
        XCTAssertEqual(layouts.layout(forEntityType: ""), .standard)
        // Change the layout for everyone, and give one type its own.
        layouts.general = BinderLayout(outline: "1000 Financials\n2000 Support")
        layouts.byEntityType["Nonprofit (Form 990)"] = BinderLayout(outline: "1000 Financials\n2000 Support\n3000 Grants\n    3010 Award Letters")
        try layouts.save(to: file)
        let back = BinderLayouts.load(from: file)
        XCTAssertEqual(back, layouts)
        XCTAssertEqual(back.layout(forEntityType: "Partnership (Form 1065)").paths, ["1000 Financials", "2000 Support"])
        XCTAssertEqual(back.layout(forEntityType: "nonprofit (form 990)").paths.last, "3000 Grants/3010 Award Letters")
    }
}
