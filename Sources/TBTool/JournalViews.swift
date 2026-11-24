import AppKit
import SwiftUI
import TBCore
import UniformTypeIdentifiers

// MARK: - List of entries

struct JournalRow: Identifiable {
    let id: String
    let number: String
    let type: String
    let date: String
    let entities: String
    let description: String
    let amount: Int64
    let files: Int
    let broken: Int
    let roll: String
    let status: String

    var cells: [String: ReportCell] {
        ["Entry": .text(number), "Type": .text(type), "Date": .text(date), "Trial Balance": .text(entities),
         "Description": .text(description), "Amount": .money(Money(cents: amount)), "Files": .text(files == 0 ? "" : String(files)),
         "File Links": .text(broken > 0 ? "Broken" : (files > 0 ? "OK" : "")), "Next Year": .text(roll), "Status": .text(status)]
    }

    static let filterColumns = [
        FilterColumn(title: "Entry", isAmount: false), FilterColumn(title: "Type", isAmount: false, choices: JEType.allCases.map(\.label)),
        FilterColumn(title: "Date", isAmount: false),
        FilterColumn(title: "Trial Balance", isAmount: false), FilterColumn(title: "Description", isAmount: false),
        FilterColumn(title: "Amount", isAmount: true), FilterColumn(title: "File Links", isAmount: false),
        FilterColumn(title: "Next Year", isAmount: false), FilterColumn(title: "Status", isAmount: false),
    ]
}

