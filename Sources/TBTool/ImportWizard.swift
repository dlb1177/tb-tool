import SwiftUI
import TBCore

/// The import window's content: the file at the front of the queue, one at a time.
struct ImportHost: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let request = model.importQueue.first, let e = model.engagement {
            ImportWizard(request: request, engagement: e, profiles: model.importProfiles)
                .id(request.id)  // a fresh screen (and fresh prediction) for each file
        } else {
            Color.clear.frame(minWidth: 980, minHeight: 560)
        }
    }
}

/// Shows a source file exactly as it is, with the app's prediction of what each column holds
/// and which rows are accounts. Everything can be changed before anything is imported.
struct ImportWizard: View {
    @EnvironmentObject private var model: AppModel
    let request: ImportRequest

    @State private var sheetIndex: Int
    @State private var mapping: ImportMapping
    @State private var target: String  // "new" or an entity id
    @State private var newName: String
    @State private var remember = true
    @State private var showOnlyIssues = false
    /// 0 for this year's unadjusted balances, otherwise the prior year the file holds.
    @State private var period: Int
    /// Set once Import is clicked and the file names accounts differently from the chart: the
    /// second step, where each difference is decided.
    @State private var conflicts: [AccountNameConflict]?
    @State private var resolutions: [String: AccountNameResolution] = [:]

    private static let newTarget = "__new__"

    init(request: ImportRequest, engagement: Engagement, profiles: [ImportProfile]) {
        self.request = request
        let guess = TBImporter.bestGuess(sheets: request.sheets, profiles: profiles, knownTypes: engagement.accountTypes)
        _sheetIndex = State(initialValue: guess.sheetIndex)
        _mapping = State(initialValue: guess.mapping)
        let existing = request.replacing
            ?? engagement.entities.first { $0.name.caseInsensitiveCompare(request.suggestedName) == .orderedSame }?.id
        _target = State(initialValue: existing ?? Self.newTarget)
        _newName = State(initialValue: request.suggestedName)
        _period = State(initialValue: request.priorYear ?? 0)
    }

    private var engagement: Engagement { model.engagement ?? Engagement(name: "", periodEnd: "") }
    private var sheet: RawSheet { request.sheets[min(sheetIndex, request.sheets.count - 1)] }
    private var preview: ImportPreview {
        TBImporter.evaluate(sheet, mapping, sourceName: request.sourceName, knownTypes: engagement.accountTypes)
    }

