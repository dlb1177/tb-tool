import AppKit
import SwiftUI
import TBCore

/// Client and binder details and the current year. The same form sets up a new file and edits an
/// open one. What is entered here heads every report export.
struct SettingsView: View {
    enum Mode { case setup, edit }

    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var closeWindow
    let mode: Mode

    @State private var name = ""
    @State private var binder = Binder()
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var month = 12
    @State private var day = 31
    @State private var listName = GroupingList.standardName
    @State private var library: [GroupingList] = []
    /// Once the list is chosen by hand, changing the entity type no longer changes it.
    @State private var listChosen = false
    @State private var loaded = false

    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    /// The year end as YYYY-MM-DD, pulling an impossible day (June 31) back to the month's last.
    private var periodEnd: String {
        var d = day
        while d > 28 {
            let s = String(format: "%04d-%02d-%02d", year, month, d)
            if Timestamp.isValidDay(s) { return s }
            d -= 1
        }
        return String(format: "%04d-%02d-%02d", year, month, d)
    }

    private var chosenList: GroupingList {
        library.first { $0.name == listName } ?? library.first ?? .standard
    }

    /// The standard list for an entity type, as set in the app's settings.
    private func standardList(for type: String) -> String {
        let wanted = type.trimmingCharacters(in: .whitespaces).lowercased()
        return (library.first { $0.entityTypes.contains { $0.lowercased() == wanted } } ?? library.first)?.name ?? GroupingList.standardName
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Client") {
                    TextField("Client name", text: $name, prompt: Text("As it should head the reports"))
                    TextField("Client number", text: $binder.clientNumber)
                    HStack {
                        TextField("Entity type", text: $binder.entityType)
                        Menu("") {
                            ForEach(Binder.entityTypes, id: \.self) { type in
                                Button(type) { binder.entityType = type }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    TextField("Tax ID (EIN)", text: $binder.taxID)
                }
                Section {
                    HStack {
                        TextField("Current year", value: $year, format: .number.grouping(.never))
                        Stepper("", value: $year, in: 1990...2200).labelsHidden()
                    }
                    HStack {
                        Picker("Year end", selection: $month) {
                            ForEach(1...12, id: \.self) { Text(Self.months[$0 - 1]).tag($0) }
                        }
                        Picker("", selection: $day) {
                            ForEach(1...31, id: \.self) { Text(String($0)).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 70)
                    }
                    Text(yearNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("Year")
                }
                Section("Binder") {
                    TextField("Engagement", text: $binder.engagement, prompt: Text("e.g. \(String(year)) Tax Return"))
                    TextField("Firm", text: $binder.firm)
                    TextField("Prepared by", text: $binder.preparedBy)
                    TextField("Reviewed by", text: $binder.reviewedBy)
                }
                if mode == .setup {
                    Section("Grouping list") {
                        Picker("Start with", selection: Binding(get: { listName }, set: {
                            listName = $0
                            listChosen = true
                        })) {
                            ForEach(library, id: \.name) { list in
                                Text("\(list.name) — \(list.groupings.filter { $0.parent == nil }.count) groupings").tag(list.name)
                            }
                        }
                        Text("This is the standard list for the entity type chosen above. Standard lists — one per entity type, updated when a form changes — are kept in TB Tool ▸ Settings. The file gets its own copy, which you can change or switch later.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let e = model.engagement {
                    Section("File") {
                        LabeledContent("Location") {
                            Text(model.fileURL.map(model.displayPath) ?? "")
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                        LabeledContent("Grouping list") {
                            Text(e.groupingListName.isEmpty ? GroupingList.standardName : e.groupingListName).foregroundStyle(.secondary)
                        }
                        if !e.rolledForwardFrom.isEmpty {
                            LabeledContent("Rolled forward from") { Text(e.rolledForwardFrom).foregroundStyle(.secondary) }
                        }
                    }
                }
                Section("How the reports will be headed") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(previewHeading.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(i == 0 ? .system(size: 15, weight: .bold) : (i == 1 ? .system(size: 12.5, weight: .semibold) : .system(size: 12)))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if mode == .edit {
                    Button("Roll Forward to Next Year…") {
                        closeWindow()
                        model.showRollForward()
                    }
                }
                Spacer()
                Button("Cancel") { closeWindow() }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .setup ? "Create…" : "Save") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(14)
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear(perform: load)
        .onChange(of: binder.entityType) { _, type in
            if mode == .setup && !listChosen { listName = standardList(for: type) }
        }
    }

    private var draft: Engagement {
        var e = Engagement(name: name.trimmingCharacters(in: .whitespaces), periodEnd: periodEnd, groupings: [])
        e.binder = binder
        return e
    }

    private var previewHeading: [String] { Reports(draft).heading("Consolidating Trial Balance — Book Basis") }

    private var yearNote: String {
        var text = "Prior-period columns count back from the current year: PP1 is \(String(year - 1)), PP2 is \(String(year - 2)), and so on."
        if mode == .edit, let e = model.engagement {
            let stored = Set(e.entities.flatMap { $0.priorPeriods.map(\.year) }).sorted(by: >)
            if !stored.isEmpty {
                let shown = stored.filter { $0 < year }.map { "PP\(year - $0) \($0)" }
                let hidden = stored.filter { $0 >= year }.map(String.init)
                text += shown.isEmpty ? " No stored year is before \(String(year))." : " In this file: \(shown.joined(separator: ", "))."
                if !hidden.isEmpty { text += " Balances stored for \(hidden.joined(separator: ", ")) are kept but not shown, because that isn't a prior year." }
            }
            if e.periodEnd != periodEnd { text += " Changing the year doesn't move any balances; to start the next year, use Roll Forward." }
        }
        return text
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        library = GroupingLibrary.all()
        listName = standardList(for: binder.entityType)
        if mode == .edit, let e = model.engagement {
            name = e.name
            binder = e.binder
            if Timestamp.isValidDay(e.periodEnd) {
                let parts = e.periodEnd.split(separator: "-").compactMap { Int($0) }
                year = parts[0]
                month = parts[1]
                day = parts[2]
            }
        } else {
            // Whoever set up the last file is probably setting up this one.
            binder.firm = UserDefaults.standard.string(forKey: "default.firm") ?? ""
            binder.preparedBy = UserDefaults.standard.string(forKey: "default.preparedBy") ?? ""
        }
    }

    private func commit() {
        UserDefaults.standard.set(binder.firm, forKey: "default.firm")
        UserDefaults.standard.set(binder.preparedBy, forKey: "default.preparedBy")
        let clean = name.trimmingCharacters(in: .whitespaces)
        switch mode {
        case .edit:
            let ok = model.mutate("Edit Settings") { e in
                e.name = clean
                e.binder = binder
                e.periodEnd = periodEnd
            }
            if ok { closeWindow() }
        case .setup:
            var e = Engagement(name: clean, periodEnd: periodEnd, groupings: chosenList.groupings)
            e.binder = binder
            e.groupingListName = chosenList.name
            if e.binder.engagement.trimmingCharacters(in: .whitespaces).isEmpty { e.binder.engagement = "" }
            if model.createFile(e) { Windows.shared.close("setup") }
        }
    }
}

// MARK: - Roll forward

struct RollForwardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var closeWindow
    @State private var carry = false
    @State private var closeInto: String?
    @State private var keepLinks = false
    @State private var keepYears = 5
    /// Roll the binder's folders and files into next year's folder along with the trial balance.
    @State private var rollBinder = true
    @State private var choices: [String: BinderRollChoice] = [:]
    @State private var destination: URL?
    @State private var tab = "binder"
    @State private var loaded = false

    var body: some View {
        if let e = model.engagement, let summary = try? e.rollForwardSummary() {
            let tree = model.binder.flatMap { $0.isEmpty || $0.truncated ? nil : $0 }
            let withBinder = rollBinder && tree != nil
            let target = destination ?? model.folder.map { BinderRoller.defaultDestination(for: $0, fromYear: summary.fromYear, toYear: summary.toYear) }
            let fileName = Engagement.rolledFileName(model.fileURL?.lastPathComponent ?? "Trial Balance.json", from: summary.fromYear, to: summary.toYear)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Roll forward \(String(summary.fromYear)) → \(String(summary.toYear))").font(.title3.bold())
                    Text("Creates \(tree == nil ? "a new file" : "next year's binder") for the year ended \(Timestamp.longDay(summary.newPeriodEnd) ?? summary.newPeriodEnd). \(model.fileURL?.lastPathComponent ?? "This file")\(tree == nil ? " is" : " and everything in this year's folder are") left exactly as \(tree == nil ? "it is" : "they are").")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Label("\(String(summary.fromYear)) final balances — book, tax, and eliminations — become PP1 in the new file\(e.priorYears.isEmpty ? "." : "; \(e.priorYears.map { e.priorLabel($0) }.joined(separator: ", ")) \(e.priorYears.count == 1 ? "moves" : "each move") back one.")", systemImage: "clock.arrow.circlepath")
                    Label("The chart of accounts, groupings, grouping list and binder details carry over.", systemImage: "list.bullet.rectangle")
                    HStack(spacing: 8) {
                        Image(systemName: "tablecells").frame(width: 18)
                        Text("\(String(summary.toYear)) balances start")
                        Picker("", selection: $carry) {
                            Text("empty — import the \(String(summary.toYear)) trial balances").tag(false)
                            Text("with the balance sheet carried forward").tag(true)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if carry {
                        HStack(spacing: 8) {
                            Spacer().frame(width: 18)
                            Text("Close income and expenses into")
                            AccountSearchField(accounts: e.sortedAccounts.filter { !$0.type.isIncomeStatement }, accountID: $closeInto,
                                               placeholder: "Equity account")
                                .frame(width: 320)
                        }
                        Text("Each trial balance opens with its balance sheet accounts at their \(String(summary.fromYear)) final book balance. Income and expense accounts start at zero and their net goes to this account.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 26)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 18) {
                        Stepper("Keep \(keepYears) prior year\(keepYears == 1 ? "" : "s")", value: $keepYears, in: 1...15).fixedSize()
                        Toggle("Carry workpaper links on entries that roll forward", isOn: $keepLinks)
                            .help("Off: rolled entries start with no linked files, since the links point at \(String(summary.fromYear)) workpapers")
                    }
                    .padding(.leading, 26)
                    if tree != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "folder").frame(width: 18)
                            Toggle("Roll the binder forward too, into", isOn: $rollBinder).fixedSize()
                            Text(target.map { model.displayPath($0) } ?? "")
                                .foregroundStyle(rollBinder ? Color.primary : Color.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .help(target?.path ?? "")
                            Button("Choose…") { chooseDestination(summary) }
                                .disabled(!rollBinder)
                            Spacer(minLength: 0)
                        }
                        if rollBinder, let target, FileManager.default.fileExists(atPath: target.appendingPathComponent(fileName).path) {
                            Label("\(fileName) is already in that folder, and roll forward won't replace it. Choose another folder, or move that file first.", systemImage: "exclamationmark.triangle.fill")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .padding(.leading, 26)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if rollBinder, let target, FileManager.default.fileExists(atPath: target.path) {
                            Text("That folder is already there. Nothing in it will be overwritten: items it already has are left as they are.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 26)
                        }
                    }
                }
                .font(.system(size: 12.5))
                .padding(16)
                Divider()
                HStack(spacing: 12) {
                    Picker("", selection: $tab) {
                        if tree != nil { Text("Binder").tag("binder") }
                        Text("Journal Entries (\(e.journalEntries.count))").tag("entries")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    if tab == "entries" || tree == nil {
                        Text(summary.entryCounts).foregroundStyle(.secondary)
                        Spacer()
                        Menu("Set All") {
                            ForEach(RollForward.allCases, id: \.self) { value in
                                Button(value.label) { model.setRollForward(value, for: Set(e.journalEntries.map(\.id))) }
                            }
                        }
                        .fixedSize()
                    } else if let tree {
                        Text(binderCounts(tree)).foregroundStyle(.secondary)
                        Spacer()
                        Menu("Set Every File") {
                            Button("Roll Forward") { setAll(tree, .copy) }
                            Button("Placeholder Only") { setAll(tree, .placeholder) }
                            Button("Don't Roll Forward") { setAll(tree, .skip) }
                        }
                        .fixedSize()
                        .disabled(!rollBinder)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                if tab == "entries" || tree == nil {
                    Table(Reports(e).sortedEntries()) {
                        TableColumn("Entry") { je in Text(je.number).fontWeight(.medium) }
                            .width(min: 60, ideal: 70, max: 100)
                        TableColumn("Type") { je in Text(je.type.label) }
                            .width(min: 80, ideal: 100, max: 120)
                        TableColumn("Description") { je in Text(je.description) }
                            .width(min: 140, ideal: 240)
                        TableColumn("Amount") { je in
                            Text(je.pending ? "—" : je.totalDebits.grouped).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .width(min: 90, ideal: 110, max: 150)
                        TableColumn("Next year") { je in
                            Picker("", selection: Binding(get: { je.rollForward }, set: { model.setRollForward($0, for: [je.id]) })) {
                                ForEach(RollForward.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 228)
                        }
                        .width(min: 240, ideal: 244, max: 260)
                    }
                } else if let tree {
                    binderList(tree)
                        .disabled(!rollBinder)
                        .opacity(rollBinder ? 1 : 0.5)
                }
                Divider()
                HStack {
                    Text(tab == "binder" && tree != nil
                         ? "Roll forward copies a file into next year's binder with its index and without its Finder tags. Placeholder leaves an empty text file under the same name, noting where this year's file is."
                         : "Without amounts: the entry waits in the new file marked “needs amounts” and posts nothing until you fill it in. As reversal: debits and credits are swapped, dated \(Timestamp.day(e.periodEnd, addingDays: 1) ?? "the first day of the new year"), and each line's memo starts “[Reversal from \(String(summary.fromYear))]”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Cancel") { closeWindow() }
                        .keyboardShortcut(.cancelAction)
                    Button(withBinder ? "Roll Forward" : "Roll Forward…") {
                        var o = RollForwardOptions()
                        if carry, let closeInto { o.opening = .carryBalanceSheet(closeInto: closeInto) }
                        o.keepLinks = keepLinks
                        o.keepPriorYears = keepYears
                        if withBinder, let target {
                            model.rollForward(o, to: target.appendingPathComponent(fileName), binderChoices: choices)
                        } else {
                            model.rollForward(o)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled((carry && closeInto == nil)
                              || (withBinder && (target.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent(fileName).path) } ?? false)))
                }
                .padding(14)
            }
            .frame(minWidth: 760, minHeight: 520)
            .onAppear {
                if closeInto == nil {
                    let equity = e.sortedAccounts.filter { $0.type == .equity }
                    closeInto = (equity.first { $0.name.lowercased().contains("retained") } ?? equity.first)?.id
                }
                guard !loaded else { return }
                loaded = true
                model.refreshBinder()
                if let tree = model.binder, !tree.isEmpty, !tree.truncated {
                    choices = BinderRoller.defaultChoices(tree)
                    // For documentation pictures: show one of each choice.
                    if CommandLine.arguments.contains("--tb-snapshot") {
                        for f in tree.files where f.parentPath.contains("Support") { choices[f.path] = .placeholder }
                        if let loose = tree.unfiled.first { choices[loose.path] = .skip }
                    }
                } else {
                    tab = "entries"
                }
            }
        } else {
            VStack(spacing: 12) {
                EmptyState(title: "Set the year end first", message: "Rolling forward needs to know the current year. Set it in Trial Balance Settings.",
                           button: "Open Settings…") {
                    closeWindow()
                    model.showSettings()
                }
            }
            .frame(minWidth: 760, minHeight: 520)
        }
    }

    // MARK: The binder, opened out

    private func binderCounts(_ tree: BinderTree) -> String {
        var copy = 0, placeholder = 0, skip = 0
        for f in tree.files {
            switch BinderRoller.effective(f.path, choices) {
            case .copy: copy += 1
            case .placeholder: placeholder += 1
            case .skip: skip += 1
            }
        }
        let folders = tree.folders.filter { BinderRoller.effective($0.path, choices) != .skip }.count
        return "\(folders) folder\(folders == 1 ? "" : "s") · \(copy) file\(copy == 1 ? "" : "s") roll forward · \(placeholder) placeholder\(placeholder == 1 ? "" : "s") · \(skip) left behind"
    }

    private func setAll(_ tree: BinderTree, _ choice: BinderRollChoice) {
        for f in tree.files { choices[f.path] = choice }
    }

    /// Sets a folder and everything under it.
    private func set(_ folder: BinderItem, contents choice: BinderRollChoice) {
        choices[folder.path] = .copy
        func walk(_ item: BinderItem) {
            for child in item.children {
                choices[child.path] = child.isFolder ? .copy : choice
                walk(child)
            }
        }
        walk(folder)
    }

    private func binderList(_ tree: BinderTree) -> some View {
        List(tree.all) { item in
            let own = choices[item.path] ?? .copy
            let effective = BinderRoller.effective(item.path, choices)
            // An item inside a folder that isn't being brought has nothing to decide.
            let blocked = effective == .skip && own != .skip
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { own != .skip }, set: { on in
                    choices[item.path] = on ? (item.isPlaceholder ? .placeholder : .copy) : .skip
                }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(blocked)
                .padding(.leading, CGFloat(item.depth) * 18)
                Image(systemName: item.isFolder ? "folder.fill" : (item.isPlaceholder ? "doc.badge.ellipsis" : "doc"))
                    .foregroundStyle(item.isFolder ? Color.accentColor : Color.secondary)
                    .frame(width: 18)
                Text(item.name)
                    .fontWeight(item.isFolder ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.tags.isEmpty {
                    Text(item.tags.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help("Finder tags on this year's file. They are not carried to next year.")
                }
                Spacer(minLength: 8)
                if item.isFolder {
                    Menu("Everything Inside") {
                        Button("Roll Forward") { set(item, contents: .copy) }
                        Button("Placeholder Only") { set(item, contents: .placeholder) }
                        Button("Don't Roll Forward") { set(item, contents: .skip) }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(effective == .skip)
                } else {
                    Picker("", selection: Binding(get: { own }, set: { choices[item.path] = $0 })) {
                        Text("Roll forward").tag(BinderRollChoice.copy)
                        Text("Placeholder only").tag(BinderRollChoice.placeholder)
                        Text("Don't roll forward").tag(BinderRollChoice.skip)
                    }
                    .labelsHidden()
                    .frame(width: 170)
                    .disabled(blocked)
                }
            }
            .font(.system(size: 12.5))
            .opacity(effective == .skip ? 0.45 : 1)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func chooseDestination(_ summary: RollForwardSummary) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = model.folder?.deletingLastPathComponent()
        panel.message = "Choose the folder for the \(summary.toYear) binder (or make a new one)"
        panel.prompt = "Use This Folder"
        if panel.runModal() == .OK, let url = panel.url {
            if url.standardizedFileURL == model.folder?.standardizedFileURL {
                model.alert = AlertInfo(title: "That is this year's binder", message: "Choose a different folder for \(summary.toYear).")
            } else {
                destination = url
            }
        }
    }
}

// MARK: - Grouping list import

struct GroupingImportView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var closeWindow
    let request: GroupingImportRequest
    @State private var mode = GroupingImportMode.replace
    @State private var name = ""

    var body: some View {
        let e = model.engagement ?? Engagement(name: "", periodEnd: "")
        let plan = e.planGroupingImport(request.list, mode: mode)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Grouping List").font(.title3.bold())
                Text("\(request.sourceName) · \(request.list.groupings.count) groupings in \(Set(request.list.groupings.map(\.section)).count) sections")
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $mode) {
                        Text("Replace this file's list").tag(GroupingImportMode.replace)
                        Text("Add to this file's list").tag(GroupingImportMode.merge)
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    Text(mode == .replace
                         ? "The grouping list becomes the imported one. Accounts keep their grouping where it is in both lists."
                         : "Groupings this file doesn't have are added. Ones it has (same id) take the imported code, name and section.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 300, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Text("List name")
                        TextField("", text: $name).textFieldStyle(.roundedBorder).frame(width: 220)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    stat("\(plan.result.count) groupings after the import (now \(e.groupings.count))")
                    if !plan.added.isEmpty { stat("\(plan.added.count) added") }
                    if !plan.updated.isEmpty { stat("\(plan.updated.count) renamed or moved to another section") }
                    if !plan.removed.isEmpty { stat("\(plan.removed.count) removed", warn: !plan.ungrouped.isEmpty) }
                    if !plan.remapped.isEmpty { stat("\(plan.remapped.count) accounts keep their grouping under its new id") }
                    if !plan.ungrouped.isEmpty {
                        stat("\(plan.ungrouped.count) account\(plan.ungrouped.count == 1 ? "" : "s") will become ungrouped: \(plan.ungrouped.prefix(3).map(\.display).joined(separator: ", "))\(plan.ungrouped.count > 3 ? "…" : "")", warn: true)
                    }
                    if plan.isEmpty { stat("This file already has this list — nothing to change") }
                }
                Spacer()
            }
            .padding(16)
            Divider()
            Table(plan.result) {
                TableColumn("Section") { g in Text(g.section).foregroundStyle(.secondary) }
                    .width(min: 120, ideal: 170, max: 240)
                TableColumn("Code") { g in Text(g.code).fontWeight(.medium).monospacedDigit() }
                    .width(min: 60, ideal: 80, max: 120)
                TableColumn("Name") { g in Text(g.name) }
                    .width(min: 200, ideal: 340)
                TableColumn("") { g in
                    if plan.added.contains(where: { $0.id == g.id }) {
                        Text("new").foregroundStyle(.green)
                    } else if plan.updated.contains(where: { $0.id == g.id }) {
                        Text("changed").foregroundStyle(.orange)
                    }
                }
                .width(min: 60, ideal: 70, max: 90)
            }
            Divider()
            HStack {
                Text("You can undo the import.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { closeWindow() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    if model.mutate("Import Grouping List", { $0.applyGroupingImport(plan, name: name) }) {
                        model.status = "Grouping list imported: \(plan.result.count) groupings"
                        closeWindow()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.isEmpty && name.trimmingCharacters(in: .whitespaces) == e.groupingListName)
            }
            .padding(14)
        }
        .frame(minWidth: 720, minHeight: 420)
        .onAppear { name = request.list.name }
    }

    private func stat(_ text: String, warn: Bool = false) -> some View {
        Label(text, systemImage: warn ? "exclamationmark.triangle" : "checkmark.circle")
            .foregroundStyle(warn ? Color.orange : Color.primary)
            .font(.callout)
    }
}