struct JournalListView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection = Set<String>()
    @State private var filter = "all"
    @State private var search = ""
    @State private var rules = FilterSet()
    @State private var confirmDelete = false
    @State private var sortOrder: [KeyPathComparator<JournalRow>] = []
    /// Column order and hidden columns, remembered between visits.
    @AppStorage("journal.columns") private var columnLayout = TableColumnCustomization<JournalRow>()

    var body: some View {
        if let ledger = model.ledger {
            let e = ledger.engagement
            let terms = search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            let brokenByEntry = Dictionary(grouping: model.brokenLinks, by: \.entryID).mapValues(\.count)
            let all = Reports(ledger: ledger).sortedEntries().filter { filter == "all" || $0.type.rawValue == filter }.map { je in
                JournalRow(id: je.id, number: je.number, type: je.type.label, date: je.date,
                           entities: je.entityIDs.map { e.entity($0)?.name ?? $0 }.joined(separator: ", "),
                           description: je.description, amount: je.totalDebits.cents, files: je.references.count,
                           broken: brokenByEntry[je.id] ?? 0, roll: je.rollForward.short,
                           status: je.pending ? "Needs amounts" : "Posted")
            }.filter { r in
                let hay = "\(r.number) \(r.type) \(r.date) \(r.entities) \(r.description) \(Money(cents: r.amount).grouped) \(r.status)".lowercased()
                guard terms.allSatisfy({ hay.contains($0) }) else { return false }
                let cells = r.cells
                return rules.matches(cell: { cells[$0] }, all: Array(cells.values))
            }
            let entries = sortOrder.isEmpty ? all : all.sorted(using: sortOrder)
            VStack(spacing: 0) {
                PageHeader(title: "Journal Entries", subtitle: summary(e)) {
                    SearchBox(prompt: "Search", text: $search)
                        .frame(width: 190)
                    FilterButton(filter: $rules, columns: JournalRow.filterColumns, storageKey: "journal")
                    Picker("Show", selection: $filter) {
                        Text("All Types").tag("all")
                        Divider()
                        ForEach(JEType.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Edit") { if let id = selection.first { model.editEntry(id) } }
                        .disabled(selection.count != 1)
                    Button("Duplicate") { if let id = selection.first { model.duplicateEntry(id) } }
                        .disabled(selection.count != 1)
                    Menu("Next Year") {
                        ForEach(RollForward.allCases, id: \.self) { value in
                            Button(value.label) { model.setRollForward(value, for: selection) }
                        }
                    }
                    .fixedSize()
                    .disabled(selection.isEmpty)
                    .help("What the roll forward to next year does with the selected entries")
                    Button("Delete", role: .destructive) { confirmDelete = true }
                        .disabled(selection.isEmpty)
                    Menu {
                        ForEach(JEType.allCases, id: \.self) { type in
                            Button("\(type.label) Entry") { model.newEntry(type) }
                        }
                    } label: {
                        Label("New Entry", systemImage: "plus")
                    }
                    .fixedSize()
                }
                Divider()
                if !model.brokenLinks.isEmpty {
                    BrokenLinksBanner()
                    Divider()
                }
                if e.journalEntries.isEmpty {
                    EmptyState(title: "No journal entries yet",
                               message: "Adjusting, reclassifying, and tax-only entries post to one trial balance. Eliminating entries choose a trial balance on every line.",
                               button: "New Adjusting Entry") { model.newEntry(.adjusting) }
                } else {
                    Table(entries, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columnLayout) {
                        TableColumn("Entry", value: \.number, comparator: .localizedStandard) { r in Text(r.number).fontWeight(.medium) }
                            .width(min: 36, ideal: 70)
                            .customizationID("entry")
                        TableColumn("Type", value: \.type) { r in Text(r.type) }
                            .width(min: 36, ideal: 100)
                            .customizationID("type")
                        TableColumn("Date", value: \.date) { r in Text(r.date).monospacedDigit() }
                            .width(min: 36, ideal: 90)
                            .customizationID("date")
                        TableColumn("Trial Balance", value: \.entities, comparator: .localizedStandard) { r in Text(r.entities) }
                            .width(min: 36, ideal: 170)
                            .customizationID("trial-balance")
                        TableColumn("Description", value: \.description, comparator: .localizedStandard) { r in Text(r.description) }
                            .width(min: 36, ideal: 300)
                            .customizationID("description")
                        TableColumn("Amount", value: \.amount) { r in
                            if r.status == "Posted" {
                                Text(Money(cents: r.amount).grouped).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                            } else {
                                Text("needs amounts").foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .trailing)
                            }
                        }
                        .width(min: 36, ideal: 120)
                        .customizationID("amount")
                        TableColumn("Files", value: \.files) { r in
                            if r.broken > 0 {
                                Label("\(r.broken) missing", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("\(r.broken) of this entry's \(r.files) linked file\(r.files == 1 ? "" : "s") can't be found. Choose Fix Links to repair.")
                            } else if r.files > 0 {
                                Label("\(r.files)", systemImage: "paperclip").foregroundStyle(.secondary)
                            }
                        }
                        .width(min: 36, ideal: 96)
                        .customizationID("files")
                        TableColumn("Next Year", value: \.roll) { r in Text(r.roll).foregroundStyle(.secondary) }
                            .width(min: 36, ideal: 120)
                            .customizationID("next-year")
                    }
                    .background(TableColumnFitter(key: "journal", contents: [
                        "Entry": entries.map(\.number), "Type": entries.map(\.type), "Date": entries.map(\.date), "Trial Balance": entries.map(\.entities),
                        "Description": entries.map(\.description), "Amount": entries.map { $0.status == "Posted" ? Money(cents: $0.amount).grouped : "needs amounts" },
                        "Files": ["0 missing"], "Next Year": entries.map(\.roll),
                    ], extra: ["Files": 22]))
                    .contextMenu(forSelectionType: String.self) { ids in
                        if ids.count == 1, let id = ids.first {
                            Button("Edit") { model.editEntry(id) }
                            Button("Duplicate") { model.duplicateEntry(id) }
                            Divider()
                        }
                        if !ids.isEmpty {
                            Menu("Next Year") {
                                ForEach(RollForward.allCases, id: \.self) { value in
                                    Button(value.label) { model.setRollForward(value, for: ids) }
                                }
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                selection = ids
                                confirmDelete = true
                            }
                        }
                    } primaryAction: { ids in
                        if let id = ids.first { model.editEntry(id) }
                    }
                }
            }
            .confirmationDialog("Delete \(selection.count) journal entr\(selection.count == 1 ? "y" : "ies")?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    let ids = selection
                    model.mutate("Delete Journal Entr\(ids.count == 1 ? "y" : "ies")") { e in ids.forEach { e.deleteEntry($0) } }
                    ids.forEach { model.closeEditor($0) }
                    selection = []
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The balances go back to what they were without \(selection.count == 1 ? "it" : "them"). You can undo this.")
            }
        }
    }

    private func summary(_ e: Engagement) -> String {
        var parts = JEType.allCases.compactMap { type -> String? in
            let n = e.journalEntries.filter { $0.type == type }.count
            return n == 0 ? nil : "\(n) \(type.label.lowercased())"
        }
        let waiting = e.journalEntries.filter(\.pending).count
        if waiting > 0 { parts.append("\(waiting) rolled forward and waiting for amounts") }
        return parts.isEmpty ? "Double-click an entry to edit it" : parts.joined(separator: " · ") + " · double-click to edit"
    }
}

/// Shown wherever journal entries are listed while any linked workpaper can't be found.
struct BrokenLinksBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let n = model.brokenLinks.count
        HStack(spacing: 10) {
            Label("\(n) linked file\(n == 1 ? "" : "s") can't be found — moved or renamed since \(n == 1 ? "it was" : "they were") linked.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Button("Fix Links…") { model.showFixLinks() }
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.08))
    }
}

