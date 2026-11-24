import SwiftUI
import TBCore

// MARK: - Chart of accounts

struct AccountRow: Identifiable, Hashable {
    let id: String
    let number: String
    let name: String
    let type: AccountType
    let typeLabel: String
    let groupingID: String?
    let grouping: String
    let section: String
    let balance: Int64
    let usedBy: String

    var cells: [String: ReportCell] {
        ["Account": .text(number), "Name": .text(name), "Type": .text(typeLabel), "Grouping": .text(grouping),
         "Section": .text(section), "Balance (book)": .money(Money(cents: balance)), "Used By": .text(usedBy)]
    }

    static let filterColumns = [
        FilterColumn(title: "Account", isAmount: false), FilterColumn(title: "Name", isAmount: false),
        FilterColumn(title: "Type", isAmount: false, choices: AccountType.allCases.map(\.label)),
        FilterColumn(title: "Grouping", isAmount: false), FilterColumn(title: "Section", isAmount: false),
        FilterColumn(title: "Balance (book)", isAmount: true), FilterColumn(title: "Used By", isAmount: false),
    ]
}

struct AccountsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection = Set<String>()
    @State private var search = ""
    @State private var status = "all"       // all / ungrouped / grouped
    @State private var typeFilter = "all"
    @State private var entityFilter = "all"
    @State private var sectionFilter = "all"
    @State private var rangeFrom = ""
    @State private var rangeTo = ""
    @State private var rules = FilterSet()
    @State private var sortOrder = [KeyPathComparator(\AccountRow.number, comparator: .localizedStandard)]
    @State private var showPicker = false
    @State private var confirmDelete = false
    /// Column order and hidden columns, remembered between visits.
    @AppStorage("accounts.columns") private var columnLayout = TableColumnCustomization<AccountRow>()

    var body: some View {
        // The balance column follows an entry being typed, like the trial balance screens.
        if let ledger = model.liveLedger ?? model.ledger {
            let e = ledger.engagement
            let all = rows(ledger)
            let shown = filtered(all).sorted(using: sortOrder)
            let shownIDs = Set(shown.map(\.id))
            let picked = selection.intersection(shownIDs)
            VStack(spacing: 0) {
                PageHeader(title: "Accounts", subtitle: subtitle(e)) {
                    Menu {
                        Button("New Account…") { model.showNewAccount() }
                        Divider()
                        Button("Import Chart of Accounts…") { model.importChartPanel() }
                        Button("Export Chart of Accounts (JSON)…") { model.exportChartPanel(csv: false) }
                        Button("Export Chart of Accounts (CSV)…") { model.exportChartPanel(csv: true) }
                    } label: {
                        Label("Chart", systemImage: "arrow.up.arrow.down.square")
                    }
                    .fixedSize()
                    .help("Reuse groupings between trial balance files that share a chart of accounts")
                }
                Divider()
                DraftBanner()
                if status != "ungrouped" { UngroupedBanner(show: showUngrouped) }
                filterBar(e)
                Divider()
                bulkBar(e, picked: picked, shown: shown)
                Divider()
                if e.accounts.isEmpty {
                    EmptyState(title: "No accounts yet", message: "The chart of accounts fills in as you import trial balances. It is shared by all of them.")
                } else {
                    table(e, shown)
                }
            }
            .onAppear { if model.showUngroupedRequested { showUngrouped() } }
            .onChange(of: model.showUngroupedRequested) { _, asked in if asked { showUngrouped() } }
            .confirmationDialog("Delete \(picked.count) account\(picked.count == 1 ? "" : "s")?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    if model.mutate("Delete Accounts", { e in try picked.forEach { try e.deleteAccount($0) } }) { selection = [] }
                }
            } message: {
                Text("Only accounts with no balances and no journal lines can be deleted.")
            }
        }
    }

    /// Narrows the list to the accounts with no grouping, clearing whatever else was filtering it.
    private func showUngrouped() {
        search = ""; typeFilter = "all"; sectionFilter = "all"; entityFilter = "all"; rangeFrom = ""; rangeTo = ""
        rules = FilterSet()
        status = "ungrouped"
        selection = []
        model.showUngroupedRequested = false
    }

    // MARK: Rows

    private func rows(_ ledger: Ledger) -> [AccountRow] {
        let e = ledger.engagement
        let users: [String: [String]] = Dictionary(grouping: e.entities.flatMap { ent in
            ledger.activeAccounts(in: ent.id).map { ($0, ent.name) }
        }, by: \.0).mapValues { $0.map(\.1) }
        return e.sortedAccounts.map { a in
            let g = e.grouping(a.grouping)
            return AccountRow(id: a.id, number: a.number, name: a.name, type: a.type, typeLabel: a.type.label,
                              groupingID: g?.id, grouping: e.groupingLabel(g?.id), section: g?.section ?? "",
                              balance: ledger.consolidated(.book, account: a.id).cents,
                              usedBy: (users[a.id] ?? []).joined(separator: ", "))
        }
    }

    private func filtered(_ all: [AccountRow]) -> [AccountRow] {
        let terms = search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let from = rangeFrom.trimmingCharacters(in: .whitespaces), to = rangeTo.trimmingCharacters(in: .whitespaces)
        let entityName = model.engagement?.entity(entityFilter)?.name
        return all.filter { r in
            if status == "ungrouped" && r.groupingID != nil { return false }
            if status == "grouped" && r.groupingID == nil { return false }
            if typeFilter != "all" && r.type.rawValue != typeFilter { return false }
            if sectionFilter != "all" && r.section != sectionFilter { return false }
            if let entityName, !r.usedBy.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(entityName) { return false }
            if !from.isEmpty || !to.isEmpty {
                guard !r.number.isEmpty else { return false }
                if !from.isEmpty && r.number.compare(from, options: .numeric) == .orderedAscending { return false }
                if !to.isEmpty && r.number.compare(to, options: .numeric) == .orderedDescending && !r.number.hasPrefix(to) { return false }
            }
            if !terms.isEmpty {
                let hay = "\(r.number) \(r.name) \(r.grouping) \(r.typeLabel) \(r.usedBy)".lowercased()
                guard terms.allSatisfy({ hay.contains($0) }) else { return false }
            }
            guard rules.isActive else { return true }
            let cells = r.cells
            return rules.matches(cell: { cells[$0] }, all: Array(cells.values))
        }
    }

    private func subtitle(_ e: Engagement) -> String {
        let ungrouped = e.accounts.filter { $0.grouping == nil }.count
        let unnumbered = e.accounts.filter { $0.number.isEmpty }.count
        var s = "\(e.accounts.count) accounts shared by every trial balance · \(ungrouped == 0 ? "all grouped" : "\(ungrouped) not grouped")"
        if unnumbered > 0 { s += " · \(unnumbered) without a number (kept by name)" }
        return s
    }

    // MARK: Filters

    private func filterBar(_ e: Engagement) -> some View {
        HStack(spacing: 10) {
            SearchBox(prompt: "Search number, name, grouping…", text: $search)
                .frame(minWidth: 140, idealWidth: 220, maxWidth: 240)
            Picker("", selection: $status) {
                Text("All").tag("all")
                Text("Ungrouped").tag("ungrouped")
                Text("Grouped").tag("grouped")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("Type", selection: $typeFilter) {
                Text("Any type").tag("all")
                ForEach(AccountType.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Section", selection: $sectionFilter) {
                Text("Any section").tag("all")
                ForEach(e.groupingSections, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Trial balance", selection: $entityFilter) {
                Text("Any trial balance").tag("all")
                ForEach(e.entities) { Text($0.name).tag($0.id) }
            }
            .labelsHidden()
            .fixedSize()
            HStack(spacing: 4) {
                Text("Accounts").foregroundStyle(.secondary).fixedSize()
                TextField("from", text: $rangeFrom).textFieldStyle(.roundedBorder).frame(width: 64)
                Text("–").foregroundStyle(.secondary)
                TextField("to", text: $rangeTo).textFieldStyle(.roundedBorder).frame(width: 64)
            }
            .help("Number range, e.g. 51000 to 51999. A short “to” like 5 includes everything starting with 5.")
            FilterButton(filter: $rules, columns: AccountRow.filterColumns, storageKey: "accounts")
            if isFiltering {
                Button("Clear Filters") {
                    search = ""; status = "all"; typeFilter = "all"; sectionFilter = "all"; entityFilter = "all"; rangeFrom = ""; rangeTo = ""
                    rules = FilterSet()
                }
                .buttonStyle(.borderless)
            }
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var isFiltering: Bool {
        !search.isEmpty || status != "all" || typeFilter != "all" || sectionFilter != "all" || entityFilter != "all" || !rangeFrom.isEmpty || !rangeTo.isEmpty
            || rules.isActive
    }

    // MARK: Bulk actions

    private func bulkBar(_ e: Engagement, picked: Set<String>, shown: [AccountRow]) -> some View {
        HStack(spacing: 10) {
            Text(picked.isEmpty ? "\(shown.count) shown · select rows (⇧-click, ⌘-click, ⌘A) to change many at once"
                                : "\(picked.count) selected")
                .foregroundStyle(picked.isEmpty ? .secondary : .primary)
                .fontWeight(picked.isEmpty ? .regular : .semibold)
            Button("Select All \(shown.count) Shown") { selection = Set(shown.map(\.id)) }
                .disabled(shown.isEmpty)
            if !picked.isEmpty {
                Button("Deselect") { selection = [] }
            }
            Divider().frame(height: 18)
            Button {
                showPicker = true
            } label: {
                Label("Apply Grouping…", systemImage: "rectangle.3.group")
            }
            .keyboardShortcut("g")
            .disabled(picked.isEmpty)
            .help("Pick a grouping for every selected account (⌘G). Type a code or name to find it.")
            .popover(isPresented: $showPicker, arrowEdge: .bottom) {
                GroupingPicker(engagement: e, count: picked.count) { id in
                    let ids = picked
                    var retyped = 0
                    model.mutate("Set Grouping") { retyped = $0.setGrouping(id, forAccounts: ids) }
                    model.status = id == nil ? "Cleared the grouping of \(ids.count) accounts"
                        : "Grouped \(ids.count) account\(ids.count == 1 ? "" : "s") as \(e.groupingLabel(id))"
                          + (retyped > 0 ? " — \(retyped) became \(e.groupingType(id)?.label.lowercased() ?? "") account\(retyped == 1 ? "" : "s") to match" : "")
                    showPicker = false
                }
            }
            Button("Edit…") { if let id = selection.first { model.showEditAccount(id) } }
                .disabled(selection.count != 1)
                .help("Change the selected account's number or name. Or double-click it.")
            Button("Clear Grouping") {
                let ids = picked
                model.mutate("Clear Grouping") { $0.setGrouping(nil, forAccounts: ids) }
            }
            .disabled(picked.isEmpty)
            Button("Delete…", role: .destructive) { confirmDelete = true }
                .disabled(picked.isEmpty)
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Table

    private func table(_ e: Engagement, _ shown: [AccountRow]) -> some View {
        Table(shown, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columnLayout) {
            TableColumn("Account", value: \.number, comparator: .localizedStandard) { r in
                Text(r.number.isEmpty ? "—" : r.number).monospacedDigit().foregroundStyle(r.number.isEmpty ? .tertiary : .primary)
            }
            .width(min: 36, ideal: 80)
            .customizationID("account")
            TableColumn("Name", value: \.name, comparator: .localizedStandard) { r in Text(r.name) }
                .width(min: 36, ideal: 300)
                .customizationID("name")
            TableColumn("Type", value: \.typeLabel) { r in
                // Read only: the type is the grouping's. Until an account is grouped it shows the
                // guess made from its number or name when it was imported.
                let fromGrouping = e.groupingType(r.groupingID) != nil
                Text(r.typeLabel)
                    .foregroundStyle(fromGrouping ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.tertiary)
                    .help(fromGrouping ? "From its grouping, \(r.grouping). To change it, change the account's grouping, or the grouping's account type on the Grouping List screen."
                                       : "A guess from the account's number or name. It is set for good by the grouping you give the account.")
            }
            .width(min: 36, ideal: 100)
            .customizationID("type")
            TableColumn("Grouping", value: \.grouping, comparator: .localizedStandard) { r in
                Menu {
                    groupingMenu(e) { id in
                        // Acting on a selected row applies to the whole selection.
                        let ids = selection.contains(r.id) ? selection : [r.id]
                        var retyped = 0
                        model.mutate("Set Grouping") { retyped = $0.setGrouping(id, forAccounts: ids) }
                        if retyped > 0 {
                            model.status = "\(retyped) account\(retyped == 1 ? "" : "s") became \(e.groupingType(id)?.label.lowercased() ?? "") to match \(e.groupingLabel(id))"
                        }
                    }
                } label: {
                    if r.grouping.isEmpty {
                        Text("Not grouped").foregroundStyle(.orange)
                    } else {
                        Text(r.grouping)
                    }
                }
                .menuStyle(.borderlessButton)
            }
            .width(min: 36, ideal: 280)
            .customizationID("grouping")
            TableColumn("Balance (book)", value: \.balance) { r in
                Text(Money(cents: r.balance).isZero ? "–" : Money(cents: r.balance).formatted)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 36, ideal: 120)
            .customizationID("balance-(book)")
            TableColumn("Used By", value: \.usedBy) { r in Text(r.usedBy).foregroundStyle(.secondary) }
                .width(min: 36, ideal: 240)
                .customizationID("used-by")
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first {
                Button("Edit Number and Name…") { model.showEditAccount(id) }
                Button("Show Activity") { model.showActivity(accountID: id, entityID: nil) }
            }
        } primaryAction: { ids in
            // Double-click an account to change its number or name.
            if ids.count == 1, let id = ids.first { model.showEditAccount(id) }
        }
        .background(TableColumnFitter(key: "accounts", contents: [
            "Account": shown.map(\.number), "Name": shown.map(\.name), "Type": shown.map(\.typeLabel),
            "Grouping": shown.map { $0.grouping.isEmpty ? "Not grouped" : $0.grouping },
            "Balance (book)": shown.map { Money(cents: $0.balance).formatted }, "Used By": shown.map(\.usedBy),
        ], extra: ["Grouping": 26]))
    }

    @ViewBuilder
    private func groupingMenu(_ e: Engagement, pick: @escaping (String?) -> Void) -> some View {
        ForEach(e.groupingSections, id: \.self) { section in
            Menu(section) {
                // Subgroups sit indented under their grouping.
                ForEach(e.groupingOutline.filter { $0.grouping.section == section }, id: \.grouping.id) { item in
                    Button(item.depth == 0 ? item.grouping.display : "      ↳ \(item.grouping.name)") { pick(item.grouping.id) }
                }
            }
        }
        Divider()
        Button("Not Grouped") { pick(nil) }
    }
}

/// Type to find a grouping or subgroup by code, name or section; Return applies the first match.
struct GroupingPicker: View {
    let engagement: Engagement
    let count: Int
    let pick: (String?) -> Void
    @State private var query = ""
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let grouping: Grouping
        let depth: Int
        let code: String
        let parentName: String
        var id: String { grouping.id }
    }

    private var matches: [Item] {
        let e = engagement
        let all = e.groupingOutline.map { item in
            Item(grouping: item.grouping, depth: item.depth, code: e.groupingCode(item.grouping.id),
                 parentName: e.parentGrouping(of: item.grouping)?.name ?? "")
        }
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return all }
        let found = all.filter { item in
            let g = item.grouping
            let hay = "\(item.code) \(g.id) \(g.name) \(item.parentName) \(g.section)".lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
        // An exact code match first ("L01" before "L01X"), and a grouping before its subgroups.
        let q = query.lowercased()
        return found.enumerated().sorted { a, b in
            let ea = a.element.code.lowercased() == q && a.element.depth == 0, eb = b.element.code.lowercased() == q && b.element.depth == 0
            return ea != eb ? ea : a.offset < b.offset
        }.map(\.element)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Group \(count) account\(count == 1 ? "" : "s") as…").font(.headline)
            TextField("Code or name — e.g. L01, cash, 815 mgmt", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if let item = matches.first { pick(item.id) } }
            List(matches) { item in
                Button {
                    pick(item.id)
                } label: {
                    HStack {
                        Text(item.depth == 0 ? item.code : "").monospacedDigit().fontWeight(.semibold).frame(width: 52, alignment: .leading)
                        if item.depth > 0 { Text("↳").foregroundStyle(.secondary) }
                        Text(item.grouping.name)
                        Spacer()
                        Text(item.depth == 0 ? item.grouping.section : "in \(item.parentName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .frame(height: 300)
            HStack {
                Button("Not Grouped") { pick(nil) }
                Spacer()
                Text("Return picks the first match").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 440)
        .onAppear { focused = true }
    }
}

// MARK: - Grouping list

private struct GroupingListRow: Identifiable {
    let grouping: Grouping
    let depth: Int
    var id: String { grouping.id }
}

struct GroupingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: String?
    @State private var library: [GroupingList] = []

    var body: some View {
        if let e = model.engagement {
            let own = Dictionary(grouping: e.accounts.compactMap(\.grouping), by: { $0 }).mapValues(\.count)
            let rows = e.groupingOutline.map { GroupingListRow(grouping: $0.grouping, depth: $0.depth) }
            let subgroupCount = rows.filter { $0.depth > 0 }.count
            VStack(spacing: 0) {
                PageHeader(title: "Grouping List", subtitle: "\(e.groupingListName.isEmpty ? GroupingList.standardName : e.groupingListName) · \(e.groupings.count - subgroupCount) groupings\(subgroupCount == 0 ? "" : ", \(subgroupCount) subgroup\(subgroupCount == 1 ? "" : "s")") · stored in this file, so each client can have its own") {
                    Menu {
                        Button("Import Grouping List…") { model.importGroupingListPanel() }
                        Button("Export Grouping List (JSON)…") { model.exportGroupingListPanel(csv: false) }
                        Button("Export Grouping List (CSV)…") { model.exportGroupingListPanel(csv: true) }
                        Divider()
                        Menu("Switch to a Standard List") {
                            ForEach(library, id: \.name) { list in
                                Button(list.name) { model.showGroupingImport(GroupingImportRequest(sourceName: "Standard lists", list: list)) }
                            }
                        }
                        Button("Save as a Standard List…") {
                            model.saveGroupingListToLibrary()
                            library = GroupingLibrary.all()
                        }
                        Button("Manage Standard Lists…") { model.showAppSettings() }
                    } label: {
                        Label("List", systemImage: "arrow.up.arrow.down.square")
                    }
                    .fixedSize()
                    .help("Import and export this file's list, switch it to one of your standard lists, or save it as one. Standard lists are managed in TB Tool ▸ Settings.")
                    Button("Edit") {
                        if let g = e.grouping(selection) { edit(GroupingDraft(g), e) }
                    }
                    .disabled(selection == nil)
                    Button("Delete", role: .destructive) {
                        if let id = selection {
                            model.mutate("Delete Grouping") { $0.deleteGrouping(id) }
                            selection = nil
                        }
                    }
                    .disabled(selection == nil)
                    .help("Deleting a subgroup moves its accounts up to the grouping. Deleting a grouping removes its subgroups too and un-groups their accounts.")
                    Button {
                        // Under the selected grouping — or beside the selected subgroup.
                        guard let g = e.grouping(selection) else { return }
                        let parent = e.parentGrouping(of: g) ?? g
                        edit(GroupingDraft(groupingID: nil, code: "", name: "", section: parent.section, parent: parent.id), e)
                    } label: {
                        Label("New Subgroup", systemImage: "arrow.turn.down.right")
                    }
                    .disabled(selection == nil)
                    .help("Add a subgroup under the selected grouping. Subgroups show nested under it in the grouping reports.")
                    Button {
                        edit(GroupingDraft(groupingID: nil, code: "", name: "", section: e.grouping(selection)?.section ?? e.groupingSections.first ?? ""), e)
                    } label: {
                        Label("New Grouping", systemImage: "plus")
                    }
                }
                Divider()
                UngroupedBanner()
                if let (code, sharing) = e.sharedGroupingCodes.first {
                    // A file from before every code had to be unique.
                    HStack(spacing: 10) {
                        Label("Code \(code) is used by \(sharing.count) groupings\(e.sharedGroupingCodes.count > 1 ? " (and \(e.sharedGroupingCodes.count - 1) more shared code\(e.sharedGroupingCodes.count == 2 ? "" : "s"))" : ""). Each code should be used once.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Combine as Subgroups") {
                            var n = 0
                            if model.mutate("Combine Shared Codes", { n = $0.mergeSharedGroupingCodes() }) {
                                model.status = n > 0 ? "\(n) groupings are now subgroups of the grouping that has their code. Every account kept its assignment."
                                                     : "Those codes have to be changed by hand: edit the groupings that share them."
                            }
                        }
                        .help("Puts the groupings that share a code under one grouping with that code, as its subgroups. Accounts keep their assignments and the totals don't change. You can undo this.")
                        Spacer()
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(Color.orange.opacity(0.08))
                    Divider()
                }
                Table(rows, selection: $selection) {
                    TableColumn("Section") { r in Text(r.depth == 0 ? r.grouping.section : "").foregroundStyle(.secondary) }
                        .width(min: 36, ideal: 160)
                    TableColumn("Code") { r in
                        Text(r.grouping.code.isEmpty ? e.groupingCode(r.grouping.id) : r.grouping.code)
                            .fontWeight(r.depth == 0 ? .medium : .regular)
                            .monospacedDigit()
                            .foregroundStyle(r.grouping.code.isEmpty ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.primary)
                    }
                    .width(min: 36, ideal: 80)
                    TableColumn("Name") { r in
                        HStack(spacing: 5) {
                            if r.depth > 0 { Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.secondary) }
                            Text(r.grouping.name)
                        }
                        .padding(.leading, r.depth > 0 ? 14 : 0)
                    }
                    .width(min: 36, ideal: 360)
                    TableColumn("Account Type") { r in
                        if r.depth == 0 {
                            Text(r.grouping.type?.label ?? "Any").foregroundStyle(r.grouping.type == nil ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.primary)
                        } else {
                            Text(e.groupingType(r.id)?.label ?? "Any").foregroundStyle(.tertiary)
                        }
                    }
                    .width(min: 36, ideal: 100)
                    TableColumn("Accounts") { r in
                        // A grouping counts the accounts in its subgroups too.
                        let n = (own[r.id] ?? 0) + (r.depth == 0 ? e.subgroups(of: r.id).map { own[$0.id] ?? 0 }.reduce(0, +) : 0)
                        Text(n == 0 ? "–" : String(n))
                            .monospacedDigit()
                            .foregroundStyle(n == 0 ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.primary)
                    }
                    .width(min: 36, ideal: 80)
                }
                .background(TableColumnFitter(key: "groupings", contents: [
                    "Section": rows.map(\.grouping.section), "Code": rows.map { $0.grouping.code.isEmpty ? e.groupingCode($0.grouping.id) : $0.grouping.code },
                    "Name": rows.map(\.grouping.name), "Account Type": rows.map { e.groupingType($0.id)?.label ?? "Any" }, "Accounts": ["000"],
                ], extra: ["Name": 34]))
                .contextMenu(forSelectionType: String.self) { ids in
                    if let g = e.grouping(ids.first) {
                        Button("Edit…") { edit(GroupingDraft(g), e) }
                        Button("New Subgroup…") {
                            let parent = e.parentGrouping(of: g) ?? g
                            edit(GroupingDraft(groupingID: nil, code: "", name: "", section: parent.section, parent: parent.id), e)
                        }
                    }
                } primaryAction: { ids in
                    if let g = e.grouping(ids.first) { edit(GroupingDraft(g), e) }
                }
            }
            .onAppear { library = GroupingLibrary.all() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in library = GroupingLibrary.all() }
        }
    }
}

extension GroupingsView {
    fileprivate func edit(_ draft: GroupingDraft, _ e: Engagement) {
        model.showGroupingEditor(draft, sections: e.groupingSections)
    }
}

struct GroupingDraft: Identifiable {
    let id = UUID()
    /// Nil while adding a new grouping.
    var groupingID: String?
    var code: String
    var name: String
    var section: String
    /// Set for a subgroup: the grouping it sits under.
    var parent: String? = nil
    /// The kind of account that belongs in the grouping; nil for any.
    var type: AccountType? = nil
    /// False on a new grouping until its type has been chosen (or "any type" has).
    var typeChosen = false
}

extension GroupingDraft {
    init(_ g: Grouping) {
        self.init(groupingID: g.id, code: g.code, name: g.name, section: g.section, parent: g.parent, type: g.type, typeChosen: true)
    }
}

struct GroupingSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var dismiss
    @State var draft: GroupingDraft
    let sections: [String]
    /// Set when the list being edited isn't the open file's: where to read it, and how to save a change.
    var source: (() -> Engagement)? = nil
    var commit: ((GroupingDraft) -> Bool)? = nil

    var body: some View {
        let e = source?() ?? model.engagement ?? Engagement(name: "", periodEnd: "")
        // A grouping that has subgroups of its own can't become one.
        let canNest = draft.groupingID.map { e.subgroups(of: $0).isEmpty } ?? true
        let parent = e.grouping(draft.parent)
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.groupingID == nil ? (draft.parent == nil ? "New Grouping" : "New Subgroup") : (draft.parent == nil ? "Edit Grouping" : "Edit Subgroup"))
                .font(.headline)
            Form {
                Picker("Subgroup of", selection: $draft.parent) {
                    Text("None — a grouping of its own").tag(String?.none)
                    ForEach(e.groupingSections, id: \.self) { section in
                        Section(section) {
                            ForEach(e.topGroupings(in: section).filter { $0.id != draft.groupingID }) { g in
                                Text(g.display).tag(String?.some(g.id))
                            }
                        }
                    }
                }
                .disabled(!canNest)
                .help(canNest ? "Choose a grouping to nest this one under it. Its accounts still roll up into that grouping."
                              : "This grouping has subgroups of its own, so it can't be nested under another.")
                if parent == nil {
                    HStack {
                        TextField("Section", text: $draft.section)
                        Menu("") {
                            ForEach(sections, id: \.self) { section in
                                Button(section) { draft.section = section }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Pick a section the list already has, or type a new one")
                    }
                }
                TextField("Code", text: $draft.code, prompt: Text(parent.map { "Optional — blank uses \($0.code)" } ?? ""))
                TextField("Name", text: $draft.name)
                if let parent {
                    LabeledContent("Account type") {
                        Text("\(parent.type?.label ?? "Any type") — the same as \(parent.code)").foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Account type", selection: Binding(get: { draft.typeChosen ? (draft.type?.rawValue ?? "any") : "" }, set: { tag in
                        draft.typeChosen = !tag.isEmpty
                        draft.type = AccountType(rawValue: tag)
                    })) {
                        if !draft.typeChosen { Text("Choose…").tag("") }
                        ForEach(AccountType.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                        Divider()
                        Text("Any type (a memo line)").tag("any")
                    }
                    .help("The type of every account in this grouping. An account's type is never set on the account itself: it is whatever its grouping says.")
                }
            }
            if parent == nil, let id = draft.groupingID, draft.typeChosen, let type = draft.type, type != e.grouping(id)?.type {
                let inside = Set([id] + e.subgroups(of: id).map(\.id))
                let n = e.accounts.filter { $0.grouping.map(inside.contains) ?? false && $0.type != type }.count
                if n > 0 {
                    Label("\(n) account\(n == 1 ? "" : "s") in this grouping will become \(type.label.lowercased()) account\(n == 1 ? "" : "s").", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
            if let parent {
                Text("Shown nested under \(parent.display) in the grouping reports. Its accounts are included in that grouping's total. Leave the code blank to report under \(parent.code); a code of its own must not be used anywhere else in the list.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.groupingID == nil ? "Add" : "Save") {
                    let ok: Bool
                    if let commit {
                        ok = commit(draft)
                    } else if let id = draft.groupingID {
                        ok = model.mutate("Edit Grouping") {
                            try $0.updateGrouping(id, code: draft.code, name: draft.name, section: draft.section, parent: draft.parent, type: draft.type)
                        }
                    } else {
                        ok = model.mutate(draft.parent == nil ? "Add Grouping" : "Add Subgroup") {
                            _ = try $0.addGrouping(code: draft.code, name: draft.name, section: draft.section, parent: draft.parent, type: draft.type)
                        }
                    }
                    if ok { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.parent == nil && !draft.typeChosen)
                .help(draft.parent == nil && !draft.typeChosen ? "Choose the account type first" : "")
            }
        }
        .padding(20)
        .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
