import AppKit
import SwiftUI
import TBCore
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case consolidated
    case entity(String)
    case journal
    case accounts
    case groupings
    case reports
}

struct AlertInfo: Identifiable {
    let id = UUID()
    var title: String
    var message: String
}

struct EditorRequest: Identifiable {
    let id = UUID()
    var entry: JournalEntry
    var isNew: Bool
}

struct ImportRequest: Identifiable, Equatable {
    let id = UUID()
    var sourceName: String
    var sheets: [RawSheet]
    /// Set when replacing one trial balance's balances.
    var replacing: String?
    var suggestedName: String
    /// Set when the file was chosen as a prior year's balances.
    var priorYear: Int? = nil
    /// Development aid: go straight to the account-name review, as if Import had been clicked.
    var reviewNames = false
}

struct ChartImportRequest: Identifiable {
    let id = UUID()
    var sourceName: String
    var chart: ChartData
}

struct GroupingImportRequest: Identifiable {
    let id = UUID()
    var sourceName: String
    var list: GroupingList
}

struct ActivityRequest: Identifiable {
    let id = UUID()
    var accountID: String
    var entityID: String?
}

/// Owns the open file. Every change goes through `mutate`, which applies it, registers undo,
/// and writes the JSON file straight away — there is no unsaved state.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var engagement: Engagement?
    /// What is saved in the file.
    @Published private(set) var ledger: Ledger?
    /// What the trial balance screens show: the saved file plus any journal entry being typed
    /// in an open editor window, so the effect of an entry is visible before it is posted.
    @Published private(set) var liveLedger: Ledger?
    /// Entries open in editor windows that differ from what is saved, by entry id.
    @Published private(set) var drafts: [String: JournalEntry] = [:]
    @Published private(set) var fileURL: URL?
    @Published private(set) var issues: [String] = []
    @Published private(set) var brokenLinks: [BrokenLink] = []
    @Published private(set) var candidates: [URL] = []
    @Published var selection: SidebarItem? = .consolidated
    @Published var status: String = ""
    @Published var importQueue: [ImportRequest] = [] {
        didSet { syncImportWindow() }
    }
    private(set) var importProfiles: [ImportProfile] = ImportProfiles.load()

    /// Shown as a real alert, in front of whichever window is being worked in.
    var alert: AlertInfo? {
        didSet {
            guard let info = alert, !quiet else { return }
            DispatchQueue.main.async { [weak self] in
                guard self?.alert?.id == info.id else { return }
                self?.alert = nil
                let a = NSAlert()
                a.messageText = info.title
                a.informativeText = info.message
                a.runModal()
            }
        }
    }

    weak var undoManager: UndoManager?
    /// Set while taking automated screenshots, so nothing opens a panel or Finder.
    var quiet = false

    private var diskDate: Date?
    private var sessionBackedUp = false
    private var unreadableDiskDate: Date?
    private var pendingDrafts: [String: JournalEntry] = [:]
    private var draftWork: DispatchWorkItem?

    var folder: URL? { fileURL?.deletingLastPathComponent() }

    /// A path as shown on screen: the home folder as "~". (For documentation screenshots,
    /// `--tb-display-folder <path>` shows the open file's folder as that path instead.)
    func displayPath(_ url: URL) -> String {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--tb-display-folder"), i + 1 < args.count, let folder {
            let real = folder.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            if path.hasPrefix(real) { return args[i + 1] + path.dropFirst(real.count) }
        }
        return url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: Opening

    /// The folder the app itself sits in. A trial balance file there is opened automatically.
    private var appFolder: URL { Bundle.main.bundleURL.deletingLastPathComponent() }

    func startup() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--tb-open"), i + 1 < args.count {
            // A development run: don't let it replace the file the app reopens next time.
            open(URL(fileURLWithPath: args[i + 1]), remember: false)
            return
        }
        refreshCandidates()
        if engagement != nil { return }
        if candidates.count == 1 {
            open(candidates[0])
        } else if candidates.isEmpty,
                  let last = UserDefaults.standard.string(forKey: "lastFile"),
                  FileManager.default.fileExists(atPath: last) {
            open(URL(fileURLWithPath: last))
        }
    }

    func refreshCandidates() {
        let items = (try? FileManager.default.contentsOfDirectory(at: appFolder, includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        candidates = items.filter { Store.looksLikeTrialBalance($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    func open(_ url: URL, remember: Bool = true) {
        do {
            let e = try Store.load(url)
            closeWindows()
            fileURL = url
            diskDate = modificationDate(url)
            sessionBackedUp = false
            undoManager?.removeAllActions()
            set(e)
            selection = .consolidated
            status = "Opened \(url.lastPathComponent)"
            if remember && !quiet { UserDefaults.standard.set(url.path, forKey: "lastFile") }
        } catch {
            alert = AlertInfo(title: "Couldn't open \(url.lastPathComponent)", message: error.localizedDescription)
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a trial balance JSON file"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// New files start with a setup window: client and binder details, the current year, and the grouping list.
    func newFilePanel() {
        Windows.shared.show("setup", title: "New Trial Balance File", size: NSSize(width: 620, height: 780), minSize: NSSize(width: 560, height: 520)) {
            SettingsView(mode: .setup)
        }
    }

    /// Asks where the new file goes (the last place a trial balance was opened, by default) and creates it.
    @discardableResult
    func createFile(_ e: Engagement) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.directoryURL = folder
        let year = e.currentYear.map { " \($0)" } ?? ""
        panel.nameFieldStringValue = "\(e.name)\(year) Trial Balance.json"
        panel.message = "Where should the new trial balance file live? Put it in the client's folder."
        panel.prompt = "Create"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try Store.save(e, to: url)
            open(url)
            return true
        } catch {
            alert = AlertInfo(title: "Couldn't create the file", message: error.localizedDescription)
            return false
        }
    }

    func closeFile() {
        closeWindows()
        engagement = nil
        ledger = nil
        liveLedger = nil
        fileURL = nil
        issues = []
        brokenLinks = []
        undoManager?.removeAllActions()
        UserDefaults.standard.removeObject(forKey: "lastFile")
        refreshCandidates()
    }

    private func closeWindows() {
        importQueue = []
        pendingDrafts = [:]
        drafts = [:]
        Windows.shared.closeAll()
    }

    private func set(_ e: Engagement) {
        engagement = e
        ledger = Ledger(e)
        issues = e.issues()
        rebuildLive()
        refreshLinks()
    }

    // MARK: Changing

    /// Applies a change. Returns false (and shows why) if the change was rejected; nothing is written in that case.
    @discardableResult
    func mutate(_ actionName: String, _ body: (inout Engagement) throws -> Void) -> Bool {
        guard var e = engagement else { return false }
        let old = e
        do {
            try body(&e)
        } catch {
            alert = AlertInfo(title: "\(actionName) didn't go through", message: error.localizedDescription)
            return false
        }
        if e != old { apply(e, previous: old, actionName: actionName) }
        return true
    }

    private func apply(_ new: Engagement, previous: Engagement, actionName: String) {
        set(new)
        undoManager?.registerUndo(withTarget: self) { model in
            model.apply(previous, previous: new, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        save()
    }

    private func save() {
        guard let e = engagement, let url = fileURL else { return }
        do {
            let onDisk = modificationDate(url)
            if let onDisk, let diskDate, onDisk != diskDate {
                // Someone else wrote the file since we last read it. Keep their version before overwriting.
                try backup(url, tag: "external")
                status = "The file had changed on disk; that version was kept in TB Backups."
            } else if !sessionBackedUp {
                try backup(url, tag: nil)
            }
            sessionBackedUp = true
            try Store.save(e, to: url)
            diskDate = modificationDate(url)
        } catch {
            alert = AlertInfo(title: "Couldn't save", message: error.localizedDescription)
        }
    }

    /// Picks up edits made to the JSON outside the app (a script, an editor, another tool), and
    /// linked files that were moved or renamed while the app was in the background.
    func checkExternalChange() {
        refreshLinks()
        guard let url = fileURL, let onDisk = modificationDate(url), let diskDate,
              onDisk != diskDate, onDisk != unreadableDiskDate else { return }
        do {
            let e = try Store.load(url)
            self.diskDate = onDisk
            undoManager?.removeAllActions()
            set(e)
            status = "Reloaded — \(url.lastPathComponent) was changed outside the app."
        } catch {
            // Leave diskDate alone: the next save then sees the mismatch and backs the outside version up first.
            unreadableDiskDate = onDisk
            alert = AlertInfo(title: "\(url.lastPathComponent) was changed outside the app and can't be read",
                              message: "\(error.localizedDescription)\n\nThe app is still showing the last good version. Your next change here will overwrite the file; the unreadable version will be kept in TB Backups.")
        }
    }

    private func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Copies the file as it is right now into "TB Backups" beside it, keeping the 20 most recent.
    private func backup(_ url: URL, tag: String?) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let dir = url.deletingLastPathComponent().appendingPathComponent("TB Backups", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = url.deletingPathExtension().lastPathComponent
        let name = "\(stem) \(Self.stamp())\(tag.map { " \($0)" } ?? "").json"
        let target = dir.appendingPathComponent(name)
        if !fm.fileExists(atPath: target.path) { try fm.copyItem(at: url, to: target) }
        let mine = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(stem + " ") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in mine.dropFirst(20) { try? fm.removeItem(at: old) }
    }

    static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f.string(from: Date())
    }

    // MARK: Settings and roll forward

    func showSettings() {
        guard engagement != nil else { return }
        Windows.shared.show("settings", title: "Trial Balance Settings", size: NSSize(width: 620, height: 780), minSize: NSSize(width: 560, height: 520)) {
            SettingsView(mode: .edit)
        }
    }

    func showRollForward() {
        guard engagement != nil else { return }
        Windows.shared.show("rollforward", title: "Roll Forward to Next Year", size: NSSize(width: 920, height: 640), minSize: NSSize(width: 760, height: 480)) {
            RollForwardView()
        }
    }

    /// Writes next year's file where the user chooses (this file's folder by default). This file is not changed.
    @discardableResult
    func rollForward(_ options: RollForwardOptions, to destination: URL? = nil) -> Bool {
        guard let e = engagement, let url = fileURL else { return false }
        do {
            var o = options
            o.sourceName = url.lastPathComponent
            let summary = try e.rollForwardSummary()
            let next = try e.rolledForward(o)
            var dest = destination
            if dest == nil {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.directoryURL = folder
                panel.nameFieldStringValue = Engagement.rolledFileName(url.lastPathComponent, from: summary.fromYear, to: summary.toYear)
                panel.message = "Where should the \(summary.toYear) trial balance file go? \(url.lastPathComponent) is left as it is."
                panel.prompt = "Roll Forward"
                guard panel.runModal() == .OK, let chosen = panel.url else { return false }
                dest = chosen
            }
            guard let dest, dest.standardizedFileURL != url.standardizedFileURL else {
                throw TBError("Choose a different name: that is the \(summary.fromYear) file being rolled forward.")
            }
            try Store.save(next, to: dest)
            status = "Rolled forward to \(dest.lastPathComponent)"
            Windows.shared.close("rollforward")
            if quiet { return true }
            let ask = NSAlert()
            ask.messageText = "The \(summary.toYear) file is ready"
            ask.informativeText = "\(dest.lastPathComponent)\n\n\(summary.fromYear) balances are in it as PP1. Journal entries: \(summary.entryCounts)."
            ask.addButton(withTitle: "Open the \(summary.toYear) File")
            ask.addButton(withTitle: "Stay in \(summary.fromYear)")
            if ask.runModal() == .alertFirstButtonReturn { open(dest) }
            return true
        } catch {
            alert = AlertInfo(title: "Couldn't roll forward", message: error.localizedDescription)
            return false
        }
    }

    // MARK: Trial balances

    /// Choose one or more files (Excel, CSV, tab or other delimited text). Each is read, its layout
    /// predicted, and shown for confirmation before anything is imported.
    func importPanel(replacing entityID: String? = nil, priorYear: Int? = nil) {
        guard engagement != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SourceReader.fileExtensions.compactMap { UTType(filenameExtension: $0) }
            + [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = entityID == nil
        panel.directoryURL = folder
        if let priorYear {
            panel.message = "Choose the \(priorYear) trial balance — Excel, CSV, or text. You'll confirm how it's read."
        } else {
            panel.message = entityID == nil ? "Choose trial balance files — Excel, CSV, or text. Each becomes its own trial balance; you'll confirm how it's read."
                                            : "Choose the file that replaces this trial balance"
        }
        guard panel.runModal() == .OK else { return }
        queueImports(panel.urls, replacing: entityID, priorYear: priorYear)
    }

    func queueImports(_ urls: [URL], replacing entityID: String? = nil, priorYear: Int? = nil) {
        var errors: [String] = []
        var requests: [ImportRequest] = []
        for url in urls {
            do {
                let sheets = try SourceReader.read(url: url)
                requests.append(ImportRequest(sourceName: url.lastPathComponent, sheets: sheets, replacing: entityID,
                                              suggestedName: TBImporter.suggestedEntityName(fileName: url.lastPathComponent), priorYear: priorYear))
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if !requests.isEmpty { importQueue.append(contentsOf: requests) }
        if !errors.isEmpty {
            alert = AlertInfo(title: "Some files couldn't be read", message: errors.joined(separator: "\n\n"))
        }
    }

    /// Cells copied from Excel, Numbers, a PDF viewer, or a web page.
    func pasteTrialBalance() {
        guard engagement != nil else { return }
        guard let text = NSPasteboard.general.string(forType: .string), text.contains(where: { $0.isNumber }) else {
            alert = AlertInfo(title: "Nothing to paste", message: "Copy the trial balance cells (account and amount columns) in Excel or another program first, then choose Paste Trial Balance.")
            return
        }
        let rows = SourceReader.parseDelimited(text)
        importQueue.append(ImportRequest(sourceName: "Pasted cells", sheets: [RawSheet(name: "Pasted", rows: rows)], replacing: nil,
                                         suggestedName: "Pasted Trial Balance"))
    }

    func finishImport(_ request: ImportRequest) {
        importQueue.removeAll { $0.id == request.id }
    }

    func cancelAllImports() { importQueue.removeAll() }

    /// The import window follows the queue: open while files are waiting, closed when they're done.
    private func syncImportWindow() {
        if importQueue.isEmpty {
            Windows.shared.close("import")
        } else if !Windows.shared.isOpen("import") {
            Windows.shared.show("import", title: "Import Trial Balance", size: NSSize(width: 1280, height: 820), minSize: NSSize(width: 980, height: 560),
                                onClose: { [weak self] in
                                    if self?.importQueue.isEmpty == false { self?.importQueue = [] }
                                }) {
                ImportHost()
            }
        }
    }

    /// Brings a confirmed import in. Balances are copied into the JSON file; the source file is never needed again.
    @discardableResult
    func commitImport(_ request: ImportRequest, tb: ImportedTB, mapping: ImportMapping, header: [String]?,
                      target: String?, newName: String, rememberLayout: Bool, priorYear: Int? = nil,
                      resolutions: [String: AccountNameResolution] = [:]) -> Bool {
        var warnings: [String] = []
        var landed: String?
        let action = priorYear.map { "Import \($0) Balances" } ?? (target == nil ? "Import \(newName)" : "Replace Trial Balance")
        let ok = mutate(action) { e in
            let id = try target ?? e.addEntity(named: newName)
            if let priorYear {
                warnings = try e.importPriorPeriod(tb, into: id, year: priorYear, resolving: resolutions)
            } else {
                warnings = try e.importTrialBalance(tb, into: id, resolving: resolutions)
            }
            landed = id
        }
        guard ok else { return false }
        if rememberLayout, let header, mapping.headerRow != nil {
            importProfiles = ImportProfiles.remember(mapping, header: header)
        }
        finishImport(request)
        if let landed, importQueue.isEmpty { selection = .entity(landed) }
        let name = landed.flatMap { engagement?.entity($0)?.name } ?? newName
        if let priorYear, let e = engagement {
            status = "Imported \(name) \(e.priorLabel(priorYear)): \(tb.accountCount) accounts"
            // Make sure the new column is on screen.
            let back = (e.currentYear ?? priorYear + 1) - priorYear
            if priorCount < back { UserDefaults.standard.set(back, forKey: "view.priorCount") }
        } else {
            status = "Imported \(name): \(tb.accountCount) accounts"
        }
        let chartNotes = warnings.filter { !tb.warnings.contains($0) }
        if !chartNotes.isEmpty {
            alert = AlertInfo(title: "Imported \(name) — check these", message: chartNotes.prefix(20).joined(separator: "\n"))
        }
        return true
    }

    /// A trial balance with no balances yet, to be keyed in by hand.
    func newBlankEntity() {
        guard engagement != nil else { return }
        let ask = NSAlert()
        ask.messageText = "New Blank Trial Balance"
        ask.informativeText = "Name it, then enter its balances by hand. (To bring balances in from a file, use Import instead.)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Trial balance name"
        ask.accessoryView = field
        ask.addButton(withTitle: "Create")
        ask.addButton(withTitle: "Cancel")
        ask.window.initialFirstResponder = field
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        var created: String?
        if mutate("New Trial Balance", { created = try $0.addEntity(named: field.stringValue) }), let created {
            selection = .entity(created)
            showBalanceEditor(entityID: created, priorYear: nil)
        }
    }

    func showBalanceEditor(entityID: String, priorYear: Int?) {
        guard let e = engagement, let entity = e.entity(entityID) else { return }
        let period = priorYear.map { e.priorLabel($0) } ?? "Unadjusted"
        let guardian = CloseGuard()
        guardian.what = "the balance changes"
        Windows.shared.show("balances:\(entityID):\(priorYear ?? 0)", title: "\(entity.name) — \(period) Balances",
                            size: NSSize(width: 860, height: 720), minSize: NSSize(width: 700, height: 420), frameName: "balances",
                            closeGuard: guardian) {
            BalanceEditor(entityID: entityID, priorYear: priorYear, engagement: e, closeGuard: guardian)
        }
    }

    // MARK: Journal entries

    func newEntry(_ type: JEType, entityID: String? = nil) {
        guard let e = engagement else { return }
        guard !e.entities.isEmpty else {
            alert = AlertInfo(title: "Import a trial balance first", message: "Journal entries post to a trial balance, and this file doesn't have one yet.")
            return
        }
        let entity = entityID ?? {
            if case .entity(let id) = selection { return id }
            return e.entities[0].id
        }()
        var je = JournalEntry(number: e.nextEntryNumber(for: type), type: type,
                              date: e.periodEnd.isEmpty ? Timestamp.dayString(Date()) : e.periodEnd)
        je.lines = [JELine(entity: entity, account: "", amount: .zero), JELine(entity: entity, account: "", amount: .zero)]
        openEditor(EditorRequest(entry: je, isNew: true))
    }

    func editEntry(_ id: String) {
        guard let je = engagement?.entry(id) else { return }
        openEditor(EditorRequest(entry: je, isNew: false))
    }

    func duplicateEntry(_ id: String) {
        guard let e = engagement, let source = e.entry(id) else { return }
        var je = JournalEntry(number: e.nextEntryNumber(for: source.type), type: source.type, date: source.date,
                              description: source.description, lines: source.lines, references: source.references)
        je.rollForward = source.rollForward
        openEditor(EditorRequest(entry: je, isNew: true))
    }

    /// Each entry gets its own window, so it can sit beside the trial balance (or on another
    /// display) while the balances update as the entry is typed.
    private func openEditor(_ request: EditorRequest) {
        guard let e = engagement else { return }
        let id = request.entry.id
        let guardian = CloseGuard()
        guardian.what = request.isNew ? "this new entry" : "your changes to \(request.entry.number)"
        Windows.shared.show("entry:\(id)", title: request.isNew ? "New Journal Entry" : "Journal Entry \(request.entry.number)",
                            size: NSSize(width: 1060, height: 680), minSize: NSSize(width: 900, height: 480), frameName: "entry",
                            closeGuard: guardian, onClose: { [weak self] in self?.setDraft(nil, id: id) }) {
            JournalEditor(request: request, engagement: e, closeGuard: guardian)
        }
    }

    func closeEditor(_ entryID: String) {
        setDraft(nil, id: entryID)
        Windows.shared.close("entry:\(entryID)")
    }

    func setRollForward(_ value: RollForward, for ids: Set<String>) {
        mutate("Set Roll Forward") { e in
            for i in e.journalEntries.indices where ids.contains(e.journalEntries[i].id) { e.journalEntries[i].rollForward = value }
        }
    }

    // MARK: Live preview of entries being typed

    /// Called by an editor window as its entry changes. Nil when the window closes or holds nothing new.
    func setDraft(_ entry: JournalEntry?, id: String) {
        var value = entry
        if let e = entry, let saved = engagement?.entry(id), saved.lines == e.lines, saved.type == e.type { value = nil }
        if let e = value, !e.lines.contains(where: { !$0.amount.isZero && !$0.account.isEmpty }) { value = nil }
        guard pendingDrafts[id] != value else { return }
        pendingDrafts[id] = value
        // Typing fires this on every keystroke; the screens only need to follow along.
        draftWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.drafts = self.pendingDrafts
            self.rebuildLive()
        }
        draftWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (value == nil ? 0 : 0.15), execute: work)
    }

    private func rebuildLive() {
        guard let e = engagement else {
            liveLedger = nil
            return
        }
        guard !drafts.isEmpty else {
            liveLedger = ledger
            return
        }
        var preview = e
        let entities = Set(e.entities.map(\.id)), accounts = Set(e.accounts.map(\.id))
        for (id, draft) in drafts {
            var je = draft
            je.lines = draft.lines.filter { !$0.amount.isZero && entities.contains($0.entity) && accounts.contains($0.account) }
            je.pending = false
            je.number = "\(draft.number) (unposted)"
            if let i = preview.journalEntries.firstIndex(where: { $0.id == id }) {
                preview.journalEntries[i] = je
            } else {
                preview.journalEntries.append(je)
            }
        }
        liveLedger = Ledger(preview)
    }

    // MARK: Account activity

    func showActivity(accountID: String, entityID: String?) {
        guard let e = engagement, let account = e.account(accountID) else { return }
        let scope = entityID.flatMap { e.entity($0)?.name } ?? "All trial balances"
        let request = ActivityRequest(accountID: accountID, entityID: entityID)
        Windows.shared.show("activity:\(accountID):\(entityID ?? "")", title: "\(account.display) — \(scope)",
                            size: NSSize(width: 900, height: 460), minSize: NSSize(width: 560, height: 260), frameName: "activity") {
            ActivityView(request: request)
        }
    }

    /// The accounts inside a grouping or subgroup, with every consolidation column.
    func showGroupDetail(groupingID: String, basis: Basis) {
        guard let e = engagement, e.grouping(groupingID) != nil else { return }
        Windows.shared.show("group-detail:\(groupingID)", title: e.groupingLabel(groupingID),
                            size: NSSize(width: 1040, height: 520), minSize: NSSize(width: 600, height: 280), frameName: "group-detail") {
            GroupDetailView(groupingID: groupingID, basisRaw: basis.rawValue)
        }
    }

    /// What double-clicking a report row opens: the journal entry it came from, the activity
    /// behind an account's balance, or the accounts inside a grouping.
    func open(_ row: ReportRow, basis: Basis) {
        if let id = row.entryID {
            if engagement?.entry(id) != nil { editEntry(id) }
        } else if let id = row.accountID {
            showActivity(accountID: id, entityID: row.entityID)
        } else if let id = row.groupingID {
            showGroupDetail(groupingID: id, basis: basis)
        }
    }

    func showNewAccount() {
        Windows.shared.show("new-account", title: "New Account", size: NSSize(width: 440, height: 250), minSize: NSSize(width: 400, height: 230)) {
            NewAccountSheet()
        }
    }

    /// The window that adds or edits one grouping. By default it works on the open file's list;
    /// with `source` and `commit` it works on another list (a standard list in the app's settings).
    func showGroupingEditor(_ draft: GroupingDraft, sections: [String], key: String = "grouping",
                            source: (() -> Engagement)? = nil, commit: ((GroupingDraft) -> Bool)? = nil) {
        let title = draft.groupingID == nil ? (draft.parent == nil ? "New Grouping" : "New Subgroup") : "Edit Grouping"
        Windows.shared.show("\(key):\(draft.groupingID ?? "new")", title: title,
                            size: NSSize(width: 480, height: 300), minSize: NSSize(width: 440, height: 280), frameName: "grouping-editor") {
            GroupingSheet(draft: draft, sections: sections, source: source, commit: commit)
        }
    }

    /// Settings for the app itself (as opposed to one trial balance file): the standard grouping lists.
    func showAppSettings() {
        Windows.shared.show("app-settings", title: "TB Tool Settings", size: NSSize(width: 1000, height: 720), minSize: NSSize(width: 860, height: 560)) {
            AppSettingsView()
        }
    }

    // MARK: Linked files

    func chooseFilesToLink() -> [FileReference] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.directoryURL = folder
        panel.message = "Choose the workpaper(s) this entry refers to"
        panel.prompt = "Link"
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.map { FileReference(file: $0, engagementFolder: folder) }
    }

    func url(for reference: FileReference) -> URL { reference.url(engagementFolder: folder) }

    func exists(_ reference: FileReference) -> Bool {
        FileManager.default.fileExists(atPath: url(for: reference).path)
    }

    func openReference(_ reference: FileReference) {
        let target = url(for: reference)
        if FileManager.default.fileExists(atPath: target.path) {
            NSWorkspace.shared.open(target)
        } else {
            alert = AlertInfo(title: "File not found", message: "\(target.path)\n\nIt may have been moved or renamed. Use Locate… to point the link at where it is now.")
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func refreshLinks() {
        let found = engagement?.brokenLinks(folder: folder) ?? []
        if found != brokenLinks { brokenLinks = found }
    }

    func showFixLinks() {
        Windows.shared.show("links", title: "Fix Broken File Links", size: NSSize(width: 980, height: 520), minSize: NSSize(width: 760, height: 320)) {
            FixLinksView()
        }
    }

    /// Asks where a missing file is now. Returns the new link path (relative to the folder when inside it).
    func locateFile(for reference: FileReference) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        // Start in the folder the file was last in (or the nearest one above it that still exists).
        panel.directoryURL = LinkFinder.lastKnownFolder(for: reference, folder: folder)
        panel.message = "Where is “\(reference.fileName)” now?"
        panel.prompt = "Relink"
        panel.nameFieldStringValue = reference.fileName
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return FileReference(file: url, engagementFolder: folder).path
    }

    /// Points every entry's link to `oldPath` at `newPath`, and repairs other broken links that
    /// moved along with it (same old folder, same file names in the new folder).
    func relink(_ oldPath: String, to newPath: String) {
        let siblings = LinkFinder.siblings(of: oldPath, movedTo: newPath, among: brokenLinks, folder: folder)
        var count = 0
        mutate("Relink File") { e in
            count = e.relink(oldPath, to: newPath)
            for (old, new) in siblings { count += e.relink(old, to: new) }
        }
        status = "Relinked \(count) link\(count == 1 ? "" : "s")" + (siblings.isEmpty ? "" : " — including \(siblings.count) other file\(siblings.count == 1 ? "" : "s") that moved to the same folder")
    }

    func relink(all pairs: [String: String]) {
        var count = 0
        mutate("Relink Files") { e in
            for (old, new) in pairs { count += e.relink(old, to: new) }
        }
        status = "Relinked \(count) link\(count == 1 ? "" : "s")"
    }

    func removeLink(_ link: BrokenLink) {
        mutate("Remove Link") { $0.removeLink(link.reference.path, entryID: link.entryID) }
    }

    // MARK: Export

    enum ExportFormat: String, CaseIterable {
        case xlsx, csv, json
        var label: String {
            switch self {
            case .xlsx: return "Excel"
            case .csv: return "CSV"
            case .json: return "JSON"
            }
        }
    }

    /// Every export asks where to save, starting in the trial balance file's own folder.
    private func savePanel(name: String, ext: String, message: String? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.directoryURL = folder
        panel.nameFieldStringValue = name
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        if let message { panel.message = message }
        panel.prompt = "Export"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private var exportPrefix: String {
        guard let e = engagement else { return "TB" }
        return e.currentYear.map { "\(e.name) \($0)" } ?? e.name
    }

    func export(_ table: ReportTable, as format: ExportFormat) {
        guard let url = savePanel(name: "\(exportPrefix) - \(table.sheetName).\(format.rawValue)", ext: format.rawValue) else { return }
        write(to: url) {
            switch format {
            case .xlsx: return Exporter.xlsx([table])
            case .csv: return Data(Exporter.csv(table, heading: true).utf8)
            case .json: return Data(Exporter.jsonRecords(table).utf8)
            }
        }
    }

    /// The "Prior Periods" choice on the trial balance screens (one prior year unless changed).
    private var priorCount: Int { max(0, UserDefaults.standard.object(forKey: "view.priorCount") as? Int ?? 1) }

    func exportWorkbookPanel() {
        guard let ledger else { return }
        guard let url = savePanel(name: "\(exportPrefix) - Trial Balance Workbook.xlsx", ext: "xlsx",
                                  message: "Every report as a sheet in one Excel workbook") else { return }
        write(to: url) { Exporter.xlsx(Reports(ledger: ledger).workbook(prior: self.priorCount, hideZero: HideZeroToggle.isOn)) }
    }

    /// The full workbook and the long-format data CSV, time-stamped, into a folder you choose
    /// (the trial balance file's folder unless you pick another).
    func quickExport() {
        guard let ledger, let folder else { return }
        var dir = folder.appendingPathComponent("Exports", isDirectory: true)
        if !quiet {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.directoryURL = folder
            panel.message = "Choose the folder for the workbook and the data file"
            panel.prompt = "Export Here"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            dir = chosen
        }
        let reports = Reports(ledger: ledger)
        let base = "\(exportPrefix) \(Self.stamp())"
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let workbook = dir.appendingPathComponent("\(base).xlsx")
            let data = dir.appendingPathComponent("\(base) data.csv")
            try Exporter.xlsx(reports.workbook(prior: priorCount, hideZero: HideZeroToggle.isOn)).write(to: workbook, options: .atomic)
            try Data(Exporter.csv(reports.tidy()).utf8).write(to: data, options: .atomic)
            status = "Exported \(base).xlsx and its data file to \(dir.lastPathComponent)"
            if !quiet { NSWorkspace.shared.activateFileViewerSelecting([workbook, data]) }
        } catch {
            alert = AlertInfo(title: "Export failed", message: error.localizedDescription)
        }
    }

    func copyToClipboard(_ table: ReportTable) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Exporter.tsv(table), forType: .string)
        status = "Copied “\(table.title)” — paste into a spreadsheet"
    }

    private func write(to url: URL, _ make: () -> Data) {
        do {
            try make().write(to: url, options: .atomic)
            status = "Exported \(url.lastPathComponent)"
            if !quiet { reveal(url) }
        } catch {
            alert = AlertInfo(title: "Export failed", message: error.localizedDescription)
        }
    }

    // MARK: Chart of accounts

    func importChartPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = (["json"] + SourceReader.fileExtensions).compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = folder
        panel.message = "Choose a chart of accounts export, another trial balance file, or a sheet with account and grouping columns"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            showChartImport(ChartImportRequest(sourceName: url.lastPathComponent, chart: try ChartTransfer.read(url: url)))
        } catch {
            alert = AlertInfo(title: "Couldn't read \(url.lastPathComponent)", message: error.localizedDescription)
        }
    }

    func showChartImport(_ request: ChartImportRequest) {
        Windows.shared.close("chart-import")
        Windows.shared.show("chart-import", title: "Import Chart of Accounts", size: NSSize(width: 980, height: 640), minSize: NSSize(width: 820, height: 420)) {
            ChartImportSheet(request: request)
        }
    }

    func exportChartPanel(csv: Bool) {
        guard let e = engagement else { return }
        guard let url = savePanel(name: "\(e.name) - Chart of Accounts.\(csv ? "csv" : "json")", ext: csv ? "csv" : "json",
                                  message: csv ? "A spreadsheet of accounts, types, and groupings"
                                               : "A chart file another trial balance can import (keeps custom groupings)") else { return }
        let chart = ChartTransfer.chart(of: e)
        write(to: url) { csv ? Data(ChartTransfer.csv(chart).utf8) : ChartTransfer.json(chart) }
    }

    // MARK: Grouping lists

    func importGroupingListPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = (["json"] + SourceReader.fileExtensions).compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = folder
        panel.message = "Choose a grouping list export, another trial balance file, or a sheet with Section, Code and Name columns"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            showGroupingImport(GroupingImportRequest(sourceName: url.lastPathComponent, list: try GroupingTransfer.read(url: url)))
        } catch {
            alert = AlertInfo(title: "Couldn't read \(url.lastPathComponent)", message: error.localizedDescription)
        }
    }

    func showGroupingImport(_ request: GroupingImportRequest) {
        Windows.shared.close("grouping-import")
        Windows.shared.show("grouping-import", title: "Import Grouping List", size: NSSize(width: 860, height: 620), minSize: NSSize(width: 720, height: 420)) {
            GroupingImportView(request: request)
        }
    }

    func exportGroupingListPanel(csv: Bool) {
        guard let e = engagement else { return }
        let list = GroupingTransfer.list(of: e)
        guard let url = savePanel(name: "\(list.name.replacingOccurrences(of: "/", with: "-")).\(csv ? "csv" : "json")", ext: csv ? "csv" : "json",
                                  message: csv ? "The grouping list as a spreadsheet: Section, Code, Name, ID"
                                               : "A grouping list file any trial balance file can import") else { return }
        write(to: url) { csv ? Data(GroupingTransfer.csv(list).utf8) : GroupingTransfer.json(list) }
    }

    /// Keeps this file's grouping list on this Mac under a name, as a standard list new files can start from.
    func saveGroupingListToLibrary() {
        guard let e = engagement else { return }
        if let (code, sharing) = e.sharedGroupingCodes.first {
            alert = AlertInfo(title: "Code \(code) is used by \(sharing.count) groupings",
                              message: "A standard list uses each code once. Choose Combine as Subgroups at the top of the Grouping List screen first, or change the codes.")
            return
        }
        let ask = NSAlert()
        ask.messageText = "Save as a Standard List"
        ask.informativeText = "The list is kept on this Mac. New trial balance files can start from it, and any file can switch to it. Manage the standard lists — including which entity type each is for — in TB Tool ▸ Settings."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = e.groupingListName.isEmpty || e.groupingListName == GroupingList.standardName ? "" : e.groupingListName
        field.placeholderString = "Name — e.g. S Corporation (1120-S)"
        ask.accessoryView = field
        ask.addButton(withTitle: "Save")
        ask.addButton(withTitle: "Cancel")
        ask.window.initialFirstResponder = field
        guard ask.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        do {
            // Saving over a list that is already there keeps the entity types it is the standard for.
            let types = GroupingLibrary.all().first { $0.name == name }?.entityTypes ?? []
            try GroupingLibrary.save(GroupingList(name: name, groupings: e.groupings, entityTypes: types))
            mutate("Name Grouping List") { $0.groupingListName = name }
            status = "Saved “\(name)” as a standard list"
        } catch {
            alert = AlertInfo(title: "Couldn't save the grouping list", message: error.localizedDescription)
        }
    }
}
