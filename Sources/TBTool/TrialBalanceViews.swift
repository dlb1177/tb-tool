import SwiftUI
import TBCore

/// The page header used by every detail view: title, a line of context, and controls on the right.
struct PageHeader<Controls: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var controls: () -> Controls

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.bold()).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            controls()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Shown above the balances while a journal entry window holds an entry that hasn't been posted.
struct DraftBanner: View {
    @EnvironmentObject private var model: AppModel
    /// On screens that export: say that exports leave the unposted entry out.
    var exportNote = false

    var body: some View {
        if !model.drafts.isEmpty {
            let names = model.drafts.values.map(\.number).sorted().joined(separator: ", ")
            HStack(spacing: 8) {
                Label("Includes \(names) as it is being typed — not posted yet. The balances update as you type and go back if you cancel."
                      + (exportNote ? " Exports and Copy leave it out until it is posted." : ""), systemImage: "pencil.line")
                Spacer()
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.10))
            Divider()
        }
    }
}

/// The accounts inside one grouping, with every consolidation column, in its own window. Opened
/// by double-clicking a grouping. Like the other balance screens it follows an entry as it is typed.
struct GroupDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var closeWindow
    @AppStorage("view.priorCount") private var priorCount = 1
    @AppStorage(HideZeroToggle.key) private var hideZero = true
    let groupingID: String
    @State var basisRaw: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let saved = model.ledger, saved.engagement.grouping(groupingID) != nil {
                let ledger = model.liveLedger ?? saved
                let basis = Basis(rawValue: basisRaw) ?? .book
                let table = Reports(ledger: ledger).groupingAccounts(groupingID: groupingID, basis: basis, prior: priorCount, hideZero: hideZero)
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(table.title).font(.title3.bold()).lineLimit(1)
                        Text(table.subtitle).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Picker("Basis", selection: $basisRaw) {
                        ForEach(Basis.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    PriorPeriodsMenu(ledger: ledger, count: $priorCount)
                    HideZeroToggle()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()
                DraftBanner()
                GridPanel(table: table, key: "group-detail") { row in
                    if let id = row.accountID { model.showActivity(accountID: id, entityID: nil) }
                }
                Divider()
                HStack {
                    let exported = model.drafts.isEmpty ? table
                        : Reports(ledger: saved).groupingAccounts(groupingID: groupingID, basis: basis, prior: priorCount, hideZero: hideZero)
                    Button("Copy") { model.copyToClipboard(exported) }
                    Menu("Export") {
                        ForEach(AppModel.ExportFormat.allCases, id: \.self) { format in
                            Button(format.label) { model.export(exported, as: format) }
                        }
                    }
                    .fixedSize()
                    Text("Double-click an account to see what makes up its balance.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { closeWindow() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            } else {
                EmptyState(title: "This grouping is no longer in the list", message: "")
            }
        }
        .frame(minWidth: 600, minHeight: 280)
    }
}

/// How many prior years to show beside this year's balances.
struct PriorPeriodsMenu: View {
    let ledger: Ledger
    @Binding var count: Int
    /// Nil where the screen's own book / tax switch decides.
    var basis: Binding<String>? = nil

    var body: some View {
        let years = ledger.priorYears
        if !years.isEmpty {
            let e = ledger.engagement
            Menu {
                Picker("Prior periods", selection: $count) {
                    Text("None").tag(0)
                    ForEach(Array(years.enumerated()), id: \.offset) { i, year in
                        Text(i == 0 ? e.priorLabel(year) : "\(e.priorLabel(years[0]).split(separator: " ")[0]) – \(e.priorLabel(year))").tag(i + 1)
                    }
                }
                .pickerStyle(.inline)
                if let basis {
                    Picker("Prior periods on", selection: basis) {
                        Text("Book basis").tag(Basis.book.rawValue)
                        Text("Tax basis").tag(Basis.tax.rawValue)
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Label(count == 0 ? "Prior Periods" : "Prior Periods (\(min(count, years.count)))", systemImage: "clock.arrow.circlepath")
            }
            .fixedSize()
            .help("Show prior-year closing balances beside this year's, with the change from the most recent one. PP1 is one year back from the file's current year.")
        }
    }
}

// MARK: - Consolidated

struct ConsolidatedView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("consolidated.basis") private var basisRaw = Basis.book.rawValue
    @AppStorage("consolidated.layout") private var layout = "accounts"
    @AppStorage(HideZeroToggle.key) private var hideZero = true
    @AppStorage("view.priorCount") private var priorCount = 1

    var body: some View {
        if let ledger = model.liveLedger ?? model.ledger {
            let e = ledger.engagement
            let basis = Basis(rawValue: basisRaw) ?? .book
            VStack(spacing: 0) {
                PageHeader(title: "Consolidated", subtitle: subtitle(e)) {
                    Picker("Rows", selection: $layout) {
                        Text("By Account").tag("accounts")
                        Text("By Grouping").tag("groupings")
                        Text("Grouping Detail").tag("detail")
                    }
                    .labelsHidden()
                    .fixedSize()
                    Picker("Basis", selection: $basisRaw) {
                        ForEach(Basis.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Book: unadjusted + adjusting + reclassifying entries. Tax: book + tax-only entries.")
                    PriorPeriodsMenu(ledger: ledger, count: $priorCount)
                    HideZeroToggle()
                }
                Divider()
                DraftBanner()
                if e.entities.isEmpty {
                    EmptyState(title: "No trial balances yet",
                               message: "Import one file per trial balance — Excel, CSV, or text, or paste cells. Each becomes its own column here, and they consolidate automatically.",
                               button: "Import Trial Balances…") { model.importPanel() }
                } else {
                    GridPanel(table: table(ledger, basis), key: "consolidated.\(layout)") { row in
                        model.open(row, basis: basis)
                    }
                    Divider()
                    checks(ledger, basis)
                }
            }
        }
    }

    private func subtitle(_ e: Engagement) -> String {
        let n = e.entities.count
        let when = Timestamp.longDay(e.periodEnd).map { " · year ended \($0)" } ?? ""
        return "\(n) trial balance\(n == 1 ? "" : "s")\(when) · double-click \(layout == "accounts" ? "a row to see what makes up the balance" : "a grouping to see its accounts")"
    }

    private func table(_ ledger: Ledger, _ basis: Basis) -> ReportTable {
        let reports = Reports(ledger: ledger)
        switch layout {
        case "groupings": return reports.groupingSummary(basis: basis, detail: false, prior: priorCount, hideZero: hideZero)
        case "detail": return reports.groupingSummary(basis: basis, detail: true, prior: priorCount, hideZero: hideZero)
        default: return reports.consolidating(basis: basis, hideZero: hideZero, prior: priorCount)
        }
    }

    private func checks(_ ledger: Ledger, _ basis: Basis) -> some View {
        // A reclassifying entry that spans trial balances moves amounts between them on purpose, so a
        // trial balance is only "out of balance" beyond what was reclassified to or from it.
        let outOfBalance = ledger.engagement.entities.filter { !ledger.imbalance(basis, entity: $0.id).isZero }
        let elim = ledger.eliminationsTotal()
        return HStack(spacing: 18) {
            CheckBadge(ok: outOfBalance.isEmpty,
                       text: outOfBalance.isEmpty ? "Every trial balance is in balance"
                                                  : "Out of balance: \(outOfBalance.map(\.name).joined(separator: ", "))")
            CheckBadge(ok: elim.isZero, text: elim.isZero ? "Eliminations net to zero" : "Eliminations off by \(elim.formatted)")
            Spacer()
            Text("Consolidated net income (\(basis.label.lowercased()))")
                .foregroundStyle(.secondary)
            Text(ledger.consolidatedNetIncome(basis).formatted)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 16)
        .frame(height: 30)
    }
}

// MARK: - One trial balance

struct EntityView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(HideZeroToggle.key) private var hideZero = true
    @AppStorage("view.priorCount") private var priorCount = 1
    @AppStorage("entity.priorBasis") private var priorBasis = Basis.book.rawValue
    /// Show the accounts under their groupings, with a total for each, as the grouping detail report does.
    @AppStorage("entity.byGrouping") private var byGrouping = false
    /// A sort clicked while laid out by grouping: sorting gives a plain list, so the layout goes
    /// back to the plain one and takes the sort with it.
    @State private var carriedSort: NamedSort?
    let entityID: String

    var body: some View {
        if let ledger = model.liveLedger ?? model.ledger, let entity = ledger.engagement.entity(entityID) {
            let e = ledger.engagement
            let reports = Reports(ledger: ledger)
            let basis = Basis(rawValue: priorBasis) ?? .book
            let table = byGrouping ? reports.entityByGrouping(entityID: entityID, hideZero: hideZero, prior: priorCount, priorBasis: basis)
                                   : reports.entityTrialBalance(entityID: entityID, hideZero: hideZero, prior: priorCount, priorBasis: basis)
            VStack(spacing: 0) {
                PageHeader(title: entity.name, subtitle: subtitle(entity)) {
                    if entity.activityNumber.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button {
                            model.showEntityDetails(entityID)
                        } label: {
                            Label("No activity number", systemImage: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.orange)
                        .help("Every trial balance needs the activity number it is imported under in the tax software. Click to set it.")
                    }
                    Toggle(isOn: Binding(get: { byGrouping }, set: {
                        carriedSort = nil
                        byGrouping = $0
                    })) {
                        Label("By Grouping", systemImage: "list.bullet.indent")
                    }
                    .toggleStyle(.button)
                    .help("Show the accounts under their groupings and subgroups, with a total for each. Click again for the plain list.")
                    PriorPeriodsMenu(ledger: ledger, count: $priorCount, basis: $priorBasis)
                    HideZeroToggle()
                    Menu {
                        ForEach([JEType.adjusting, .reclassifying, .taxOnly], id: \.self) { type in
                            Button("\(type.label) Entry") { model.newEntry(type, entityID: entityID) }
                        }
                    } label: {
                        Label("New Entry", systemImage: "plus")
                    }
                    .fixedSize()
                    Menu {
                        Button("Name and Activity Number…") { model.showEntityDetails(entityID) }
                        Divider()
                        Button("Edit Unadjusted Balances…") { model.showBalanceEditor(entityID: entityID, priorYear: nil) }
                        Button("Add Accounts and Balances from File…") { model.importPanel(replacing: entityID, appending: true) }
                        Button("Replace Unadjusted Balances from File…") { model.importPanel(replacing: entityID) }
                        if let year = e.currentYear {
                            Divider()
                            ForEach(1...4, id: \.self) { back in
                                let has = entity.priorPeriods.contains { $0.year == year - back }
                                Menu("PP\(back) \(String(year - back))\(has ? "" : " — none yet")") {
                                    Button("Import from File…") { model.importPanel(replacing: entityID, priorYear: year - back) }
                                    Button(has ? "Edit Balances…" : "Enter Balances…") { model.showBalanceEditor(entityID: entityID, priorYear: year - back) }
                                    if has {
                                        Button("Remove \(String(year - back)) Balances", role: .destructive) {
                                            model.mutate("Remove Prior Year") { $0.deletePriorPeriod(year - back, entity: entityID) }
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Balances", systemImage: "pencil")
                    }
                    .fixedSize()
                    .help("Change the unadjusted balances by hand, replace them from a file, or bring in prior-year balances")
                }
                Divider()
                DraftBanner()
                if entity.balances.isEmpty && ledger.activeAccounts(in: entityID).isEmpty {
                    VStack(spacing: 10) {
                        EmptyState(title: "No balances yet", message: "Import this trial balance from an Excel, CSV or text file, or key the balances in by hand.",
                                   button: "Import from File…") { model.importPanel(replacing: entityID) }
                            .frame(maxHeight: 160)
                        Button("Enter Balances by Hand…") { model.showBalanceEditor(entityID: entityID, priorYear: nil) }
                        Spacer()
                    }
                    .padding(.top, 80)
                } else {
                    GridPanel(table: table, key: byGrouping ? "entity.grouped" : "entity", onActivate: { row in
                        if let id = row.accountID { model.showActivity(accountID: id, entityID: entityID) }
                    }, initialSort: byGrouping ? nil : carriedSort, onSort: { sort in
                        guard byGrouping, let sort else { return }
                        carriedSort = NamedSort(title: ["Code": "Account", "Grouping": "Name"][sort.title] ?? sort.title, ascending: sort.ascending)
                        byGrouping = false
                    })
                    .id(byGrouping)
                    Divider()
                    checks(ledger)
                }
            }
        }
    }

    private func subtitle(_ entity: Entity) -> String {
        let edited = (entity.editedAt.isEmpty ? "" : " · changed by hand on \(entity.editedAt.prefix(10))")
            + (entity.activityNumber.isEmpty ? "" : " · activity \(entity.activityNumber)")
        guard !entity.source.isEmpty else {
            return entity.balances.isEmpty ? "No trial balance imported" : "Balances entered by hand\(edited.replacingOccurrences(of: " · changed by hand", with: ""))"
        }
        let day = String(entity.importedAt.prefix(10))
        return "Balances stored in this file · from \(entity.source)\(day.isEmpty ? "" : " on \(day)")\(edited)"
    }

    private func checks(_ ledger: Ledger) -> some View {
        let unadjusted = ledger.total(.unadjusted, entity: entityID)
        let final = ledger.total(.tax, entity: entityID)
        // What reclassifying entries that span trial balances moved here from the others (or away).
        let moved = ledger.total(.rje, entity: entityID)
        let n = ledger.engagement.entries(touching: entityID).count
        return HStack(spacing: 18) {
            CheckBadge(ok: unadjusted.isZero, text: unadjusted.isZero ? "Imported trial balance is in balance" : "Imported trial balance is off by \(unadjusted.formatted)")
            if !moved.isZero && (final - moved).isZero {
                CheckBadge(ok: true, text: "In balance but for \(moved.formatted) reclassified \(moved.cents > 0 ? "from" : "to") other trial balances")
                    .help("A reclassifying entry that names more than one trial balance moves an amount between them. Each is then off by its share, and the consolidation still balances.")
            } else {
                CheckBadge(ok: final.isZero, text: final.isZero ? "Adjusted columns are in balance" : "Adjusted columns are off by \(final.formatted)")
            }
            Text("\(n) journal entr\(n == 1 ? "y" : "ies")").foregroundStyle(.secondary)
            Spacer()
            Text("Net income (book)").foregroundStyle(.secondary)
            Text(ledger.netIncome(.book, entity: entityID).formatted)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 16)
        .frame(height: 30)
    }
}

struct EmptyState: View {
    let title: String
    let message: String
    var button: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let button, let action {
                Button(button, action: action).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
