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
            steps.append(("entity-plain", { UserDefaults.standard.set(false, forKey: "entity.byGrouping") }))
        }
        steps.append(("journal", { model.selection = .journal }))
        steps.append(("accounts", { model.selection = .accounts }))
        steps.append(("groupings", { model.selection = .groupings }))
        steps.append(("reports", { model.selection = .reports }))
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
            steps.append(("binder-log-2", { model.selection = .changeLog }))
        }

        // --tb-only a,b,c: just these steps, by name.
        if let only = files("--tb-only").first?.lastPathComponent.split(separator: ",").map(String.init) {
            steps = steps.filter { only.contains($0.0) }
        }

        func capture(_ name: String) {
            for window in NSApp.windows where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView, view.bounds.width > 200,
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
