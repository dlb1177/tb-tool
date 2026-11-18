import SwiftUI
import TBCore

enum ReportKind: String, CaseIterable, Identifiable {
    case consolidating, groupingSummary, groupingDetail, entity, journal, data, accounts, signOffs, changeLog

    var id: String { rawValue }

    var title: String {
        switch self {
        case .consolidating: return "Consolidating Trial Balance"
        case .groupingSummary: return "Grouping Summary"
        case .groupingDetail: return "Grouping Detail"
        case .entity: return "Single Trial Balance"
        case .journal: return "Journal Entries"
        case .data: return "Data (Long Format)"
        case .accounts: return "Chart of Accounts"
        case .signOffs: return "Workpaper Sign-offs"
        case .changeLog: return "Change Log"
        }
    }

    var blurb: String {
        switch self {
        case .consolidating: return "Every account, one column per trial balance, then Combined, Eliminations, Consolidated."
        case .groupingSummary: return "The consolidation rolled up to the grouping list, subgroups nested under their grouping. Double-click a grouping for its accounts."
        case .groupingDetail: return "Each grouping and subgroup opened up to the accounts inside it."
        case .entity: return "One trial balance: Unadjusted, AJE, Adjusted, RJE, Final, TJE, Tax."
        case .journal: return "Every entry set out on its own, under a heading for each kind. Click a reference to open the workpaper."
        case .data: return "One row per trial balance × account with every column. Built for pivots, charts, and handing to Claude."
        case .accounts: return "The shared chart with types and grouping assignments."
        case .signOffs: return "Every workpaper marked prepared, reviewed or second reviewed: who marked it, and when."
        case .changeLog: return "Every change to this file: what, who, on which Mac, and when."
        }
    }

    var usesBasis: Bool { self == .consolidating || self == .groupingSummary || self == .groupingDetail }
    var usesPrior: Bool { usesBasis || self == .entity }
    /// Reports whose rows are balances, so rows that are all zero can be hidden.
    var hasZeroRows: Bool { usesPrior || self == .data }
}