    var body: some View {
        let p = preview
        Group {
            if let conflicts {
                NameConflictReview(engagement: engagement, conflicts: conflicts, resolutions: $resolutions, sourceName: request.sourceName,
                                   importLabel: p.tb.total.isZero ? "Import \(p.tb.accountCount) Accounts" : "Import Out of Balance",
                                   onBack: { self.conflicts = nil },
                                   onCancel: { model.finishImport(request) },
                                   onImport: { commit(p.tb) })
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    settings
                    Divider()
                    ImportPreviewGrid(sheet: sheet, preview: p, mapping: $mapping, showOnlyIssues: showOnlyIssues)
                    Divider()
                    footer(p)
                }
            }
        }
        .frame(minWidth: 980, minHeight: 560)
        .onAppear {
            // For documentation pictures: open on the review with one of each kind of decision made.
            // (Only ever shows the review; with nothing to review it does nothing rather than import.)
            guard request.reviewNames, !engagement.accountNameConflicts(in: p.tb).isEmpty else { return }
            startImport(p.tb)
            if let found = conflicts, found.count >= 4 {
                resolutions[found[1].accountID] = AccountNameResolution(.useFileName)
                resolutions[found[2].accountID] = AccountNameResolution(.separateAccount(number: engagement.suggestedSeparateNumber(for: found[2].number)))
                resolutions[found[3].accountID] = AccountNameResolution(.keepChartName, keepGrouping: false)
            }
        }
    }

    /// Import was clicked. If the file names any account differently from the chart, those are
    /// decided first; otherwise it comes straight in.
    private func startImport(_ tb: ImportedTB) {
        let found = engagement.accountNameConflicts(in: tb)
        if found.isEmpty {
            commit(tb)
        } else {
            // Decisions already made (the person went back to the layout and returned) are kept.
            resolutions = resolutions.filter { key, _ in found.contains { $0.accountID == key } }
            for c in found where resolutions[c.accountID] == nil { resolutions[c.accountID] = AccountNameResolution() }
            conflicts = found
        }
    }

    private func commit(_ tb: ImportedTB) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        model.commitImport(request, tb: tb, mapping: mapping, header: mapping.headerRow.map { sheet.rows[$0] },
                           target: target == Self.newTarget ? nil : target, newName: name, rememberLayout: remember,
                           priorYear: period == 0 ? nil : period, resolutions: conflicts == nil ? [:] : resolutions)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Import Trial Balance").font(.title3.bold())
                Text(request.sourceName).foregroundStyle(.secondary)
            }
            Spacer()
            if model.importQueue.count > 1 {
                Text("\(model.importQueue.count - 1) more file\(model.importQueue.count == 2 ? "" : "s") after this")
                    .foregroundStyle(.secondary)
            }
            if mapping.fromSavedLayout {
                Label("Recognized a layout you saved before", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            } else {
                Label("Layout predicted — check it below", systemImage: "wand.and.stars")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                if request.sheets.count > 1 {
                    field("Sheet") {
                        Picker("", selection: Binding(get: { sheetIndex }, set: { new in
                            sheetIndex = new
                            mapping = TBImporter.guess(request.sheets[new], profiles: model.importProfiles, knownTypes: engagement.accountTypes)
                        })) {
                            ForEach(request.sheets.indices, id: \.self) { Text(request.sheets[$0].name).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                if let year = engagement.currentYear {
                    field("These are") {
                        Picker("", selection: $period) {
                            Text("\(String(year)) unadjusted balances").tag(0)
                            Divider()
                            ForEach(1...5, id: \.self) { back in
                                Text("PP\(back) — \(String(year - back)) closing balances").tag(year - back)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .help("Prior-year balances sit beside this year's as PP1, PP2… They don't change this year's balances.")
                    }
                }
                field(period == 0 ? "Import into" : "For") {
                    Picker("", selection: $target) {
                        Text("New trial balance").tag(Self.newTarget)
                        if !engagement.entities.isEmpty { Divider() }
                        ForEach(engagement.entities) { Text(period == 0 ? "Replace “\($0.name)”" : $0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(request.replacing != nil)
                }
                if target == Self.newTarget {
                    field("Name") {
                        TextField("Trial balance name", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 240)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 16) {
                field("Header row") {
                    Picker("", selection: Binding(get: { mapping.headerRow ?? -1 }, set: { new in
                        mapping.headerRow = new < 0 ? nil : new
                        mapping.fromSavedLayout = false
                    })) {
                        Text("None").tag(-1)
                        ForEach(Array(sheet.rows.prefix(80).enumerated()), id: \.offset) { i, row in
                            let cells = row.filter { !$0.isEmpty }.prefix(4).joined(separator: " · ")
                            Text("Row \(i + 1)\(cells.isEmpty ? "" : ": " + String(cells.prefix(70)))").tag(i)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 380)
                }
                if mapping.usesBalance {
                    field("Balance signs") {
                        Picker("", selection: $mapping.sign) {
                            ForEach(SignConvention.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                Spacer(minLength: 0)
            }
            Text(period != 0
                 ? "These come in as \(engagement.priorLabel(period)) closing balances\(target == Self.newTarget ? "" : " for “\(engagement.entity(target)?.name ?? "")”"), shown beside this year's. This year's balances and journal entries are not changed."
                 : target == Self.newTarget
                 ? "Check the role above each column and the rows that come in (✓). Totals, headings and blank lines are left out automatically, but any row except the header can be checked or unchecked by hand. Right-click a row number to make it the header. Accounts with no number are kept by name."
                 : "The balances of “\(engagement.entity(target)?.name ?? "")” will be replaced. Its journal entries stay as they are.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary).fixedSize()
            content()
        }
    }

    // MARK: Footer

    private func footer(_ p: ImportPreview) -> some View {
        let tb = p.tb
        let leftOut = p.rows.filter { $0.kind == .account && !$0.included }.count
        let issues = p.problems + p.rows.filter { $0.kind == .badAmount }.prefix(3).map { "Row \($0.index + 1): \($0.note)" } + tb.warnings
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    if issues.isEmpty {
                        CheckBadge(ok: true, text: "In balance — ready to import")
                    }
                    ForEach(Array(issues.prefix(4).enumerated()), id: \.offset) { _, text in
                        Label(text, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    Text(summary(p, leftOut: leftOut))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                total("Accounts", "\(tb.accountCount)")
                total("Debits", tb.totalDebits.grouped)
                total("Credits", tb.totalCredits.grouped)
                total("Difference", (tb.total.cents < 0 ? -tb.total : tb.total).grouped, warn: !tb.total.isZero)
            }
            HStack {
                Toggle("Show only rows that are left out or flagged", isOn: $showOnlyIssues)
                Toggle("Remember this layout for files like this", isOn: $remember)
                    .disabled(mapping.headerRow == nil)
                    .help("Next time a file with the same column headings comes in, these column roles are used automatically")
                Spacer()
                if model.importQueue.count > 1 {
                    Button("Cancel All") { model.cancelAllImports() }
                }
                Button(model.importQueue.count > 1 ? "Skip This File" : "Cancel") { model.finishImport(request) }
                    .keyboardShortcut(.cancelAction)
                Button(tb.total.isZero ? "Import \(tb.accountCount) Accounts" : "Import Out of Balance") { startImport(tb) }
                    .help("If the file names any account differently from the chart, you'll be asked which name to keep before anything comes in.")
                .keyboardShortcut(.defaultAction)
                .disabled(!p.isUsable || (target == Self.newTarget && newName.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(14)
    }

    private func summary(_ p: ImportPreview, leftOut: Int) -> String {
        var parts: [String] = []
        if p.count(.total) > 0 { parts.append("\(p.count(.total)) total line\(p.count(.total) == 1 ? "" : "s")") }
        if p.count(.heading) > 0 { parts.append("\(p.count(.heading)) heading\(p.count(.heading) == 1 ? "" : "s")") }
        if p.count(.noAccount) > 0 { parts.append("\(p.count(.noAccount)) amount\(p.count(.noAccount) == 1 ? "" : "s") with no account") }
        if leftOut > 0 { parts.append("\(leftOut) account\(leftOut == 1 ? "" : "s") you left out") }
        let unnumbered = p.tb.rows.filter { $0.number.isEmpty }.count
        var text = parts.isEmpty ? "Nothing skipped." : "Skipped: " + parts.joined(separator: ", ") + "."
        if unnumbered > 0 { text += " \(unnumbered) account\(unnumbered == 1 ? " has" : "s have") no number and will be kept by name." }
        return text
    }

    private func total(_ label: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(warn ? Color.orange : Color.primary)
        }
        .frame(minWidth: 90, alignment: .trailing)
    }
}

// MARK: - The sheet as it is

struct ImportPreviewGrid: View {
    let sheet: RawSheet
    let preview: ImportPreview
    @Binding var mapping: ImportMapping
    let showOnlyIssues: Bool

    private var columnCount: Int { min(max(sheet.columnCount, mapping.roles.count), 60) }

    private var widths: [CGFloat] {
        (0..<columnCount).map { c in
            let longest = sheet.rows.prefix(300).map { c < $0.count ? $0[c].count : 0 }.max() ?? 0
            return min(max(CGFloat(longest) * 7 + 18, 120), 300)
        }
    }

    var body: some View {
        let w = widths
        let rows = preview.rows.filter { r in
            !showOnlyIssues || (r.kind != .account && r.kind != .blank && r.kind != .aboveHeader) || !r.included
        }
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(rows, id: \.index) { r in
                        rowView(r, widths: w)
                    }
                } header: {
                    roleHeader(w)
                }
            }
        }
    }

    private func letter(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 {
            s = String(UnicodeScalar(UInt8(65 + (n - 1) % 26))) + s
            n = (n - 1) / 26
        }
        return s
    }

    private func roleHeader(_ w: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            Text("In").frame(width: 34)
            Text("Row").frame(width: 46, alignment: .trailing).padding(.trailing, 6)
            ForEach(0..<columnCount, id: \.self) { c in
                VStack(alignment: .leading, spacing: 2) {
                    Text(letter(c)).font(.caption2).foregroundStyle(.tertiary)
                    Picker("", selection: Binding(get: { mapping.role(c) }, set: { role in
                        mapping.setRole(role, for: c)
                        mapping.fromSavedLayout = false
                    })) {
                        ForEach(ColumnRole.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .tint(tint(mapping.role(c)))
                }
                .padding(.horizontal, 4)
                .frame(width: w[c], alignment: .leading)
                .background(tint(mapping.role(c)).opacity(mapping.role(c) == .ignore ? 0 : 0.10))
            }
            Text("Comes in as").frame(width: 320, alignment: .leading).padding(.leading, 10)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tint(_ role: ColumnRole) -> Color {
        role.isAccount ? .blue : (role.isAmount ? .green : (role == .accountType ? .purple : .secondary))
    }

    private func rowView(_ r: PreviewRow, widths w: [CGFloat]) -> some View {
        let cells = r.index < sheet.rows.count ? sheet.rows[r.index] : []
        // A row that is left out fades; its checkbox stays at full strength so it reads as clickable.
        let fade: Double = !r.included && r.kind != .header ? 0.5 : 1
        return HStack(spacing: 0) {
            Group {
                if r.toggleable {
                    Toggle("", isOn: Binding(get: { r.included }, set: { on in mapping.setIncluded(on, row: r) }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                } else {
                    Text("")
                }
            }
            .frame(width: 34)
            Text("\(r.index + 1)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)
                .padding(.trailing, 6)
                .opacity(fade)
                .contextMenu {
                    Button("Use Row \(r.index + 1) as the Header Row") {
                        mapping.headerRow = r.index
                        mapping.fromSavedLayout = false
                    }
                    if mapping.headerRow != nil { Button("No Header Row") { mapping.headerRow = nil } }
                }
            ForEach(0..<columnCount, id: \.self) { c in
                let text = c < cells.count ? cells[c] : ""
                Text(text)
                    .font(.system(size: 12, weight: r.kind == .header ? .semibold : .regular))
                    .foregroundStyle(mapping.role(c) == .ignore && r.kind != .header ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 6)
                    .frame(width: w[c], alignment: mapping.role(c).isAmount ? .trailing : .leading)
                    .opacity(fade)
                    .help(text)
            }
            result(r)
                .frame(width: 320, alignment: .leading)
                .padding(.leading, 10)
                .opacity(fade)
        }
        .frame(height: 22)
        .background(background(r))
    }

    @ViewBuilder
    private func result(_ r: PreviewRow) -> some View {
        if r.included {
            HStack(spacing: 6) {
                Text(r.label).lineLimit(1).truncationMode(.tail)
                if r.kind != .account {
                    // Checked by hand: say so, and what had to be filled in.
                    Text(r.note).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1).help(r.note)
                }
                Spacer(minLength: 4)
                Text(r.amount.formatted).monospacedDigit()
            }
            .font(.system(size: 12))
        } else if !r.note.isEmpty {
            Text(r.note)
                .font(.system(size: 11.5))
                .foregroundStyle(r.kind == .badAmount || r.kind == .noAccount ? Color.orange : Color.secondary)
                .lineLimit(1)
        }
    }

    private func background(_ r: PreviewRow) -> Color {
        switch r.kind {
        case .header: return Color.accentColor.opacity(0.16)
        case .badAmount, .noAccount: return Color.orange.opacity(0.10)
        case .total, .heading: return Color.primary.opacity(0.03)
        default: return r.index.isMultiple(of: 2) ? .clear : Color.primary.opacity(0.025)
        }
    }
}

// MARK: - Chart of accounts import

struct ChartImportSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var dismiss
    let request: ChartImportRequest
    @State private var options = ChartImportOptions()

    var body: some View {
        let e = model.engagement ?? Engagement(name: "", periodEnd: "")
        let plan = e.planChartImport(request.chart, options: options)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Chart of Accounts").font(.title3.bold())
                Text("\(request.sourceName) · \(request.chart.accounts.count) accounts. Matched by account number; accounts with no number are matched by name.")
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Apply groupings", isOn: $options.applyGroupings)
                    Toggle("Replace groupings already set in this file", isOn: $options.overwriteGroupings)
                        .disabled(!options.applyGroupings)
                        .padding(.leading, 18)
                    Toggle("Apply account types", isOn: $options.applyTypes)
                    Toggle("Add accounts this file doesn't have", isOn: $options.addMissing)
                }
                VStack(alignment: .leading, spacing: 4) {
                    stat("\(plan.matched) of \(request.chart.accounts.count) accounts matched")
                    stat("\(plan.groupingChanges) groupings will be set")
                    stat("\(plan.typeChanges) account types will change")
                    if !plan.added.isEmpty { stat("\(plan.added.count) accounts will be added") }
                    if !plan.newGroupings.isEmpty {
                        stat("\(plan.newGroupings.count) grouping\(plan.newGroupings.count == 1 ? "" : "s") added to the list: \(plan.newGroupings.map(\.display).prefix(4).joined(separator: ", "))")
                    }
                    if !plan.keptExisting.isEmpty { stat("\(plan.keptExisting.count) existing groupings kept (differ from the source)", warn: true) }
                    if !plan.unmatched.isEmpty { stat("\(plan.unmatched.count) source accounts aren't in this file", warn: true) }
                    if !plan.unresolved.isEmpty { stat("\(plan.unresolved.count) groupings couldn't be matched — e.g. \(plan.unresolved[0])", warn: true) }
                }
                Spacer()
            }
            .padding(16)
            Divider()
            Table(plan.changes) {
                TableColumn("Account") { c in Text(c.display) }.width(min: 200, ideal: 320)
                TableColumn("Grouping now") { c in Text(e.grouping(c.oldGrouping)?.display ?? "—").foregroundStyle(.secondary) }
                    .width(min: 140, ideal: 240)
                TableColumn("Grouping after") { c in
                    Text((e.grouping(c.newGrouping) ?? plan.newGroupings.first { $0.id == c.newGrouping })?.display ?? "—")
                        .fontWeight(c.newGrouping != c.oldGrouping ? .semibold : .regular)
                }
                .width(min: 140, ideal: 240)
                TableColumn("Type") { c in
                    Text(c.newType == c.oldType ? c.newType.label : "\(c.oldType.label) → \(c.newType.label)")
                        .foregroundStyle(c.newType == c.oldType ? Color.secondary : Color.primary)
                }
                .width(min: 90, ideal: 150)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") {
                    if model.mutate("Import Chart of Accounts", { $0.applyChartImport(plan) }) {
                        model.status = "Chart imported: \(plan.groupingChanges) groupings, \(plan.typeChanges) types, \(plan.added.count) accounts added"
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.isEmpty)
            }
            .padding(14)
        }
        .frame(minWidth: 820, minHeight: 420)
    }

    private func stat(_ text: String, warn: Bool = false) -> some View {
        Label(text, systemImage: warn ? "exclamationmark.triangle" : "checkmark.circle")
            .foregroundStyle(warn ? Color.orange : Color.primary)
            .font(.callout)
    }
}