// MARK: - Editor

private struct DraftLine: Identifiable, Equatable {
    let id = UUID()
    var entity: String
    var accountID: String?
    var debit = ""
    var credit = ""
    var memo = ""
}

struct JournalEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var closeWindow
    @AppStorage("editor.livePreview") private var livePreview = true

    let request: EditorRequest
    let closeGuard: CloseGuard

    @State private var type: JEType
    @State private var number: String
    @State private var date: Date
    @State private var descriptionText: String
    @State private var entityID: String
    @State private var lines: [DraftLine]
    @State private var references: [FileReference]
    @State private var rollForward: RollForward
    @State private var baseline: JournalEntry?
    /// The line whose account field should take the cursor: the one just added.
    @State private var focusLine: UUID?
    @State private var confirmDelete = false
    /// Set while the type picker is being put back after a change that isn't allowed.
    @State private var revertingType = false

    init(request: EditorRequest, engagement: Engagement, closeGuard: CloseGuard) {
        self.request = request
        self.closeGuard = closeGuard
        let je = request.entry
        _rollForward = State(initialValue: je.rollForward)
        _type = State(initialValue: je.type)
        _number = State(initialValue: je.number)
        _date = State(initialValue: Timestamp.day(from: je.date) ?? Date())
        _descriptionText = State(initialValue: je.description)
        _entityID = State(initialValue: je.lines.first?.entity ?? engagement.entities.first?.id ?? "")
        _lines = State(initialValue: je.lines.map { l in
            DraftLine(entity: l.entity,
                      accountID: l.account.isEmpty ? nil : l.account,
                      debit: l.amount.cents > 0 ? l.amount.plain : "",
                      credit: l.amount.cents < 0 ? (-l.amount).plain : "",
                      memo: l.memo)
        })
        _references = State(initialValue: je.references)
    }

    private var engagement: Engagement { model.engagement ?? Engagement(name: "", periodEnd: "") }

    /// The entry as it would be posted, plus everything stopping it from being posted.
    private var built: (entry: JournalEntry, errors: [String]) {
        var errors: [String] = []
        var out: [JELine] = []
        for (i, l) in lines.enumerated() {
            let debitText = l.debit.trimmingCharacters(in: .whitespaces)
            let creditText = l.credit.trimmingCharacters(in: .whitespaces)
            if l.accountID == nil && debitText.isEmpty && creditText.isEmpty && l.memo.isEmpty { continue }
            guard let d = Money.parse(debitText), let c = Money.parse(creditText) else {
                errors.append("Line \(i + 1): the amount isn't a number.")
                continue
            }
            if d.rounded || c.rounded { errors.append("Line \(i + 1): amounts can have at most two decimals.") }
            if !d.value.isZero && !c.value.isZero { errors.append("Line \(i + 1): enter a debit or a credit, not both.") }
            out.append(JELine(entity: type.canSpanTrialBalances ? l.entity : entityID,
                              account: l.accountID ?? "", amount: d.value - c.value, memo: l.memo.trimmingCharacters(in: .whitespaces)))
        }
        var je = request.entry
        je.type = type
        je.number = number
        je.date = Timestamp.dayString(date)
        je.description = descriptionText
        je.lines = out
        je.references = references.map { r in
            var r = r
            r.sheet = r.sheet.trimmingCharacters(in: .whitespaces)
            r.cells = WorkbookTabs.cells(r.cells) ?? r.cells
            return r
        }
        for r in je.references where r.isWorkbook {
            if r.sheet.isEmpty { errors.append("Choose the tab of “\(r.fileName)” this entry refers to.") }
            if WorkbookTabs.cells(r.cells) == nil { errors.append("“\(r.cells)” isn't a cell reference. Type cells like B4 or B4:D10, or leave them out.") }
        }
        je.rollForward = rollForward
        // Filling in the amounts completes an entry that was rolled forward without them.
        je.pending = false
        // Line numbers in the rule messages refer to the lines as typed, which matches when no blank lines sit in between.
        errors.append(contentsOf: engagement.validationErrors(for: je))
        return (je, errors)
    }

    var body: some View {
        let result = built
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    linesSection
                    referencesSection
                }
                .padding(16)
            }
            Divider()
            footer(result)
        }
        .frame(minWidth: 900, minHeight: 480)
        .onAppear {
            if baseline == nil { baseline = result.entry }
            publish(result.entry)
        }
        .onChange(of: result.entry) { _, new in publish(new) }
        .onChange(of: livePreview) { _, _ in publish(result.entry) }
        .confirmationDialog("Delete \(request.entry.number)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                model.mutate("Delete \(request.entry.number)") { $0.deleteEntry(request.entry.id) }
                closeGuard.isDirty = false
                closeWindow()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Tells the trial balance screens what this entry looks like right now, so they show its
    /// effect while it is being typed — before anything is posted.
    private func publish(_ entry: JournalEntry) {
        closeGuard.isDirty = baseline != nil && entry != baseline
        model.setDraft(livePreview ? entry : nil, id: request.entry.id)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(request.isNew ? "New Journal Entry" : "Edit \(request.entry.number)")
                    .font(.title3.bold())
                Spacer()
                Picker("Type", selection: $type) {
                    ForEach(JEType.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .onChange(of: type) { old, new in typeChanged(from: old, to: new) }
            }
            HStack(spacing: 14) {
                LabeledField("Number") {
                    TextField("", text: $number).textFieldStyle(.roundedBorder).frame(width: 90)
                }
                LabeledField("Date") {
                    DatePicker("", selection: $date, displayedComponents: .date).labelsHidden()
                }
                if type.canSpanTrialBalances {
                    LabeledField("Posts to") {
                        Text("Chosen on each line").foregroundStyle(.secondary).frame(height: 22)
                    }
                } else {
                    LabeledField("Posts to") {
                        Picker("", selection: $entityID) {
                            ForEach(engagement.entities) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                }
                LabeledField("Description") {
                    TextField("What this entry is for", text: $descriptionText).textFieldStyle(.roundedBorder)
                }
                LabeledField("Next year") {
                    Picker("", selection: $rollForward) {
                        ForEach(RollForward.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .help("What the roll forward to next year does with this entry: leave it behind, carry it with its amounts (a recurring entry), carry the accounts with the amounts blank, or carry it reversed — debits and credits swapped, each line's memo marked “[Reversal from year]”.")
                }
            }
            if request.entry.pending {
                Label("Rolled forward from last year without amounts. Enter this year's amounts and post it — until then it posts nothing.", systemImage: "arrow.uturn.forward.circle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Text(typeHelp).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if type == .reclassifying, let note = allocationNote {
                Label(note, systemImage: "arrow.left.arrow.right").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    /// For a reclassifying entry that names several trial balances: what each one ends up with.
    private var allocationNote: String? {
        let entry = built.entry
        var net: [String: Money] = [:]
        var order: [String] = []
        for l in entry.lines {
            if net[l.entity] == nil { order.append(l.entity) }
            net[l.entity, default: .zero] += l.amount
        }
        guard order.count > 1 else { return nil }
        let parts = order.filter { !net[$0]!.isZero }.map { "\(engagement.entity($0)?.name ?? $0) \(net[$0]!.formatted)" }
        if parts.isEmpty { return "This entry names \(order.count) trial balances and balances within each one." }
        return "Moves between trial balances: \(parts.joined(separator: ", ")). Each of those is out of balance by that much on its own; the consolidation stays in balance."
    }

    private var typeHelp: String {
        switch type {
        case .adjusting: return "Posts to one trial balance. Shows in the AJE column and flows into Adjusted, Final, and Tax."
        case .reclassifying: return "Shows in the RJE column and flows into Final and Tax. Pick the trial balance on each line: keep them the same to reclassify within one, or name several to allocate an amount across them in one entry."
        case .taxOnly: return "Posts to one trial balance. Shows in the TJE column and only changes the Tax basis."
        case .eliminating: return "The only entry type that can span trial balances: pick one on each line. It shows in the Eliminations column of the consolidation and leaves each trial balance itself unchanged."
        }
    }

    private func typeChanged(from old: JEType, to new: JEType) {
        // An adjusting or tax-only entry posts to one trial balance, so an entry that names several
        // can't be turned into one. Put the type back and say why.
        if !new.canSpanTrialBalances && old.canSpanTrialBalances && usedEntities.count > 1 {
            let names = usedEntities.map { engagement.entity($0)?.name ?? $0 }.joined(separator: ", ")
            revertingType = true
            type = old
            model.alert = AlertInfo(title: "\(new == .adjusting ? "An adjusting" : "A tax-only") entry posts to one trial balance",
                                    message: "This entry has lines on \(usedEntities.count) trial balances (\(names)). Put every line on the same trial balance first, or post a separate entry for each.")
            return
        }
        if revertingType {
            revertingType = false
            return
        }
        // Keep a hand-typed number; otherwise follow the type's own sequence.
        let wasAutomatic = number == request.entry.number || number == engagement.nextEntryNumber(for: old, excluding: request.entry.id)
        if wasAutomatic {
            number = (new == request.entry.type && !request.isNew) ? request.entry.number
                                                                    : engagement.nextEntryNumber(for: new, excluding: request.entry.id)
        }
        if new.canSpanTrialBalances && !old.canSpanTrialBalances {
            for i in lines.indices { lines[i].entity = entityID }
        } else if !new.canSpanTrialBalances && old.canSpanTrialBalances, let first = usedEntities.first ?? lines.first?.entity, engagement.entity(first) != nil {
            entityID = first
        }
    }

    /// The trial balances named on lines that have something on them.
    private var usedEntities: [String] {
        var seen = Set<String>()
        return lines.filter { $0.accountID != nil || !$0.debit.trimmingCharacters(in: .whitespaces).isEmpty || !$0.credit.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(\.entity).filter { seen.insert($0).inserted }
    }

    // MARK: Lines

    private var linesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("#").frame(width: 20, alignment: .trailing)
                if type.canSpanTrialBalances { Text("Trial Balance").frame(width: 160, alignment: .leading) }
                Text("Account").frame(maxWidth: .infinity, alignment: .leading)
                Text("Debit").frame(width: 112, alignment: .trailing)
                Text("Credit").frame(width: 112, alignment: .trailing)
                Text("Memo").frame(width: 180, alignment: .leading)
                Spacer().frame(width: 22)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            ForEach(Array(lines.enumerated()), id: \.element.id) { index, draft in
                let line = binding(for: draft.id)
                HStack(spacing: 6) {
                    Text("\(index + 1)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 20, alignment: .trailing)
                    if type.canSpanTrialBalances {
                        Picker("", selection: line.entity) {
                            ForEach(engagement.entities) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                    AccountSearchField(accounts: engagement.sortedAccounts, accountID: line.accountID,
                                       takeFocus: focusLine == draft.id, focusTaken: { focusLine = nil })
                        .frame(maxWidth: .infinity)
                    amountField(line.debit, clears: line.credit)
                    amountField(line.credit, clears: line.debit)
                    TextField("", text: line.memo)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Button {
                        lines.removeAll { $0.id == draft.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 22)
                    .help("Remove this line")
                    .disabled(lines.count <= 2)
                }
            }

            HStack(spacing: 10) {
                Button {
                    addLine()
                } label: {
                    Label("Add Line", systemImage: "plus")
                }
                .keyboardShortcut("l")
                Button("New Account…") { model.showNewAccount() }
                    .help("Add an account to the chart of accounts")
                Spacer()
            }
            .padding(.top, 4)
        }
    }

    /// Looks the line up by id each time, so a row that is being removed never reaches a stale index.
    private func binding(for id: UUID) -> Binding<DraftLine> {
        Binding(get: { lines.first { $0.id == id } ?? DraftLine(entity: entityID) },
                set: { new in
                    if let i = lines.firstIndex(where: { $0.id == id }) { lines[i] = new }
                })
    }

    private func amountField(_ text: Binding<String>, clears other: Binding<String>) -> some View {
        TextField("", text: text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 112)
            .onChange(of: text.wrappedValue) { _, new in
                if !new.trimmingCharacters(in: .whitespaces).isEmpty { other.wrappedValue = "" }
            }
    }

    /// A new line starts with whatever amount would balance the entry.
    private func addLine() {
        let imbalance = built.entry.imbalance
        var line = DraftLine(entity: lines.last?.entity ?? entityID)
        if imbalance.cents > 0 { line.credit = imbalance.plain }
        if imbalance.cents < 0 { line.debit = (-imbalance).plain }
        lines.append(line)
        // Straight into the new line, ready for its account to be typed.
        focusLine = line.id
    }

    // MARK: References

    /// Every indexed file in the binder, in index order whatever folder it is in, in the shape
    /// the search field lists: the index where an account's number goes, the name after it.
    private var binderChoices: [Account] {
        (model.binder?.indexedFiles ?? []).map { item in
            var a = Account(number: item.index?.text ?? "", name: item.title, type: .asset)
            a.id = item.path
            return a
        }
    }

    private var referencesSection: some View {
        let choices = binderChoices
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("References").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if choices.isEmpty {
                    Text(model.binder == nil ? "This file isn't in a binder folder, so there are no workpapers to refer to."
                                             : "No indexed files in the binder yet. Index the workpapers on the Binder screen to refer to them here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    AccountSearchField(accounts: choices, accountID: .constant(nil),
                                       placeholder: "Add a reference — type an index or part of a file name (\(choices.count) indexed file\(choices.count == 1 ? "" : "s"))",
                                       detail: { a in
                                           let folder = ((a.id as NSString).deletingLastPathComponent as NSString).lastPathComponent
                                           return BinderPlaceholder.isPlaceholder((a.id as NSString).lastPathComponent) ? "placeholder · \(folder)" : folder
                                       },
                                       keepOrder: true,
                                       onChoose: { path in references.append(FileReference(path: path)) })
                        .frame(maxWidth: 560)
                }
                Spacer()
            }
            VStack(spacing: 0) {
                if references.isEmpty {
                    Text("Refer to the workpapers that support this entry. Pick them from the binder's indexed files above.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                } else {
                    ForEach(Array(references.enumerated()), id: \.offset) { index, ref in
                        if index > 0 { Divider() }
                        referenceRow(ref, index: index)
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
        }
    }

    private func referenceRow(_ value: FileReference, index: Int) -> some View {
        let found = model.exists(value)
        func field(_ path: WritableKeyPath<FileReference, String>) -> Binding<String> {
            Binding(get: { index < references.count ? references[index][keyPath: path] : "" },
                    set: { if index < references.count { references[index][keyPath: path] = $0 } })
        }
        let tabs = value.isWorkbook ? model.sheetNames(for: value) : nil
        let cellsOK = WorkbookTabs.cells(value.cells) != nil
        return HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: model.url(for: value).path))
                .resizable()
                .frame(width: 20, height: 20)
                .opacity(found ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 1) {
                Button(value.fileName) { model.openReference(value) }
                    .buttonStyle(.link)
                    .help(value.isWorkbook && !value.sheet.isEmpty
                          ? "Opens the workbook in Excel on “\(value.sheet)”\(value.cells.isEmpty ? "" : ", with \(value.cells) selected")"
                          : "Opens the file")
                Text(found ? value.path : "Not found — moved or renamed: \(value.path). Remove it and pick the file again.")
                    .font(.caption)
                    .foregroundStyle(found ? Color.secondary : Color.orange)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if value.isWorkbook {
                // A workbook reference always says which tab, even when the workbook has only one.
                if let tabs {
                    Picker("Tab", selection: field(\.sheet)) {
                        if value.sheet.isEmpty { Text("Choose the tab…").tag("") }
                        ForEach(tabs, id: \.self) { Text($0).tag($0) }
                        if !value.sheet.isEmpty && !tabs.contains(value.sheet) { Text("\(value.sheet) (not in the workbook)").tag(value.sheet) }
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.orange, lineWidth: value.sheet.isEmpty || !tabs.contains(value.sheet) ? 1.5 : 0))
                    .help("The tab of the workbook this entry refers to")
                } else {
                    TextField("Tab name", text: field(\.sheet))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 170)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.orange, lineWidth: value.sheet.trimmingCharacters(in: .whitespaces).isEmpty ? 1.5 : 0))
                        .help("The tabs of this workbook can't be read here (an .xls or .xlsb file, or one that can't be found), so type the tab's name")
                }
                TextField("Cells (optional)", text: field(\.cells))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 112)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.orange, lineWidth: cellsOK ? 0 : 1.5))
                    .help("The cells on that tab, like B4 or B4:D10. Clicking the file's name then opens Excel with them selected.")
            }
            TextField("Note (page, line…)", text: field(\.note))
                .textFieldStyle(.roundedBorder)
                .frame(width: value.isWorkbook ? 170 : 220)
            Button {
                model.reveal(model.url(for: value))
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .disabled(!found)
            Button {
                if index < references.count { references.remove(at: index) }
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove this reference (the file itself is not touched)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: Footer

    private func footer(_ result: (entry: JournalEntry, errors: [String])) -> some View {
        let entry = result.entry
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                if result.errors.isEmpty {
                    CheckBadge(ok: true, text: "In balance — ready to post")
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(result.errors.prefix(4).enumerated()), id: \.offset) { _, message in
                            Label(message, systemImage: "exclamationmark.circle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                        if result.errors.count > 4 {
                            Text("…and \(result.errors.count - 4) more").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                totals("Debits", entry.totalDebits)
                totals("Credits", entry.totalCredits)
                totals("Difference", entry.imbalance.cents >= 0 ? entry.imbalance : -entry.imbalance, warn: !entry.imbalance.isZero)
            }
            HStack {
                if !request.isNew {
                    Button("Delete Entry", role: .destructive) { confirmDelete = true }
                }
                Toggle("Show on the trial balance as I type", isOn: $livePreview)
                    .help("While this window is open, the trial balance and consolidation include this entry as typed, marked unposted. Nothing is saved until you post.")
                Spacer()
                Button("Cancel") { closeWindow() }
                    .keyboardShortcut(.cancelAction)
                if request.isNew {
                    Button("Post & New") {
                        if post(entry) { model.newEntry(type, entityID: type.canSpanTrialBalances ? nil : entityID) }
                    }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(!result.errors.isEmpty)
                    .help("Post this entry and start another of the same type (⇧⌘↩)")
                }
                Button(request.isNew || request.entry.pending ? "Post Entry" : "Save Changes") { post(entry) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!result.errors.isEmpty)
            }
        }
        .padding(14)
    }

    @discardableResult
    private func post(_ entry: JournalEntry) -> Bool {
        let name = request.isNew ? "Post \(entry.number)" : "Edit \(entry.number)"
        guard model.mutate(name, { try $0.post(entry) }) else { return false }
        model.status = request.isNew ? "Posted \(entry.number)" : "Saved \(entry.number)"
        closeGuard.isDirty = false
        model.closeEditor(request.entry.id)
        return true
    }

    private func totals(_ label: String, _ amount: Money, warn: Bool = false) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(amount.grouped)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(warn ? Color.orange : Color.primary)
        }
        .frame(minWidth: 96, alignment: .trailing)
    }
}

private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

// MARK: - Editing an account

/// Changes an account's number, its name, or both. Everything that refers to the account —
/// balances, prior years, journal lines, in every trial balance — follows a new number.
struct EditAccountSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var dismiss
    let accountID: String
    @State private var number = ""
    @State private var name = ""
    @State private var loaded = false

    var body: some View {
        let e = model.engagement ?? Engagement(name: "", periodEnd: "")
        let account = e.account(accountID)
        let newID = Account(number: number.trimmingCharacters(in: .whitespaces), name: name.trimmingCharacters(in: .whitespaces)).id
        let clash = newID != accountID ? e.account(newID) : nil
        let usedBy = e.entities.filter { ent in ent.balances.contains { $0.account == accountID } || ent.priorPeriods.contains { $0.balances.contains { $0.account == accountID } } }.map(\.name)
        let lines = e.journalEntries.reduce(0) { $0 + $1.lines.filter { $0.account == accountID }.count }
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Account").font(.headline)
            Form {
                TextField("Number", text: $number, prompt: Text("None — kept by name"))
                TextField("Name", text: $name)
                LabeledContent("Grouping") { Text(e.groupingLabel(account?.grouping).isEmpty ? "Not grouped" : e.groupingLabel(account?.grouping)).foregroundStyle(.secondary) }
            }
            if let clash {
                Label("\(newID) is already “\(clash.name)”. Two accounts can't share a number.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
            Text(newID != accountID && clash == nil
                 ? "Changing the number moves everything that refers to this account to the new number: its balances\(usedBy.isEmpty ? "" : " in \(usedBy.joined(separator: ", "))"), prior years, and \(lines) journal line\(lines == 1 ? "" : "s"). Nothing is lost, and ⌘Z changes it back."
                 : "The chart is shared, so the change shows in every trial balance. The grouping and the account type are not changed here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if model.changeAccount(accountID, number: number, name: name) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || clash != nil
                          || (number.trimmingCharacters(in: .whitespaces) == account?.number && name.trimmingCharacters(in: .whitespaces) == account?.name))
            }
        }
        .padding(20)
        .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            guard !loaded, let account else { return }
            loaded = true
            number = account.number
            name = account.name
        }
    }
}

// MARK: - New account

struct NewAccountSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var dismiss
    @State private var number = ""
    @State private var name = ""
    @State private var groupingID: String?

    var body: some View {
        let e = model.engagement ?? Engagement(name: "", periodEnd: "")
        VStack(alignment: .leading, spacing: 14) {
            Text("New Account").font(.headline)
            Form {
                TextField("Number", text: $number)
                TextField("Name", text: $name)
                Picker("Grouping", selection: $groupingID) {
                    Text("Not grouped yet").tag(String?.none)
                    ForEach(e.groupingSections, id: \.self) { section in
                        Section(section) {
                            ForEach(e.groupingOutline.filter { $0.grouping.section == section }, id: \.grouping.id) { item in
                                Text(item.depth == 0 ? item.grouping.display : "      ↳ \(item.grouping.name)").tag(String?.some(item.grouping.id))
                            }
                        }
                    }
                }
                // The type is never chosen here: it is the grouping's.
                LabeledContent("Account type") {
                    if let type = e.groupingType(groupingID) {
                        Text("\(type.label) — from its grouping")
                    } else {
                        Text("\(AccountType.infer(number: number.trimmingCharacters(in: .whitespaces), name: name).label) for now — set by the grouping once it has one")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text("The account joins the shared chart, so every trial balance can use it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Account") {
                    let grouping = groupingID
                    let ok = model.mutate("Add Account") { e in
                        let a = try e.addAccount(number: number, name: name, type: nil)
                        if let grouping { e.setGrouping(grouping, forAccounts: [a.id]) }
                    }
                    if ok { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
