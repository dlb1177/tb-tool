import SwiftUI
import TBCore

enum ReportKind: String, CaseIterable, Identifiable {
    case consolidating, groupingSummary, groupingDetail, entity, journal, data, accounts

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
        }
    }

    var blurb: String {
        switch self {
        case .consolidating: return "Every account, one column per trial balance, then Combined, Eliminations, Consolidated."
        case .groupingSummary: return "The consolidation rolled up to the grouping list, subgroups nested under their grouping. Double-click a grouping for its accounts."
        case .groupingDetail: return "Each grouping and subgroup opened up to the accounts inside it."
        case .entity: return "One trial balance: Unadjusted, AJE, Adjusted, RJE, Final, TJE, Tax."
        case .journal: return "One row per journal line, with the entry's number, type, and linked files."
        case .data: return "One row per trial balance × account with every column. Built for pivots, charts, and handing to Claude."
        case .accounts: return "The shared chart with types and grouping assignments."
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
    @State private var entityID = ""
    @State private var entryFilter = "all"

    private var kind: ReportKind { ReportKind(rawValue: kindRaw) ?? .consolidating }

    var body: some View {
        if let saved = model.ledger {
            // On screen: the file plus any entry being typed in an open entry window. Exports and
            // Copy always use what is saved.
            let ledger = model.liveLedger ?? saved
            let e = ledger.engagement
            let table = makeTable(ledger)
            let exported = model.drafts.isEmpty ? table : makeTable(saved)
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
                        Button(format.label) { model.export(exported, as: format) }
                    }
                    Button("Copy") { model.copyToClipboard(exported) }
                        .help("Copies the report so it pastes into a spreadsheet as cells")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
                DraftBanner(exportNote: true)
                GridPanel(table: table, key: "report.\(kind.rawValue)") { row in
                    model.open(row, basis: Basis(rawValue: basisRaw) ?? .book)
                }
            }
            .onAppear {
                if e.entity(entityID) == nil { entityID = e.entities.first?.id ?? "" }
            }
        }
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
            return reports.entityTrialBalance(entityID: id, hideZero: hideZero, prior: priorCount, priorBasis: Basis(rawValue: priorBasis) ?? .book)
        case .journal:
            return reports.journalEntries(types: JEType(rawValue: entryFilter).map { [$0] })
        case .data: return reports.tidy(hideZero: hideZero)
        case .accounts: return reports.chartOfAccounts()
        }
    }
}
