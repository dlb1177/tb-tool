import Foundation
import TBCore

// Command-line access to the same engine the app uses. Every write goes through the same
// posting rules, so a script (or an AI assistant) can't put the file into a state the app wouldn't.

let usage = """
tbcli — work with a TB Tool trial balance file

  tbcli new <file.json> [--name "Client"] [--period YYYY-MM-DD]
  tbcli import <file.json> <tb.xlsx|csv|txt> [--entity "Name"] [--sheet "Tab"] [--prior-year YYYY] [--use-file-names]
                                                           import (or re-import) one trial balance; the
                                                           layout is detected (or taken from a saved one).
                                                           With --prior-year the file is that year's closing
                                                           balances (PP1, PP2…) instead of this year's.
                                                           An account the file names differently from the chart
                                                           keeps the chart's name unless --use-file-names
  tbcli map <file.json> <mapping.csv>                      assign groupings: account,grouping
  tbcli coa-export <file.json> <out.json|out.csv>          export the chart of accounts with groupings
  tbcli coa-import <file.json> <chart.json|csv|xlsx|other TB.json> [--overwrite] [--add-missing] [--no-types]
  tbcli groupings-export <file.json> <out.json|out.csv>    export the grouping list
  tbcli groupings-import <file.json> <list.json|csv|xlsx|other TB.json> [--merge]
                                                           replace the grouping list (or add to it)
  tbcli post <file.json> <entry.json>                      post one journal entry (see README)
  tbcli links <file.json>                                  list linked files that can't be found
  tbcli rollforward <file.json> <next-year.json> [--carry-balance-sheet <equity account>] [--binder]
                                                           write next year's file; this one is unchanged.
                                                           With --binder the folders and files beside this file
                                                           are rolled into the new file's folder as well: files
                                                           are copied without Finder tags, placeholders stay
                                                           placeholders, nothing there is overwritten
  tbcli check <file.json>                                  list integrity problems
  tbcli log <file.json>                                    the change log: when, who, on which Mac, what changed
  tbcli summary <file.json>                                balances check and net income
  tbcli export <file.json> <out.xlsx | out.csv>            full workbook, or the long-format data

"""

