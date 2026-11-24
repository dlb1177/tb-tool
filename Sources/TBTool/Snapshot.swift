import AppKit
import TBCore

/// Development aid: `TBTool --tb-open file.json --tb-snapshot outDir` walks the main screens and
/// every window the app can open, writes a PNG of each, and quits. Used to check the interface
/// without clicking through it.
enum Snapshotter {
    static func run(into dir: URL) {
        let model = AppModel.shared
        model.quiet = true
        // --tb-light: take the pictures in the light appearance whatever the system is set to.
        if CommandLine.arguments.contains("--tb-light") { NSApp.appearance = NSAppearance(named: .aqua) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let args = CommandLine.arguments
        func files(_ flag: String) -> [URL] {
            args.indices.filter { args[$0] == flag && $0 + 1 < args.count }.map { URL(fileURLWithPath: args[$0 + 1]) }
        }

        var steps: [(String, () -> Void)] = [
            ("consolidated", { model.selection = .consolidated }),
        ]
        let first = model.engagement?.entities.first
        if let first {
            steps.append(("entity", { model.selection = .entity(first.id) }))
            steps.append(("entity-grouped", { UserDefaults.standard.set(true, forKey: "entity.byGrouping") }))
            // Select a few rows and rest the pointer on them: the panel with their total in each column.
            steps.append(("selection-total", {
                UserDefaults.standard.set(false, forKey: "entity.byGrouping")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let table = find(GridTableView.self, in: NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") ?? false }?.contentView) else { return }
                    table.selectRowIndexes(IndexSet(3...7), byExtendingSelection: false)
                    let rect = table.rect(ofRow: 5)
                    table.hoverHandler?(table.convert(NSPoint(x: rect.minX + 420, y: rect.midY), to: nil))
                }
            }))
            steps.append(("selection-cleared", {
                find(GridTableView.self, in: NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") ?? false }?.contentView)?.deselectAll(nil)
            }))
            // Click a heading while laid out by grouping: the list goes plain, sorted, and the button with it.
            steps.append(("entity-grouped-sorted", {
                guard let table = find(GridTableView.self, in: NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") ?? false }?.contentView),
                      let column = table.tableColumns.first(where: { $0.title == "Unadjusted" }), let proto = column.sortDescriptorPrototype else { return }
                table.sortDescriptors = [proto]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    FileHandle.standardError.write(Data("by grouping after sorting: \(UserDefaults.standard.bool(forKey: "entity.byGrouping"))\n".utf8))
                }
            }))
            steps.append(("entity-plain", { UserDefaults.standard.set(false, forKey: "entity.byGrouping") }))
        }
        steps.append(("journal", { model.selection = .journal }))
        steps.append(("accounts", { model.selection = .accounts }))
        steps.append(("groupings", { model.selection = .groupings }))
        steps.append(("reports", {
            UserDefaults.standard.set(ReportKind.consolidating.rawValue, forKey: "reports.kind")
            model.selection = .reports
        }))
        steps.append(("reports-journal", {
            UserDefaults.standard.set(ReportKind.journal.rawValue, forKey: "reports.kind")
            model.selection = .reports
        }))
        // The exports themselves, written beside the pictures so they can be looked at.
        steps.append(("exports", {
            UserDefaults.standard.set(ReportKind.consolidating.rawValue, forKey: "reports.kind")
            guard let ledger = model.ledger else { return }
            let reports = Reports(ledger: ledger)
            try? PDFReport.data([reports.journalReport()]).write(to: dir.appendingPathComponent("journal.pdf"))
            try? PDFReport.data([reports.consolidating(basis: .book, hideZero: true, prior: 1)]).write(to: dir.appendingPathComponent("consolidating.pdf"))
            try? PDFReport.data([reports.groupingSummary(basis: .book, detail: true, prior: 0, hideZero: true)]).write(to: dir.appendingPathComponent("grouping-detail.pdf"))
            try? PDFReport.data(reports.workbook(prior: 1, hideZero: true).filter { !$0.flat && $0.sheetName != "Accounts" }).write(to: dir.appendingPathComponent("all.pdf"))
            try? Exporter.xlsx(reports.workbook(prior: 1, hideZero: true)).write(to: dir.appendingPathComponent("workbook.xlsx"))
            try? Data(Exporter.csv(reports.journalReport(), heading: true).utf8).write(to: dir.appendingPathComponent("journal.csv"))
        }))
        steps.append(("binder", { model.selection = .binder }))
        steps.append(("change-log", { model.selection = .changeLog }))
        if let tree = model.binder, let target = tree.unindexed.first(where: { !$0.isFolder }) ?? tree.files.first(where: { !$0.parentPath.isEmpty }) {
            steps.append(("binder-index", { model.showSetIndex(for: target.path) }))
        }
        if let first {
            steps.append(("entity-details", {
                Windows.shared.closeAll()
                model.showEntityDetails(first.id)
            }))
        }
        if let entry = model.engagement?.journalEntries.first {
            steps.append(("editor", { model.editEntry(entry.id) }))
            // Type into the reference picker: every indexed file in the binder, narrowed as you type.
            steps.append(("reference-search", {
                guard let window = NSApp.windows.first(where: { $0.title.hasPrefix("Journal Entry") }),
                      let field = findAll(SearchTextField.self, in: window.contentView).first(where: { ($0.placeholderString ?? "").hasPrefix("Add a reference") }) else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.string = "state"
                field.textDidChange(Notification(name: NSText.didChangeNotification, object: field.currentEditor()))
            }))
            steps.append(("activity", {
                Windows.shared.closeAll()
                model.showActivity(accountID: entry.lines.first?.account ?? "", entityID: nil)
            }))
        }
        if let first, first.balances.count >= 2 {
            // A new entry window: type into the account search, then show the unposted entry on the trial balance.
            steps.append(("editor-new", {
                Windows.shared.closeAll()
                model.selection = .entity(first.id)
                model.newEntry(.adjusting, entityID: first.id)
            }))
            steps.append(("account-search", {
                guard let window = NSApp.windows.first(where: { $0.title == "New Journal Entry" }),
                      let field = find(SearchTextField.self, in: window.contentView) else { return }
                window.makeFirstResponder(field)
                field.currentEditor()?.string = "tax"
                field.textDidChange(Notification(name: NSText.didChangeNotification, object: field.currentEditor()))
            }))
            let draft = JournalEntry(number: "AJE-DRAFT", type: .adjusting, date: model.engagement?.periodEnd ?? "", description: "Being typed",
                                     lines: [JELine(entity: first.id, account: first.balances[0].account, amount: Money(cents: 250_000)),
                                             JELine(entity: first.id, account: first.balances[1].account, amount: Money(cents: -250_000))])
            steps.append(("live-preview", {
                Windows.shared.closeAll()
                model.setDraft(draft, id: draft.id)
                model.showActivity(accountID: first.balances[0].account, entityID: first.id)
            }))
            steps.append(("live-preview-cleared", { model.setDraft(nil, id: draft.id) }))
            steps.append(("balances", {
                Windows.shared.closeAll()
                model.showBalanceEditor(entityID: first.id, priorYear: nil)
            }))
        }
        // Grouping screens: the list with its subgroups, the editor, and the accounts behind a grouping.
        if let e = model.engagement {
            let used = Set(e.accounts.compactMap(\.grouping))
            let sub = e.groupings.first { $0.parent != nil }
            let pick = sub.flatMap { e.parentGrouping(of: $0) } ?? e.groupings.first { used.contains($0.id) }
            if let pick {
                steps.append(("group-detail", {
                    Windows.shared.closeAll()
                    model.selection = .groupings
                    model.showGroupDetail(groupingID: pick.id, basis: .book)
                }))
                steps.append(("grouping-editor", {
                    Windows.shared.closeAll()
                    model.showGroupingEditor(GroupingDraft(pick), sections: e.groupingSections)
                }))
            }
        }
        steps.append(("new-account", {
            Windows.shared.closeAll()
            model.showNewAccount()
        }))
        steps.append(("settings", {
            Windows.shared.closeAll()
            model.showSettings()
        }))
        steps.append(("app-settings", {
            Windows.shared.closeAll()
            model.showAppSettings()
        }))
        steps.append(("app-settings-binder", {
            Windows.shared.closeAll()
            UserDefaults.standard.set("binder", forKey: "settings.tab")
            model.showAppSettings()
        }))
        steps.append(("app-settings-reset", {
            Windows.shared.closeAll()
            UserDefaults.standard.set("groupings", forKey: "settings.tab")
        }))
        steps.append(("rollforward", {
            Windows.shared.closeAll()
            model.showRollForward()
        }))
        steps.append(("links", {
            Windows.shared.closeAll()
            model.showFixLinks()
        }))
        steps.append(("grouping-import", {
            Windows.shared.closeAll()
            var list = GroupingList.standard
            list.name = "Sample list"
            list.groupings.removeLast(3)
            list.groupings.append(Grouping(id: "S19", code: "S19", name: "OTHER DEDUCTIONS", section: "Page 1 Accounts"))
            model.showGroupingImport(GroupingImportRequest(sourceName: "Sample", list: list))
        }))
        steps.append(("filters", {
            Windows.shared.closeAll()
            let sample = FilterSet(matchAll: true, conditions: [
                FilterCondition(column: "Consolidated", op: .atLeast, value: "10,000"),
                FilterCondition(column: "Grp", op: .isEmpty),
                FilterCondition(column: "Consolidated", op: .between, value: "1", value2: "500"),
                FilterCondition(column: "", op: .contains, value: "rent"),
                FilterCondition(column: FilterCondition.accountTypeColumn, op: .notEquals, value: "Expense"),
            ])
            Windows.shared.show("filters-demo", title: "Filters", size: NSSize(width: 660, height: 360), minSize: NSSize(width: 660, height: 300)) {
                FilterEditor(filter: .constant(sample), columns: [FilterColumn(title: "Account", isAmount: false), FilterColumn(title: "Grp", isAmount: false),
                                                                  FilterColumn(title: "Consolidated", isAmount: true), .accountType], storageKey: "demo")
            }
        }))
        steps.append(("setup", {
            Windows.shared.closeAll()
            model.newFilePanel()
        }))
        steps.append(("windows-closed", { Windows.shared.closeAll() }))

        // --tb-import <file> (repeatable): show the import confirmation for each file.
        let importFiles = files("--tb-import")
        for (n, url) in importFiles.enumerated() {
            steps.append(("import-\(n + 1)", {
                model.cancelAllImports()
                model.queueImports([url])
            }))
        }
        if !importFiles.isEmpty { steps.append(("import-closed", { model.cancelAllImports() })) }
        // --tb-conflict <file>: import it over the first trial balance and show the account-name review.
        if let url = files("--tb-conflict").first, let first {
            steps.append(("name-review", {
                model.cancelAllImports()
                model.queueImports([url], replacing: first.id)
                if !model.importQueue.isEmpty { model.importQueue[0].reviewNames = true }
            }))
            steps.append(("name-review-closed", { model.cancelAllImports() }))
        }
        // --tb-chart <file>: show the chart of accounts import for it.
        if let url = files("--tb-chart").first {
            steps.append(("chart-import", {
                if let chart = try? ChartTransfer.read(url: url) {
                    model.showChartImport(ChartImportRequest(sourceName: url.lastPathComponent, chart: chart))
                }
            }))
            steps.append(("chart-closed", { Windows.shared.closeAll() }))
        }

        // --tb-views: walk the screens that depend on view preferences (grouping layouts, the reports
        // while an entry is being typed, zero rows shown, a column resized and moved and then come
        // back to). It changes this binary's preferences, so it is kept out of the plain run.
        if args.contains("--tb-views"), let first, first.balances.count >= 2 {
            let defaults = UserDefaults.standard
            let draft = JournalEntry(number: "AJE-LIVE", type: .adjusting, date: model.engagement?.periodEnd ?? "", description: "Being typed",
                                     lines: [JELine(entity: first.id, account: first.balances[0].account, amount: Money(cents: 99_999_00)),
                                             JELine(entity: first.id, account: first.balances[1].account, amount: Money(cents: -99_999_00))])
            steps.append(("view-groupings", {
                defaults.set("groupings", forKey: "consolidated.layout")
                model.selection = .consolidated
            }))
            steps.append(("view-detail", { defaults.set("detail", forKey: "consolidated.layout") }))
            steps.append(("view-reports-live", {
                defaults.set(ReportKind.groupingSummary.rawValue, forKey: "reports.kind")
                model.setDraft(draft, id: draft.id)
                model.selection = .reports
                if let g = model.engagement?.account(first.balances[0].account)?.grouping { model.showGroupDetail(groupingID: g, basis: .book) }
            }))
            steps.append(("view-accounts-live", { model.selection = .accounts }))
            steps.append(("view-zero-shown", {
                Windows.shared.closeAll()
                model.setDraft(nil, id: draft.id)
                defaults.set(false, forKey: HideZeroToggle.key)
                defaults.set("accounts", forKey: "consolidated.layout")
                model.selection = .consolidated
            }))
            steps.append(("view-zero-hidden", { defaults.set(true, forKey: HideZeroToggle.key) }))
            // Resize one column and drag another, as a person would; leave the screen and come back.
            steps.append(("view-columns-changed", {
                model.selection = .entity(first.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let table = find(GridTableView.self, in: NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") ?? false }?.contentView
                                           ?? NSApp.windows.first?.contentView) else { return }
                    if let name = table.tableColumns.first(where: { $0.title == "Name" }) { name.width = 150 }
                    let from = table.column(withIdentifier: NSUserInterfaceItemIdentifier("Tax Basis"))
                    if from >= 0 { table.moveColumn(from, toColumn: 3) }
                    if let rje = table.tableColumns.first(where: { $0.title == "RJE" }) {
                        // Hidden through the same path the header menu uses.
                        table.headerView?.menu?.delegate?.menuNeedsUpdate?(table.headerView!.menu!)
                        if let item = table.headerView?.menu?.items.first(where: { ($0.representedObject as? NSTableColumn) === rje }) {
                            _ = item.target?.perform(item.action, with: item)
                        }
                    }
                }
            }))
            steps.append(("view-columns-away", { model.selection = .journal }))
            steps.append(("view-columns-back", {
                model.selection = .entity(first.id)
                FileHandle.standardError.write(Data("saved layout: \(GridLayout.load("entity"))\n".utf8))
            }))
            steps.append(("view-columns-reset", {
                GridLayout().save("entity")
                model.selection = .consolidated
            }))
        }

        // With --tb-exercise the run also changes the file (use a scratch copy): it posts entries,
        // undoes one, edits a balance, brings in a prior year, exports, and rolls forward — so saving,
        // backups, undo, and export are exercised for real.
        if args.contains("--tb-exercise"), let e = model.engagement, let entity = first, entity.balances.count >= 2 {
            let a = entity.balances[0].account, b = entity.balances[1].account
            func entry(_ type: JEType, _ cents: Int64) -> JournalEntry {
                JournalEntry(number: e.nextEntryNumber(for: type), type: type, date: e.periodEnd, description: "Exercise \(type.label)",
                             lines: [JELine(entity: entity.id, account: a, amount: Money(cents: cents)),
                                     JELine(entity: entity.id, account: b, amount: Money(cents: -cents))])
            }
            steps.append(("posted", {
                var je = entry(.adjusting, 123_456)
                je.rollForward = .withAmounts
                je.references = [FileReference(path: "Workpapers/Moved away.xlsx")]
                model.mutate("Post AJE") { try $0.post(je) }
                model.selection = .entity(entity.id)
            }))
            // A separate step, so it lands in its own undo group (undo groups by run-loop event).
            steps.append(("posted-2", { model.mutate("Post RJE") { try $0.post(entry(.reclassifying, 5_000)) } }))
            steps.append(("undone", { model.undoManager?.undo() }))
            steps.append(("posted-reversing", {
                var je = entry(.adjusting, 77_700)
                je.number = model.engagement?.nextEntryNumber(for: .adjusting) ?? je.number
                je.description = "Exercise accrual to reverse"
                je.lines[0].memo = "Accrued at year end"
                je.rollForward = .reversal
                model.mutate("Post AJE") { try $0.post(je) }
            }))
            steps.append(("rejected", {
                // Must be refused: a non-eliminating entry across two trial balances.
                var bad = entry(.taxOnly, 100)
                if e.entities.count > 1 { bad.lines[1].entity = e.entities[1].id }
                let accepted = model.mutate("Post TJE") { try $0.post(bad) }
                model.alert = nil
                model.status = accepted ? "EXERCISE FAILED: cross-entity entry accepted" : "Cross-entity tax-only entry correctly refused"
            }))
            steps.append(("balance-edited", {
                // Move 10.00 between the first two accounts by hand; the trial balance stays in balance.
                var balances = model.engagement!.editableBalances(entity: entity.id)
                balances[0].amount += Money(cents: 1_000)
                balances[1].amount -= Money(cents: 1_000)
                model.mutate("Edit Balances") { try $0.setBalances(balances, for: entity.id) }
            }))
            // --tb-prior <file>: bring a file in as the first trial balance's prior year.
            for url in files("--tb-prior") {
                steps.append(("prior-import", {
                    let year = (model.engagement?.currentYear ?? 2026) - 1
                    model.queueImports([url], replacing: entity.id, priorYear: year)
                }))
                steps.append(("prior-committed", {
                    guard let request = model.importQueue.first, let e = model.engagement, let year = request.priorYear else { return }
                    let guess = TBImporter.bestGuess(sheets: request.sheets, profiles: model.importProfiles, knownTypes: e.accountTypes)
                    let p = TBImporter.evaluate(request.sheets[guess.sheetIndex], guess.mapping, sourceName: request.sourceName, knownTypes: e.accountTypes)
                    model.commitImport(request, tb: p.tb, mapping: guess.mapping, header: nil, target: entity.id, newName: "", rememberLayout: false, priorYear: year)
                    model.alert = nil
                }))
            }
            steps.append(("links-broken", {
                model.selection = .journal
                model.showFixLinks()
            }))
            steps.append(("exported", {
                Windows.shared.closeAll()
                model.quickExport()
                model.selection = .journal
            }))
            // Commit each --tb-import file through the same path the Import button uses.
            for (n, url) in importFiles.enumerated() {
                steps.append(("committed-\(n + 1)", {
                    model.queueImports([url])
                    guard let request = model.importQueue.first, let e = model.engagement else { return }
                    let guess = TBImporter.bestGuess(sheets: request.sheets, profiles: model.importProfiles, knownTypes: e.accountTypes)
                    let p = TBImporter.evaluate(request.sheets[guess.sheetIndex], guess.mapping, sourceName: request.sourceName, knownTypes: e.accountTypes)
                    model.commitImport(request, tb: p.tb, mapping: guess.mapping, header: guess.mapping.headerRow.map { request.sheets[guess.sheetIndex].rows[$0] },
                                       target: nil, newName: "Imported \(n + 1) " + request.suggestedName, rememberLayout: false)
                    model.alert = nil
                }))
            }
            steps.append(("rolled-forward", {
                guard let folder = model.folder, let year = model.engagement?.currentYear else { return }
                // The binder goes too: next year's folder beside this one, every file by its default.
                let next = BinderRoller.defaultDestination(for: folder, fromYear: year, toYear: year + 1)
                let dest = next.appendingPathComponent(Engagement.rolledFileName(model.fileURL?.lastPathComponent ?? "TB.json", from: year, to: year + 1))
                var choices = model.binder.map(BinderRoller.defaultChoices) ?? [:]
                // One of each: the first file a placeholder, the last left behind.
                if let files = model.binder?.files, files.count >= 2 {
                    choices[files[0].path] = .placeholder
                    choices[files[files.count - 1].path] = .skip
                }
                if model.rollForward(RollForwardOptions(), to: dest, binderChoices: model.binder == nil ? nil : choices) { model.open(dest) }
                model.alert = nil
                model.selection = .binder
            }))
            steps.append(("rolled-journal", { model.selection = .journal }))
        }

        // With --tb-binder-demo the run works in the binder (use a scratch copy): it signs files
        // off, changes one afterwards, closes a folder, and opens the windows that confirm a drag
        // and a drop from Finder.
        if args.contains("--tb-binder-demo"), let tree = model.binder {
            let files = tree.indexedFiles.filter { !$0.isPlaceholder }
            steps.append(("binder-marks", {
                Windows.shared.closeAll()
                model.selection = .binder
                for (n, file) in files.prefix(6).enumerated() {
                    model.toggleSignOff(.prepared, on: file.path)
                    if n < 4 { model.toggleSignOff(.reviewed, on: file.path) }
                    if n < 2 { model.toggleSignOff(.secondReviewed, on: file.path) }
                }
                // One workpaper is changed after it was signed off.
                if files.count > 3, let handle = try? FileHandle(forWritingTo: tree.url(files[3])) {
                    handle.seekToEndOfFile()
                    handle.write(Data(" ".utf8))
                    try? handle.close()
                }
                if let folder = tree.folders.last(where: { !$0.children.isEmpty && $0.depth == 0 }) { model.collapsedFolders = [folder.path] }
                model.refreshBinder()
            }))
            let support = tree.folders.first { $0.children.filter { !$0.isFolder && $0.index != nil }.count >= 2 && $0.name.contains("Financials") } ?? tree.folders.first { $0.children.filter { !$0.isFolder && $0.index != nil }.count >= 2 }
            if let support {
                let inside = support.children.filter { !$0.isFolder && $0.index != nil }
                steps.append(("binder-move", { model.showBinderMove(inside[0].path, .after(inside[min(3, inside.count - 1)].path)) }))
            }
            if let placeholder = tree.files.first(where: { $0.isPlaceholder && $0.index != nil }), let arriving = tree.unindexed.first(where: { !$0.isFolder }) ?? tree.unfiled.first {
                steps.append(("binder-replace", {
                    Windows.shared.closeAll()
                    model.showBinderMove(arriving.path, .onto(placeholder.path))
                }))
            }
            steps.append(("binder-add", {
                Windows.shared.closeAll()
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tbtool-drop-\(UUID().uuidString.prefix(6))", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let incoming = ["Bank statement - Brighton.pdf", "Bank statement - Clayton.pdf"].map { dir.appendingPathComponent($0) }
                incoming.forEach { try? Data("x".utf8).write(to: $0) }
                let target = tree.folders.first { $0.name.contains("Support") } ?? tree.folders[0]
                model.showAddToBinder(incoming, folderPath: target.path)
            }))
            steps.append(("binder-flat", {
                Windows.shared.closeAll()
                UserDefaults.standard.set(true, forKey: "binder.flat")
                model.selection = .binder
            }))
            steps.append(("binder-nested", { UserDefaults.standard.set(false, forKey: "binder.flat") }))
            if let placeholder = tree.files.first(where: { $0.isPlaceholder && $0.index != nil }) {
                steps.append(("binder-arrive", {
                    Windows.shared.closeAll()
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tbtool-drop-\(UUID().uuidString.prefix(6))", isDirectory: true)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let url = dir.appendingPathComponent("Lender statement - December.pdf")
                    try? Data("x".utf8).write(to: url)
                    model.showReplacePlaceholder(.outside(url), placeholder: placeholder.path)
                }))
            }
            steps.append(("binder-log", {
                Windows.shared.closeAll()
                model.selection = .changeLog
            }))
            // The same changes carried out, then undone, with the folder listed after each.
            func listing(_ what: String) {
                let names = (model.binder?.files ?? []).filter { !$0.parentPath.hasPrefix("5000") }.map(\.path).joined(separator: "\n    ")
                FileHandle.standardError.write(Data("\(what):\n    \(names)\n  references: \(model.engagement?.journalEntries.flatMap { $0.references.map(\.path) } ?? [])\n  signed: \(Set(model.engagement?.signOffs.map(\.path) ?? []).sorted())\n".utf8))
            }
            if let support {
                let inside = support.children.filter { !$0.isFolder && $0.index != nil }
                steps.append(("binder-moved", {
                    model.selection = .binder
                    listing("before")
                    model.applyBinderMove(BinderIndexer.move(inside[0].path, .after(inside[min(3, inside.count - 1)].path), in: model.binder!))
                    listing("after dragging \(inside[0].name) below \(inside[min(3, inside.count - 1)].name)")
                }))
            }
            steps.append(("binder-added", {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tbtool-drop-\(UUID().uuidString.prefix(6))", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let incoming = ["Bank statement - Brighton.pdf", "Bank statement - Clayton.pdf"].map { dir.appendingPathComponent($0) }
                incoming.forEach { try? Data("x".utf8).write(to: $0) }
                guard let tree = model.binder, let target = tree.folders.first(where: { $0.name.contains("Support") }) else { return }
                // At a number that is taken, so the files there have to make room.
                model.addToBinder(incoming, folderPath: target.path, start: BinderIndex(typed: "\(target.index!.prefix).02", isFolder: false), copy: false)
                listing("after adding two files at .02 (originals still in the drop folder: \((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []))")
                model.alert = nil
            }))
            steps.append(("binder-undo-add", {
                model.undoManager?.undo()
                listing("after undoing the add")
            }))
            steps.append(("binder-undo-move", {
                model.undoManager?.undo()
                listing("after undoing the drag")
            }))
            // Folders, placeholders, several files at once, indexing a selection, a free number, the Trash.
            steps.append(("binder-ops", {
                model.trashFolder = dir.appendingPathComponent("trash", isDirectory: true)
                guard let t0 = model.binder else { return }
                model.makeBinderFolder(named: "Correspondence", number: BinderIndexer.newFolderIndex(in: "", tree: t0)?.text ?? "", in: "")
                if let perm = t0.folders.first(where: { $0.name.contains("Permanent") }) {
                    model.makeBinderFolder(named: "Loan Documents", number: BinderIndexer.newFolderIndex(in: perm.path, tree: t0)?.text ?? "", in: perm.path)
                }
                guard let support = t0.folders.first(where: { $0.name.contains("Support") }) else { return }
                model.makePlaceholder(named: "K-1 - Lakeside.pdf", index: BinderIndexer.nextFileIndex(in: support.path, tree: model.binder!)?.text ?? "", in: support.path)
                listing("after a new folder, a new subfolder and a new placeholder (folders: \(model.binder!.folders.map(\.name)))")
                // Several files from outside come in unindexed; then the selection is indexed.
                let drop = FileManager.default.temporaryDirectory.appendingPathComponent("tbtool-drop-\(UUID().uuidString.prefix(6))", isDirectory: true)
                try? FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
                let incoming = ["Invoice A.pdf", "Invoice B.pdf", "Invoice C.pdf"].map { drop.appendingPathComponent($0) }
                incoming.forEach { try? Data("x".utf8).write(to: $0) }
                model.addToBinder(incoming, folderPath: support.path, start: nil, copy: false)
                listing("after dropping three files at once")
                model.applyBinderRenames(BinderIndexer.index(Set(incoming.map { support.path + "/" + $0.lastPathComponent }), in: model.binder!), actionName: "Index Files")
                listing("after indexing the three selected")
                model.alert = nil
            }))
            steps.append(("binder-trash", {
                guard let tree = model.binder, let support = tree.folders.first(where: { $0.name.contains("Support") }),
                      let second = support.children.first(where: { $0.index?.suffix == 2 }), let loose = support.children.first(where: { !$0.isFolder && $0.index == nil }) else { return }
                model.trashBinderItems([second.path])
                listing("after moving \(second.name) to the Trash")
                // Now a number is free between 01 and 03: a file let go there takes it, and nothing else moves.
                let first = model.binder!.item(support.path)!.children.first { $0.index?.suffix == 1 }!
                let renames = BinderIndexer.move(loose.path, .after(first.path), in: model.binder!)
                FileHandle.standardError.write(Data("  drag \(loose.name) below \(first.name): \(renames.map { "\($0.from) > \($0.to)" })\n".utf8))
                if renames.count == 1 { model.applyBinderMove(renames) }
                listing("after the drag onto the free number")
            }))
            steps.append(("binder-untrash", {
                model.undoManager?.undo()
                listing("after undoing the drag")
                model.undoManager?.undo()
                listing("after undoing the Trash")
            }))
            steps.append(("binder-arrived", {
                guard let tree = model.binder, let placeholder = tree.files.first(where: { $0.isPlaceholder && $0.index?.suffix == 3 }) else { return }
                let drop = FileManager.default.temporaryDirectory.appendingPathComponent("tbtool-drop-\(UUID().uuidString.prefix(6))", isDirectory: true)
                try? FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
                let url = drop.appendingPathComponent("Lender statement - December.pdf")
                try? Data("x".utf8).write(to: url)
                model.arrive(.outside(url), at: placeholder.path, replace: true)
                model.alert = nil
                listing("after a document from outside replaced \(placeholder.name) (in the test trash: \((try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("trash").path)) ?? []))")
            }))
            // A real click on a row, then Return: the name becomes a field to type in, as in Finder.
            func mainWindow() -> NSWindow? { NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") ?? false } }
            func post(_ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags = []) {
                guard let window = mainWindow(), let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
                NSApp.postEvent(e, atStart: false)
            }
            func key(_ code: UInt16, _ characters: String) {
                guard let window = mainWindow(), let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                                         windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                                         isARepeat: false, keyCode: code) else { return }
                NSApp.postEvent(e, atStart: false)
            }
            func rowPoint(_ suffix: String) -> NSPoint? {
                guard let screen = BinderScreen.current, let content = mainWindow()?.contentView,
                      let frame = screen.rowFrames.first(where: { $0.key.hasSuffix(suffix) })?.value else { return nil }
                var p = NSPoint(x: frame.minX + 260, y: frame.midY)
                if !content.isFlipped { p.y = content.bounds.height - p.y }
                return content.convert(p, to: nil)
            }
            steps.append(("binder-click", {
                Windows.shared.closeAll()
                UserDefaults.standard.set(false, forKey: "binder.flat")
                model.collapsedFolders = []
                model.selection = .binder
                mainWindow()?.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let a = rowPoint("Organizer.pdf"), let b = rowPoint("Bank statement - Ashford.pdf") else {
                        FileHandle.standardError.write(Data("  no row frames: \(BinderScreen.current?.rowFrames.count ?? -1)\n".utf8))
                        return
                    }
                    post(.leftMouseDown, at: a)
                    post(.leftMouseUp, at: a)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        // ⌘-click a second row: both are selected, and the press is matched to its row.
                        post(.leftMouseDown, at: b, flags: .command)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            FileHandle.standardError.write(Data("  press matched to: \(BinderScreen.current?.pressed?.path ?? "nothing")\n".utf8))
                            post(.leftMouseUp, at: b, flags: .command)
                        }
                    }
                }
            }))
            steps.append(("binder-rename", {
                FileHandle.standardError.write(Data("  selected after a click and a ⌘-click: \((BinderScreen.current?.selection ?? []).sorted())\n".utf8))
                guard let b = rowPoint("Bank statement - Ashford.pdf") else { return }
                post(.leftMouseDown, at: b)
                post(.leftMouseUp, at: b)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { key(36, "\r") }
            }))
            steps.append(("binder-renamed", {
                FileHandle.standardError.write(Data("  renaming: \(BinderScreen.current?.renaming ?? "nothing") — field holds “\(BinderScreen.current?.renameText ?? "")”\n".utf8))
                BinderScreen.current?.renameText = "Bank statement - Ashford (December)"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    key(36, "\r")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { listing("after typing a new name and pressing Return") }
                }
            }))
            // A new version let go on a file; a file turned into a placeholder; several files moved at once.
            steps.append(("binder-onfile", {
                Windows.shared.closeAll()
                model.trashFolder = dir.appendingPathComponent("trash", isDirectory: true)
                guard let tree = model.binder, let target = tree.files.first(where: { $0.index?.text == "4000.01" }) else { return }
                let drop = FileManager.default.temporaryDirectory.appendingPathComponent("tbtool-drop-\(UUID().uuidString.prefix(6))", isDirectory: true)
                try? FileManager.default.createDirectory(at: drop, withIntermediateDirectories: true)
                let url = drop.appendingPathComponent("Organizer - signed copy.pdf")
                try? Data("the new version".utf8).write(to: url)
                model.toggleSignOff(.prepared, on: target.path)
                model.showDropOnFile(.outside(url), target: target.path)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    model.replaceVersion(.outside(url), of: target.path)
                    let now = (try? String(contentsOf: tree.url(target), encoding: .utf8)) ?? "?"
                    listing("after a new version replaced \(target.name) (it now reads “\(now)”; changed since sign-off: \(!model.staleSignOffs.isEmpty))")
                    model.alert = nil
                }
            }))
            steps.append(("binder-version-undone", {
                Windows.shared.closeAll()
                model.undoManager?.undo()
                if let tree = model.binder, let target = tree.files.first(where: { $0.index?.text == "4000.01" }) {
                    listing("after undoing the new version (it reads “\(((try? String(contentsOf: tree.url(target), encoding: .utf8)) ?? "?").trimmingCharacters(in: .whitespacesAndNewlines))” again)")
                }
            }))
            steps.append(("binder-to-placeholder", {
                guard let tree = model.binder, let target = tree.files.first(where: { $0.index?.text == "4000.01" }) else { return }
                model.turnIntoPlaceholder(target.path)
                listing("after turning \(target.name) into a placeholder")
                // Two files from one folder into another, as one move.
                let pair = Set(model.binder!.files.filter { $0.index?.prefix == "2000" }.prefix(2).map(\.path))
                if let other = model.binder!.folders.first(where: { $0.name.contains("Additional") }) {
                    model.applyBinderRenames(BinderIndexer.file(pair, into: other.path, in: model.binder!), actionName: "Move in Binder")
                    FileHandle.standardError.write(Data("  two files moved together: \(model.binder!.item(other.path)!.children.map(\.name))\n".utf8))
                }
            }))
            steps.append(("binder-log-2", { model.selection = .changeLog }))
        }

        // With --tb-keys-demo (use a scratch copy): leaving a search box with Esc and with a click,
        // Return on the button the keyboard is on, adding a file to a trial balance, and
        // renumbering an account.
        if args.contains("--tb-keys-demo"), let first, first.balances.count >= 2 {
            func main() -> NSWindow? { NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") ?? false } }
            func click(_ point: NSPoint, in window: NSWindow) {
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) { NSApp.postEvent(e, atStart: false) }
                }
            }
            func press(_ code: UInt16, _ characters: String, in window: NSWindow) {
                if let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) { NSApp.postEvent(e, atStart: false) }
            }
            func say(_ text: String) { FileHandle.standardError.write(Data("  \(text)\n".utf8)) }
            func typing(_ window: NSWindow?) -> String { window?.firstResponder is NSText ? "a text field" : "the window (not a text field)" }
            func searchField() -> NSTextField? {
                findAll(NSTextField.self, in: main()?.contentView).first { ($0.placeholderString ?? "").hasPrefix("Search files") }
            }
            steps.append(("search-typing", {
                Windows.shared.closeAll()
                UserDefaults.standard.set(false, forKey: "binder.flat")
                model.selection = .binder
                main()?.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard let window = main(), let field = searchField() else { return say("no search field found") }
                    click(field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil), in: window)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        say("after clicking the search box, the keyboard is in: \(typing(window))")
                        BinderScreen.current?.query = "trial"
                    }
                }
            }))
            steps.append(("search-escaped", {
                guard let window = main() else { return }
                press(53, "\u{1B}", in: window)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    say("after Esc, the keyboard is in: \(typing(window)); the search still reads “\(BinderScreen.current?.query ?? "")”")
                }
            }))
            steps.append(("search-clicked-off", {
                guard let window = main(), let field = searchField() else { return }
                click(field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil), in: window)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let was = typing(window)
                    guard let screen = BinderScreen.current, let content = window.contentView, let frame = screen.rowFrames.first(where: { $0.key.hasSuffix("Trial Balance.csv") })?.value else { return say("no row to click") }
                    var p = NSPoint(x: frame.minX + 260, y: frame.midY)
                    if !content.isFlipped { p.y = content.bounds.height - p.y }
                    click(content.convert(p, to: nil), in: window)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        say("clicked the search box (keyboard in \(was)), then a row: keyboard in \(typing(window)); selected \(screen.selection.map { ($0 as NSString).lastPathComponent }); search still “\(screen.query)”")
                    }
                }
            }))
            steps.append(("return-on-button", {
                BinderScreen.current?.query = ""
                Windows.shared.closeAll()
                model.selection = .entity(first.id)
                model.newEntry(.adjusting, entityID: first.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard let window = NSApp.windows.first(where: { $0.title == "New Journal Entry" }) else { return say("no entry window") }
                    func accountFields() -> [SearchTextField] { findAll(SearchTextField.self, in: window.contentView).filter { ($0.placeholderString ?? "").hasPrefix("Type an account") } }
                    let before = accountFields().count
                    if args.contains("--tb-probe") {
                        // What the keyboard lands on as Tab is pressed through the window.
                        say("full keyboard access: \(NSApp.isFullKeyboardAccessEnabled)")
                        window.makeKeyAndOrderFront(nil)
                        if let memo = findAll(NSTextField.self, in: window.contentView).last(where: { $0.isEditable }) { window.makeFirstResponder(memo) }
                        var last = ""
                        func hop(_ n: Int) {
                            guard n < 30 else { return }
                            press(48, "\t", in: window)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                let r = window.firstResponder
                                let view = r as? NSView
                                let field = ((r as? NSTextView)?.delegate as? NSTextField)?.placeholderString ?? ""
                                let what = "\(r.map { String(describing: type(of: $0)) } ?? "nil") \(field) \((r as? NSButton)?.title ?? "") super \(view?.superview.map { String(describing: type(of: $0)) } ?? "")"
                                if what != last || !(r is NSTextView) { say("tab \(n): \(what)") }
                                last = what
                                hop(n + 1)
                            }
                        }
                        hop(0)
                        return
                    }
                    // Tab from the last line's memo lands on Add Line; Return then presses it.
                    window.makeKeyAndOrderFront(nil)
                    guard let memo = findAll(NSTextField.self, in: window.contentView).last(where: { $0.isEditable && !($0 is SearchTextField) }) else { return say("no memo field") }
                    window.makeFirstResponder(memo)
                    press(48, "\t", in: window)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        say("after Tab the keyboard is on: \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing")")
                        press(36, "\r", in: window)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            let fields = accountFields()
                            let editing = (window.firstResponder as? NSTextView)?.delegate as? NSTextField
                            say("Return: \(before) lines before, \(fields.count) after; the cursor is in the new line's account field: \(editing != nil && editing === fields.last)")
                        }
                    }
                }
            }))
            if let url = files("--tb-import").first {
                steps.append(("import-add", {
                    Windows.shared.closeAll()
                    model.queueImports([url], replacing: first.id, appending: true)
                }))
                steps.append(("import-added", {
                    guard let request = model.importQueue.first, let e = model.engagement else { return }
                    let guess = TBImporter.bestGuess(sheets: request.sheets, profiles: model.importProfiles, knownTypes: e.accountTypes)
                    let p = TBImporter.evaluate(request.sheets[guess.sheetIndex], guess.mapping, sourceName: request.sourceName, knownTypes: e.accountTypes)
                    let had = e.entity(first.id)?.balances.count ?? 0
                    model.commitImport(request, tb: p.tb, mapping: guess.mapping, header: nil, target: first.id, newName: "", rememberLayout: false, mode: .append(.add))
                    model.alert = nil
                    say("added \(url.lastPathComponent) to \(first.name): \(had) balances before, \(model.engagement?.entity(first.id)?.balances.count ?? 0) after — \(model.status)")
                    model.undoManager?.undo()
                    say("after undo: \(model.engagement?.entity(first.id)?.balances.count ?? 0) balances")
                }))
            }
            let account = first.balances[0].account
            steps.append(("edit-account", {
                model.cancelAllImports()
                Windows.shared.closeAll()
                model.selection = .accounts
                model.showEditAccount(account)
            }))
            steps.append(("account-changed", {
                Windows.shared.closeAll()
                let before = model.ledger?.value(.book, entity: first.id, account: account)
                model.changeAccount(account, number: "10900", name: "Ashford Operating Account")
                let after = model.ledger?.value(.book, entity: first.id, account: "10900")
                say("account \(account) renumbered 10900: balance \(before?.formatted ?? "?") → \(after?.formatted ?? "?"); old number still there: \(model.engagement?.account(account) != nil); data check: \(model.issues.count) issues; log: \(model.engagement?.auditLog.last?.details ?? [])")
                model.selection = .entity(first.id)
            }))
        }

        // --tb-only a,b,c: just these steps, by name.
        if let only = files("--tb-only").first?.lastPathComponent.split(separator: ",").map(String.init) {
            steps = steps.filter { only.contains($0.0) }
        }

        func capture(_ name: String) {
            for window in NSApp.windows where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView, view.bounds.width > (window is NSPanel ? 40 : 200),
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let key = window.identifier?.rawValue ?? ""
                var tag = key.hasPrefix("main") || window.title == "TB Tool" || key.isEmpty ? "main" : String(key.split(separator: ":")[0])
                if window is NSPanel { tag = "list" }
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent("\(name)-\(tag).png"))
                }
            }
        }

        func step(_ i: Int) {
            guard i < steps.count else {
                exit(0)
            }
            steps[i].1()
            // Undo groups close at the end of a user event. Nothing here is a click or a key, so send
            // an empty event after each step; otherwise every change would land in one undo group.
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(event, atStart: false)
            }
            if args.contains("--tb-debug") {
                FileHandle.standardError.write(Data("step \(steps[i].0): undo level \(model.undoManager?.groupingLevel ?? -1) canUndo \(model.undoManager?.canUndo ?? false)\n".utf8))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                capture(String(format: "%02d-%@", i + 1, steps[i].0))
                step(i + 1)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApp.windows.first?.setFrame(NSRect(x: 60, y: 60, width: 1440, height: 880), display: true)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { step(0) }
        }
    }

    private static func findAll<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        return (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { findAll(type, in: $0) }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let hit = view as? T { return hit }
        for sub in view.subviews {
            if let hit = find(type, in: sub) { return hit }
        }
        return nil
    }
}