struct ReportsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("reports.kind") private var kindRaw = ReportKind.consolidating.rawValue
    @AppStorage("reports.basis") private var basisRaw = Basis.book.rawValue
    @AppStorage(HideZeroToggle.key) private var hideZero = true
    @AppStorage("view.priorCount") private var priorCount = 1
    @AppStorage("entity.priorBasis") private var priorBasis = Basis.book.rawValue
    @AppStorage("entity.byGrouping") private var byGrouping = false
    @State private var entityID = ""
    @State private var entryFilter = "all"
    @State private var carriedSort: NamedSort?

    private var kind: ReportKind { ReportKind(rawValue: kindRaw) ?? .consolidating }

    var body: some View {
        if let saved = model.ledger {
            // On screen: the file plus any entry being typed in an open entry window. Exports and
            // Copy always use what is saved.
            let ledger = model.liveLedger ?? saved
            let e = ledger.engagement
            let table = makeTable(ledger)
            let exported = model.drafts.isEmpty ? table : makeTable(saved)
            let grouped = kind == .entity && byGrouping
            VStack(spacing: 0) {
                PageHeader(title: "Reports & Export", subtitle: kind.blurb) {
                    Button {
                        model.quickExport()
                    } label: {
                        Label("Quick Export", systemImage: "bolt")
                    }
                    .help("Writes the full workbook (.xlsx) and the long-format data (.csv), time-stamped, into a folder you choose — the trial balance file's folder unless you pick another")
                    Button("Export Full Workbook…") { model.exportWorkbookPanel() }
                        .help("Every report as a sheet in one Excel file")
                    Button("All Reports as PDF…") { model.exportAllAsPDF() }
                        .help("Every report in one PDF, each starting on a new page, with numbered pages")
                }
                Divider()
                HStack(spacing: 10) {
                    Picker("Report", selection: $kindRaw) {
                        ForEach(ReportKind.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if kind.usesBasis {
                        Picker("Basis", selection: $basisRaw) {
                            ForEach(Basis.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    if kind == .entity {
                        Picker("Trial balance", selection: $entityID) {
                            ForEach(e.entities) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Toggle("By grouping", isOn: Binding(get: { byGrouping }, set: {
                            carriedSort = nil
                            byGrouping = $0
                        }))
                            .toggleStyle(.checkbox)
                            .fixedSize()
                            .help("Lay the accounts out under their groupings and subgroups, with a total for each")
                    }
                    if kind == .journal {
                        Picker("Type", selection: $entryFilter) {
                            Text("All Types").tag("all")
                            ForEach(JEType.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if kind.usesPrior {
                        if kind == .entity {
                            PriorPeriodsMenu(ledger: ledger, count: $priorCount, basis: $priorBasis)
                        } else {
                            PriorPeriodsMenu(ledger: ledger, count: $priorCount)
                        }
                    }
                    if kind.hasZeroRows { HideZeroToggle() }
                    Spacer()
                    Text("Export:").foregroundStyle(.secondary)
                    ForEach(AppModel.ExportFormat.allCases, id: \.self) { format in
                        // The journal goes out set out entry by entry; as JSON it goes out as records.
                        Button(format.label) { model.export(kind == .journal && format == .json ? journalData(saved) : exported, as: format) }
                    }
                    Button("Copy") { model.copyToClipboard(exported) }
                        .help("Copies the report so it pastes into a spreadsheet as cells")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
                DraftBanner(exportNote: true)
                if kind == .journal {
                    JournalReportView(ledger: ledger, types: JEType(rawValue: entryFilter).map { [$0] })
                } else {
                    GridPanel(table: table, key: grouped ? "report.entity.grouped" : "report.\(kind.rawValue)", onActivate: { row in
                        model.open(row, basis: Basis(rawValue: basisRaw) ?? .book)
                    }, initialSort: kind == .entity && !byGrouping ? carriedSort : nil, onSort: { sort in
                        // Sorting a trial balance laid out by grouping gives a plain list: untick the box to match.
                        guard grouped, let sort else { return }
                        carriedSort = NamedSort(title: ["Code": "Account", "Grouping": "Name"][sort.title] ?? sort.title, ascending: sort.ascending)
                        byGrouping = false
                    })
                    .id("\(kind.rawValue).\(grouped)")
                }
            }
            .onAppear {
                if e.entity(entityID) == nil { entityID = e.entities.first?.id ?? "" }
            }
        }
    }

    private func journalData(_ ledger: Ledger) -> ReportTable {
        Reports(ledger: ledger).journalEntries(types: JEType(rawValue: entryFilter).map { [$0] })
    }

    private func makeTable(_ ledger: Ledger) -> ReportTable {
        let reports = Reports(ledger: ledger)
        let basis = Basis(rawValue: basisRaw) ?? .book
        switch kind {
        case .consolidating: return reports.consolidating(basis: basis, hideZero: hideZero, prior: priorCount)
        case .groupingSummary: return reports.groupingSummary(basis: basis, detail: false, prior: priorCount, hideZero: hideZero)
        case .groupingDetail: return reports.groupingSummary(basis: basis, detail: true, prior: priorCount, hideZero: hideZero)
        case .entity:
            let id = ledger.engagement.entity(entityID) != nil ? entityID : (ledger.engagement.entities.first?.id ?? "")
            return byGrouping ? reports.entityByGrouping(entityID: id, hideZero: hideZero, prior: priorCount, priorBasis: Basis(rawValue: priorBasis) ?? .book)
                              : reports.entityTrialBalance(entityID: id, hideZero: hideZero, prior: priorCount, priorBasis: Basis(rawValue: priorBasis) ?? .book)
        case .journal:
            return reports.journalReport(types: JEType(rawValue: entryFilter).map { [$0] })
        case .data: return reports.tidy(hideZero: hideZero)
        case .accounts: return reports.chartOfAccounts()
        case .signOffs: return reports.signOffs()
        case .changeLog: return reports.changeLog()
        }
    }
}
