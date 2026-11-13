import AppKit
import SwiftUI
import TBCore

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            if model.engagement != nil {
                MainView()
            } else {
                WelcomeView()
            }
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, new in model.undoManager = new }
        .onOpenURL { model.open($0) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.checkExternalChange()
        }
    }
}

// MARK: - Welcome

struct WelcomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "tablecells")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text("TB Tool")
                .font(.largeTitle.bold())
            Text("Import trial balances, post journal entries, and consolidate — all in one JSON file on your Mac.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 12) {
                Button("Open Trial Balance File…") { model.openPanel() }
                    .keyboardShortcut(.defaultAction)
                Button("New Trial Balance File…") { model.newFilePanel() }
            }
            .controlSize(.large)
            if !model.candidates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("In this folder")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(model.candidates, id: \.self) { url in
                        Button {
                            model.open(url)
                        } label: {
                            Label(url.lastPathComponent, systemImage: "doc.text")
                        }
                        .buttonStyle(.link)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Main window

struct MainView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showIssues = false

    var body: some View {
        NavigationSplitView {
            Sidebar(showIssues: $showIssues)
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 320)
        } detail: {
            VStack(spacing: 0) {
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                statusBar
            }
        }
        .navigationTitle(model.engagement?.name ?? "TB Tool")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    ForEach(JEType.allCases, id: \.self) { type in
                        Button("\(type.label) Entry") { model.newEntry(type) }
                    }
                } label: {
                    Label("New Entry", systemImage: "plus.square.on.square")
                }
                .help("Post a journal entry")
                Menu {
                    Button("Import Trial Balance Files…") { model.importPanel() }
                    Button("Paste Trial Balance") { model.pasteTrialBalance() }
                    Button("New Blank Trial Balance…") { model.newBlankEntity() }
                    Divider()
                    Button("Import Chart of Accounts…") { model.importChartPanel() }
                    Button("Import Grouping List…") { model.importGroupingListPanel() }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                } primaryAction: {
                    model.importPanel()
                }
                .help("Import trial balances from Excel, CSV or text — one file per trial balance. You confirm how each is read.")
                Button {
                    model.quickExport()
                } label: {
                    Label("Quick Export", systemImage: "square.and.arrow.up")
                }
                .help("Write the full Excel workbook and the data CSV into a folder you choose")
                Button {
                    model.showRollForward()
                } label: {
                    Label("Roll Forward", systemImage: "calendar.badge.plus")
                }
                .help("Create next year's file: this year's balances become PP1 and the entries you marked carry over")
                Button {
                    model.showSettings()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Client and binder details, and the current year")
            }
        }
    }

    private var subtitle: String {
        guard let e = model.engagement else { return "" }
        var parts: [String] = []
        if let year = e.currentYear { parts.append(String(year)) }
        if !e.binder.engagement.isEmpty { parts.append(e.binder.engagement) }
        parts.append(model.fileURL?.lastPathComponent ?? "")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection ?? .consolidated {
        case .consolidated: ConsolidatedView()
        case .entity(let id):
            if model.engagement?.entity(id) != nil {
                EntityView(entityID: id).id(id)
            } else {
                ConsolidatedView()
            }
        case .journal: JournalListView()
        case .accounts: AccountsView()
        case .groupings: GroupingsView()
        case .reports: ReportsView()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Text(model.status)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let url = model.fileURL {
                Button {
                    model.reveal(url)
                } label: {
                    Label(model.displayPath(url), systemImage: "doc.text")
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .buttonStyle(.plain)
                .help("Every change is saved to this file as you make it. Click to show it in Finder.")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
    }
}

// MARK: - Sidebar

struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    @Binding var showIssues: Bool
    @State private var renaming: Entity?
    @State private var renameText = ""
    @State private var deleting: Entity?

    var body: some View {
        List(selection: $model.selection) {
            if let e = model.engagement {
                Section {
                    Label("Consolidated", systemImage: "square.stack.3d.up")
                        .tag(SidebarItem.consolidated)
                }
                Section("Trial Balances") {
                    ForEach(e.entities) { entity in
                        Label(entity.name, systemImage: "building.2")
                            .tag(SidebarItem.entity(entity.id))
                            .contextMenu {
                                Button("New Adjusting Entry") { model.newEntry(.adjusting, entityID: entity.id) }
                                Divider()
                                Button("Rename…") {
                                    renameText = entity.name
                                    renaming = entity
                                }
                                Button("Edit Unadjusted Balances…") { model.showBalanceEditor(entityID: entity.id, priorYear: nil) }
                                Button("Replace Balances from File…") { model.importPanel(replacing: entity.id) }
                                Divider()
                                Button("Delete…", role: .destructive) { deleting = entity }
                            }
                    }
                    Menu {
                        Button("Import from Files…") { model.importPanel() }
                        Button("Paste from Clipboard") { model.pasteTrialBalance() }
                        Button("New Blank Trial Balance…") { model.newBlankEntity() }
                    } label: {
                        Label("Add…", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .foregroundStyle(.secondary)
                }
                Section("Work") {
                    Label("Journal Entries", systemImage: "list.bullet.rectangle")
                        .badge(e.journalEntries.count)
                        .tag(SidebarItem.journal)
                    Label("Accounts", systemImage: "number")
                        .badge(e.accounts.filter { $0.grouping == nil }.count)
                        .tag(SidebarItem.accounts)
                        .help("Chart of accounts. The badge counts accounts with no grouping yet.")
                    Label("Grouping List", systemImage: "rectangle.3.group")
                        .tag(SidebarItem.groupings)
                    Label("Reports & Export", systemImage: "doc.richtext")
                        .tag(SidebarItem.reports)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { dataCheck }
        .alert("Rename Trial Balance", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let entity = renaming {
                    model.mutate("Rename Trial Balance") { try $0.renameEntity(entity.id, to: renameText) }
                }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let entity = deleting {
                    if model.selection == .entity(entity.id) { model.selection = .consolidated }
                    model.mutate("Delete Trial Balance") { try $0.deleteEntity(entity.id) }
                }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text(deleteMessage)
        }
    }

    private var deleteTitle: String { "Delete “\(deleting?.name ?? "")”?" }

    private var deleteMessage: String {
        guard let entity = deleting, let e = model.engagement else { return "" }
        let n = e.entries(touching: entity.id).count
        return n == 0 ? "Its imported balances will be removed. You can undo this."
                      : "Its imported balances and the \(n) journal entr\(n == 1 ? "y" : "ies") posted to it will be removed. You can undo this."
    }

    private var dataCheck: some View {
        Button {
            showIssues = true
        } label: {
            HStack(spacing: 6) {
                let problems = model.issues.count + model.brokenLinks.count
                if problems == 0 {
                    CheckBadge(ok: true, text: "Data check: clean")
                } else {
                    CheckBadge(ok: false, text: "\(problems) data issue\(problems == 1 ? "" : "s")")
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .popover(isPresented: $showIssues, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Data check").font(.headline)
                if !model.brokenLinks.isEmpty {
                    HStack {
                        Label("\(model.brokenLinks.count) linked file\(model.brokenLinks.count == 1 ? "" : "s") on journal entries can't be found.", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                        Spacer()
                        Button("Fix Links…") {
                            showIssues = false
                            model.showFixLinks()
                        }
                    }
                }
                if let e = model.engagement, !e.typeConflicts.isEmpty {
                    HStack {
                        Label("Some accounts have a type that differs from their grouping's.", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                        Spacer()
                        Button("Review Account Types…") {
                            showIssues = false
                            model.showTypeReview()
                        }
                    }
                }
                if model.issues.isEmpty && !model.brokenLinks.isEmpty {
                    EmptyView()
                } else if model.issues.isEmpty {
                    Text("Every trial balance is in balance, every entry balances and follows the posting rules, and every reference points at something that exists.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.issues, id: \.self) { issue in
                                Label(issue, systemImage: "exclamationmark.triangle")
                                    .font(.callout)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 320)
                }
            }
            .padding(16)
            .frame(width: 420)
        }
    }
}

// MARK: - Account activity

/// What makes up one account's balance, in its own window. It follows the file: post or type an
/// entry in another window and the lines here change with it.
struct ActivityView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var closeWindow
    let request: ActivityRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let ledger = model.liveLedger ?? model.ledger, ledger.engagement.account(request.accountID) != nil {
                let table = Reports(ledger: ledger).accountActivity(accountID: request.accountID, entityID: request.entityID)
                VStack(alignment: .leading, spacing: 2) {
                    Text(table.title).font(.title3.bold())
                    Text(table.subtitle).foregroundStyle(.secondary)
                }
                .padding(16)
                Divider()
                DraftBanner()
                GridPanel(table: table, key: "activity") { row in
                    if let id = row.entryID, model.engagement?.entry(id) != nil {
                        model.editEntry(id)
                    } else if row.id.hasPrefix("u:"), let entity = row.entityID {
                        model.showBalanceEditor(entityID: entity, priorYear: nil)
                    }
                }
                Divider()
                HStack {
                    let exported = model.drafts.isEmpty || model.ledger == nil ? table
                        : Reports(ledger: model.ledger!).accountActivity(accountID: request.accountID, entityID: request.entityID)
                    Button("Copy") { model.copyToClipboard(exported) }
                    Menu("Export") {
                        ForEach(AppModel.ExportFormat.allCases, id: \.self) { format in
                            Button(format.label) { model.export(exported, as: format) }
                        }
                    }
                    .fixedSize()
                    Text("Double-click an entry to open it, or the unadjusted line to change the balance.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Done") { closeWindow() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            } else {
                EmptyState(title: "This account is no longer in the file", message: "")
            }
        }
        .frame(minWidth: 560, minHeight: 260)
    }
}