/// Saves, first adding a line to the file's change log that says what this command changed.
func saveLogged(_ e: Engagement, to url: URL, action: String) throws {
    var out = e
    let before = try? Store.load(url)
    out.log("\(action) (tbcli)", details: before.map { out.changes(since: $0) } ?? [], by: Actor.current())
    try Store.save(out, to: url)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func option(_ name: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func positional(_ args: [String]) -> [String] {
    var out: [String] = []
    var skip = false
    for a in args {
        if skip {
            skip = false
            continue
        }
        if a.hasPrefix("--") {
            // Switches stand alone; every other option is followed by its value.
            skip = !["--overwrite", "--add-missing", "--no-types", "--merge", "--use-file-names", "--binder"].contains(a)
            continue
        }
        out.append(a)
    }
    return out
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(0)
}
let rest = Array(args.dropFirst())
let pos = positional(rest)

do {
    switch command {
    case "new":
        guard pos.count == 1 else { fail(usage) }
        let url = URL(fileURLWithPath: pos[0])
        guard !FileManager.default.fileExists(atPath: url.path) else { fail("\(url.lastPathComponent) already exists.") }
        let year = Calendar.current.component(.year, from: Date())
        var e = Engagement(name: option("--name", in: rest) ?? url.deletingPathExtension().lastPathComponent,
                           periodEnd: option("--period", in: rest) ?? "\(year)-12-31")
        e.log("Created the file (tbcli)", details: [url.lastPathComponent], by: Actor.current())
        try Store.save(e, to: url)
        print("Created \(url.lastPathComponent)")

    case "import":
        guard pos.count == 2 else { fail(usage) }
        let url = URL(fileURLWithPath: pos[0])
        var e = try Store.load(url)
        let source = URL(fileURLWithPath: pos[1])
        let sheets = try SourceReader.read(url: source)
        let result = try TBImporter.automatic(sheets: sheets, sourceName: source.lastPathComponent, profiles: ImportProfiles.load(),
                                              sheet: option("--sheet", in: rest), knownTypes: e.accountTypes)
        let tb = result.preview.tb
        let name = option("--entity", in: rest) ?? TBImporter.suggestedEntityName(fileName: source.lastPathComponent)
        let id: String
        if let existing = e.entities.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id == name }) {
            id = existing.id
        } else {
            id = try e.addEntity(named: name)
        }
        let priorYear = option("--prior-year", in: rest).flatMap { Int($0) }
        if option("--prior-year", in: rest) != nil && priorYear == nil { fail("--prior-year needs a year, e.g. 2025.") }
        // Accounts the file names differently from the chart: the chart's name stands (and is reported)
        // unless the file's names were asked for.
        var decisions: [String: AccountNameResolution] = [:]
        let renames = e.accountNameConflicts(in: tb)
        if rest.contains("--use-file-names") {
            for c in renames { decisions[c.accountID] = AccountNameResolution(.useFileName) }
        }
        let warnings = try priorYear.map { try e.importPriorPeriod(tb, into: id, year: $0, resolving: decisions) }
            ?? e.importTrialBalance(tb, into: id, resolving: decisions)
        if !decisions.isEmpty { renames.forEach { print("  renamed \($0.number): “\($0.chartName)” → “\($0.fileName)”") } }
        try saveLogged(e, to: url, action: priorYear.map { "Import \($0) Balances" } ?? "Import \(name)")
        let m = result.mapping
        func letter(_ i: Int) -> String {
            var n = i + 1, s = ""
            while n > 0 { s = String(UnicodeScalar(UInt8(65 + (n - 1) % 26))) + s; n = (n - 1) / 26 }
            return s
        }
        let cols = m.roles.enumerated().filter { $0.element != .ignore }.map { "\(letter($0.offset))=\($0.element.label)" }.joined(separator: ", ")
        let p = result.preview
        if let priorYear { print("as \(e.priorLabel(priorYear)) closing balances —") }
        print("\(name): \(tb.accountCount) accounts\(tb.rows.count != tb.accountCount ? " from \(tb.rows.count) rows" : ""), debits \(tb.totalDebits.grouped), credits \(tb.totalCredits.grouped)")
        print("  read: sheet “\(sheets[result.sheetIndex].name)”, header \(m.headerRow.map { "row \($0 + 1)" } ?? "none"), \(cols)\(m.usesBalance ? ", \(m.sign.label.lowercased())" : "")\(m.fromSavedLayout ? " (saved layout)" : "")")
        print("  skipped: \(p.count(.total)) total lines, \(p.count(.heading)) headings, \(p.count(.noAccount)) unlabeled amounts")
        warnings.forEach { print("  warning: \($0)") }

    case "map":
        guard pos.count == 2 else { fail(usage) }
        let url = URL(fileURLWithPath: pos[0])
        var e = try Store.load(url)
        let text = try String(contentsOf: URL(fileURLWithPath: pos[1]), encoding: .utf8)
        let result = e.applyGroupingMap(csv: text)
        try saveLogged(e, to: url, action: "Map Groupings")
        print("Mapped \(result.applied) accounts")
        result.warnings.forEach { print("  warning: \($0)") }

    case "coa-export":
        guard pos.count == 2 else { fail(usage) }
        let e = try Store.load(URL(fileURLWithPath: pos[0]))
        let out = URL(fileURLWithPath: pos[1])
        let chart = ChartTransfer.chart(of: e)
        switch out.pathExtension.lowercased() {
        case "json": try ChartTransfer.json(chart).write(to: out, options: .atomic)
        case "csv": try Data(ChartTransfer.csv(chart).utf8).write(to: out, options: .atomic)
        default: fail("Export the chart to .json or .csv.")
        }
        print("Wrote \(chart.accounts.count) accounts to \(out.lastPathComponent)")

    case "coa-import":
        guard pos.count == 2 else { fail(usage) }
        let url = URL(fileURLWithPath: pos[0])
        var e = try Store.load(url)
        let chart = try ChartTransfer.read(url: URL(fileURLWithPath: pos[1]))
        var o = ChartImportOptions()
        o.overwriteGroupings = rest.contains("--overwrite")
        o.addMissing = rest.contains("--add-missing")
        o.applyTypes = !rest.contains("--no-types")
        let plan = e.planChartImport(chart, options: o)
        e.applyChartImport(plan)
        try saveLogged(e, to: url, action: "Import Chart of Accounts")
        print("Matched \(plan.matched) of \(chart.accounts.count) accounts: \(plan.groupingChanges) groupings set, \(plan.typeChanges) types changed, \(plan.added.count) added, \(plan.newGroupings.count) new groupings")
        if !plan.keptExisting.isEmpty { print("  kept \(plan.keptExisting.count) existing groupings (use --overwrite to replace)") }
        if !plan.unmatched.isEmpty { print("  \(plan.unmatched.count) source accounts not in this file (use --add-missing to add)") }
        plan.unresolved.prefix(20).forEach { print("  unresolved grouping: \($0)") }

    case "groupings-export":
        guard pos.count == 2 else { fail(usage) }
        let e = try Store.load(URL(fileURLWithPath: pos[0]))
        let out = URL(fileURLWithPath: pos[1])
        let list = GroupingTransfer.list(of: e)
        switch out.pathExtension.lowercased() {
        case "json": try GroupingTransfer.json(list).write(to: out, options: .atomic)
        case "csv": try Data(GroupingTransfer.csv(list).utf8).write(to: out, options: .atomic)
        default: fail("Export the grouping list to .json or .csv.")
        }
        print("Wrote \(list.groupings.count) groupings to \(out.lastPathComponent)")

    case "groupings-import":
        guard pos.count == 2 else { fail(usage) }
        let url = URL(fileURLWithPath: pos[0])
        var e = try Store.load(url)
        let list = try GroupingTransfer.read(url: URL(fileURLWithPath: pos[1]))
        let plan = e.planGroupingImport(list, mode: rest.contains("--merge") ? .merge : .replace)
        e.applyGroupingImport(plan, name: rest.contains("--merge") ? nil : list.name)
        try saveLogged(e, to: url, action: "Import Grouping List")
        print("\(plan.result.count) groupings: \(plan.added.count) added, \(plan.updated.count) changed, \(plan.removed.count) removed")
        if !plan.ungrouped.isEmpty { print("  \(plan.ungrouped.count) accounts are now ungrouped: \(plan.ungrouped.prefix(10).map(\.id).joined(separator: ", "))") }

    case "links":
        guard pos.count == 1 else { fail(usage) }
        let url = URL(fileURLWithPath: pos[0])
        let folder = url.deletingLastPathComponent()
        let broken = LinkFinder.withCandidates(try Store.load(url).brokenLinks(folder: folder), folder: folder)
        if broken.isEmpty {
            print("Every linked file was found.")
        } else {
            for l in broken {
                print("\(l.entryNumber): \(l.reference.path)" + (l.suggestion.map { "  → found at \($0)" } ?? ""))
            }
            exit(2)
        }

    case "log":
        guard pos.count == 1 else { fail(usage) }
        let e = try Store.load(URL(fileURLWithPath: pos[0]))
        for a in e.auditLog {
            print("\(a.at)  \(a.action)  — \(a.actor.display), \(a.actor.computer)")
            a.details.forEach { print("    \($0)") }
        }
        if let broken = e.auditLogBreak {
            print("Line \(broken + 1) doesn't follow from the line before it: the log was changed outside TB Tool.")
            exit(2)
        }
        print("\(e.auditLog.count) line\(e.auditLog.count == 1 ? "" : "s"); the log is unbroken.")

    case "rollforward":
        guard pos.count == 2 else { fail(usage) }
        let url = URL(fileURLWithPath: pos[0]), dest = URL(fileURLWithPath: pos[1])
        guard url.standardizedFileURL != dest.standardizedFileURL else { fail("Give the next year's file a different name.") }
        guard !FileManager.default.fileExists(atPath: dest.path) else { fail("\(dest.lastPathComponent) already exists.") }
        let e = try Store.load(url)
        var o = RollForwardOptions()
        o.sourceName = url.lastPathComponent
        o.actor = Actor.current()
        if let equity = option("--carry-balance-sheet", in: rest) {
            guard let account = e.resolveAccount(equity) else { fail("No account “\(equity)” in the chart.") }
            o.opening = .carryBalanceSheet(closeInto: account.id)
        }
        let summary = try e.rollForwardSummary()
        var next = try e.rolledForward(o)
        if rest.contains("--binder") {
            let tree = BinderScanner.scan(url.deletingLastPathComponent())
            let r = try BinderRoller.roll(tree, to: dest.deletingLastPathComponent(), choices: BinderRoller.defaultChoices(tree))
            next.relink(after: r.renamed)
            next.log("Binder rolled forward (tbcli)", details: ["\(r.folders) folders created, \(r.copied) files copied, \(r.placeholders) placeholders left"], by: Actor.current())
            print("Binder: \(r.folders) folders created, \(r.copied) files rolled forward, \(r.placeholders) placeholders" + (r.alreadyThere.isEmpty ? "" : ", \(r.alreadyThere.count) already there and left alone"))
        } else {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Store.save(next, to: dest)
        print("Rolled \(summary.fromYear) forward to \(dest.lastPathComponent) (year ended \(summary.newPeriodEnd))")
        print("  \(summary.fromYear) balances are PP1; entries: \(summary.entryCounts)")

    case "post":
        guard pos.count == 2 else { fail(usage) }
        let url = URL(fileURLWithPath: pos[0])
        var e = try Store.load(url)
        var entry = try Store.decodeEntry(data: try Data(contentsOf: URL(fileURLWithPath: pos[1])))
        if entry.number.isEmpty { entry.number = e.nextEntryNumber(for: entry.type) }
        if entry.date.isEmpty { entry.date = e.periodEnd }
        // Lines may name the trial balance by its display name instead of its id.
        for i in entry.lines.indices where e.entity(entry.lines[i].entity) == nil {
            if let match = e.entities.first(where: { $0.name.caseInsensitiveCompare(entry.lines[i].entity) == .orderedSame }) {
                entry.lines[i].entity = match.id
            }
        }
        try e.post(entry)
        try saveLogged(e, to: url, action: "Post \(entry.number)")
        print("Posted \(entry.number): debits \(entry.totalDebits.grouped), credits \(entry.totalCredits.grouped)")

    case "check":
        guard pos.count == 1 else { fail(usage) }
        let checkedURL = URL(fileURLWithPath: pos[0])
        let checked = try Store.load(checkedURL)
        let issues = checked.issues()
        // The binder the file sits in: loose files, items with no index, numbers used twice.
        var binderNotes: [String] = []
        if BinderScanner.isLikelyBinder(checkedURL.deletingLastPathComponent().standardizedFileURL) {
            let tree = BinderScanner.scan(checkedURL.deletingLastPathComponent())
            if !tree.unfiled.isEmpty { binderNotes.append("Binder: \(tree.unfiled.count) loose file(s) beside the trial balance: \(tree.unfiled.prefix(5).map(\.name).joined(separator: ", "))") }
            if !tree.unindexed.isEmpty { binderNotes.append("Binder: \(tree.unindexed.count) item(s) with no index: \(tree.unindexed.prefix(5).map(\.path).joined(separator: ", "))") }
            for d in tree.duplicateIndexes { binderNotes.append("Binder: index \(d.index) is used by \(d.items.count) items") }
        }
        let noActivity = checked.entities.filter { $0.activityNumber.trimmingCharacters(in: .whitespaces).isEmpty }
        if !noActivity.isEmpty { binderNotes.append("\(noActivity.count) trial balance(s) with no activity number: \(noActivity.map(\.name).joined(separator: ", "))") }
        if let broken = checked.auditLogBreak { binderNotes.append("Change log: line \(broken + 1) doesn't follow from the line before it — the log was changed outside TB Tool.") }
        // Not a fault in the file, but work left to do: say so either way.
        let ungrouped = checked.ungroupedAccounts
        let note = ungrouped.isEmpty ? nil
            : "\(ungrouped.count) account\(ungrouped.count == 1 ? " isn't" : "s aren't") grouped: \(ungrouped.prefix(8).map(\.display).joined(separator: ", "))\(ungrouped.count > 8 ? ", …" : "")"
        if issues.isEmpty {
            print("Clean: no problems found.")
            if let note { print(note) }
            binderNotes.forEach { print($0) }
        } else {
            issues.forEach { print($0) }
            if let note { print(note) }
            binderNotes.forEach { print($0) }
            exit(2)
        }

    case "summary":
        guard pos.count == 1 else { fail(usage) }
        let e = try Store.load(URL(fileURLWithPath: pos[0]))
        let ledger = Ledger(e)
        print("\(e.name) — as of \(e.periodEnd)" + (e.priorYears.isEmpty ? "" : " — prior years: \(e.priorYears.map { e.priorLabel($0) }.joined(separator: ", "))"))
        for ent in e.entities {
            let moved = ledger.total(.rje, entity: ent.id)
            print("  \(ent.name)\(ent.activityNumber.isEmpty ? "" : " (activity \(ent.activityNumber))"): out of balance \(ledger.imbalance(.book, entity: ent.id).formatted), net income \(ledger.netIncome(.book, entity: ent.id).formatted)"
                  + (moved.isZero ? "" : ", \(moved.formatted) reclassified \(moved.cents > 0 ? "from" : "to") other trial balances"))
        }
        print("  Journal entries: \(e.journalEntries.count)")
        print("  Eliminations net to \(ledger.eliminationsTotal().formatted)")
        print("  Consolidated: out of balance \(ledger.consolidatedTotal(.book).formatted), net income \(ledger.consolidatedNetIncome(.book).formatted)")

    case "export":
        guard pos.count == 2 else { fail(usage) }
        let e = try Store.load(URL(fileURLWithPath: pos[0]))
        let out = URL(fileURLWithPath: pos[1])
        let reports = Reports(e)
        switch out.pathExtension.lowercased() {
        case "xlsx": try Exporter.xlsx(reports.workbook()).write(to: out, options: .atomic)
        case "csv": try Data(Exporter.csv(reports.tidy()).utf8).write(to: out, options: .atomic)
        default: fail("Export to .xlsx or .csv.")
        }
        print("Wrote \(out.lastPathComponent)")

    default:
        fail(usage)
    }
} catch {
    fail(error.localizedDescription)
}
