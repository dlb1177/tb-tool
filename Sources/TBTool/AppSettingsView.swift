import AppKit
import SwiftUI
import TBCore
import UniformTypeIdentifiers

/// The standard grouping lists kept on this Mac, as the app's settings window edits them. Every
/// change is written straight to the list's file in Application Support.
final class StandardLists: ObservableObject {
    @Published private(set) var lists: [GroupingList] = []
    @Published var selected = GroupingList.standardName
    @Published private(set) var standardChanged = false

    init() { reload() }

    func reload() {
        lists = GroupingLibrary.all()
        standardChanged = GroupingLibrary.isStandardChanged()
        if !lists.contains(where: { $0.name == selected }) { selected = lists.first?.name ?? GroupingList.standardName }
    }

    var current: GroupingList? { lists.first { $0.name == selected } }
    var isBuiltIn: Bool { selected == GroupingList.standardName }

    /// The selected list's groupings as a file would hold them, so the same grouping rules apply.
    var scratch: Engagement { Engagement(name: "", periodEnd: "", groupings: current?.groupings ?? []) }

    private func fail(_ title: String, _ error: Error) {
        AppModel.shared.alert = AlertInfo(title: title, message: error.localizedDescription)
    }

    /// Applies a change to the selected list's groupings and saves it. False (with the reason shown) if it isn't allowed.
    @discardableResult
    func change(_ body: (inout Engagement) throws -> Void) -> Bool {
        guard var list = current else { return false }
        var e = scratch
        do {
            try body(&e)
            list.groupings = e.groupings
            try GroupingLibrary.save(list)
        } catch {
            fail("That change didn't go through", error)
            return false
        }
        reload()
        return true
    }

    func setStandard(_ on: Bool, forEntityType type: String) {
        do {
            try GroupingLibrary.setStandard(on ? selected : nil, forEntityType: type)
        } catch {
            fail("Couldn't save the grouping list", error)
        }
        reload()
    }

    /// Adds a list under a name that isn't taken yet and selects it.
    func add(_ list: GroupingList, named raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        guard !lists.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            AppModel.shared.alert = AlertInfo(title: "There is already a list named “\(name)”", message: "Choose another name, or select that list and change it.")
            return
        }
        do {
            try GroupingLibrary.save(GroupingList(name: name, groupings: Engagement.mergingSharedCodes(list.groupings)))
            selected = name
        } catch {
            fail("Couldn't save the grouping list", error)
        }
        reload()
    }

    func rename(to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard var list = current, !isBuiltIn, !name.isEmpty, name != list.name else { return }
        guard !lists.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.name != list.name }) else {
            AppModel.shared.alert = AlertInfo(title: "There is already a list named “\(name)”", message: "Choose another name.")
            return
        }
        let old = list.name
        list.name = name
        do {
            try GroupingLibrary.save(list)
            if old.caseInsensitiveCompare(name) != .orderedSame { GroupingLibrary.delete(named: old) }
            selected = name
        } catch {
            fail("Couldn't rename the list", error)
        }
        reload()
    }

    /// Deletes the selected list — or, for the built-in list, throws away the changes made to it.
    func deleteSelected() {
        GroupingLibrary.delete(named: selected)
        reload()
    }

    /// Replaces the selected list's groupings with another list's (from a file, or the open trial balance).
    func replaceGroupings(with groupings: [Grouping]) {
        change { $0.groupings = Engagement.mergingSharedCodes(groupings) }
    }
}

/// TB Tool ▸ Settings: what applies to the app rather than to one trial balance file. The
/// standard grouping lists live here — the list each entity type's new files start from — so
/// they can be brought up to date when a form changes.
struct AppSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var closeWindow
    @StateObject private var store = StandardLists()
    @AppStorage("default.firm") private var firm = ""
    @AppStorage("default.preparedBy") private var preparedBy = ""
    @State private var groupingSelection: String?
    @State private var renameText = ""
    @State private var confirmDelete = false
    @AppStorage("settings.tab") private var tab = "groupings"

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Grouping Lists").tag("groupings")
                Text("Binder Layout").tag("binder")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 8)
            Divider()
            if tab == "binder" {
                BinderLayoutSettings()
            } else {
                groupingLists
            }
        }
    }

    private var groupingLists: some View {
        VStack(alignment: .leading, spacing: 0) {
            newFiles
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Text("Standard grouping lists").font(.headline)
                Text("The list a new trial balance file starts with is the one marked as the standard for its entity type. Change a list here when a form changes, or keep one per year. Files you already have keep their own copy; bring one up to date from its Grouping List screen (List ▸ Switch to a Standard List).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            Divider()
            HStack(spacing: 0) {
                listColumn.frame(width: 270)
                Divider()
                detail
            }
            Divider()
            HStack {
                Text("Changes here are saved as you make them. They can't be undone with ⌘Z.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { closeWindow() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 860, minHeight: 560)
        .onChange(of: store.selected) { _, _ in
            groupingSelection = nil
            renameText = store.selected
        }
        .onAppear { renameText = store.selected }
        .confirmationDialog(store.isBuiltIn ? "Put the built-in list back as it shipped?" : "Delete “\(store.selected)”?", isPresented: $confirmDelete) {
            Button(store.isBuiltIn ? "Restore" : "Delete", role: .destructive) { store.deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(store.isBuiltIn ? "The changes made to it on this Mac are discarded. Trial balance files that already use the list are not affected."
                                 : "The list is removed from this Mac. Trial balance files that already use it keep their own copy.")
        }
    }

    // MARK: New files

    private var newFiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New trial balance files").font(.headline)
            HStack(spacing: 14) {
                LabeledContent("Firm") { TextField("", text: $firm).textFieldStyle(.roundedBorder).frame(width: 260) }
                LabeledContent("Prepared by") { TextField("", text: $preparedBy).textFieldStyle(.roundedBorder).frame(width: 160) }
                Spacer()
                HideZeroToggle()
            }
            Text("The firm and preparer are filled in when you set up a new file. Each file's own details are under File ▸ Trial Balance Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    // MARK: Lists

    private var listColumn: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { Optional(store.selected) }, set: { if let name = $0 { store.selected = name } })) {
                ForEach(store.lists, id: \.name) { list in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(list.name).lineLimit(1)
                        Text(caption(list)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .padding(.vertical, 2)
                    .tag(list.name)
                }
            }
            Divider()
            HStack(spacing: 8) {
                Menu {
                    Button("New Empty List…") {
                        if let name = ask("New Grouping List", "Name the list — for example “S Corporation (Form 1120-S)”. Add its groupings on the right, or import them from a file.") {
                            store.add(GroupingList(name: name, groupings: []), named: name)
                        }
                    }
                    Button("Duplicate “\(store.selected)”…") {
                        if let list = store.current, let name = ask("Duplicate List", "Name the copy — for example the same list for another year.", suggestion: "\(list.name) copy") {
                            store.add(list, named: name)
                        }
                    }
                    Button("Import a List from a File…") { importList(replacing: false) }
                    if let e = model.engagement {
                        Button("Add the Open File's List…") {
                            let suggestion = e.groupingListName.isEmpty || e.groupingListName == GroupingList.standardName ? "\(e.name) groupings" : e.groupingListName
                            if let name = ask("Add the Open File's List", "Saves the grouping list of \(e.name) as a standard list.", suggestion: suggestion) {
                                store.add(GroupingList(name: name, groupings: e.groupings), named: name)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Add a standard list")
                Button {
                    confirmDelete = true
                } label: {
                    Image(systemName: store.isBuiltIn ? "arrow.uturn.backward" : "minus")
                }
                .buttonStyle(.borderless)
                .disabled(store.isBuiltIn && !store.standardChanged)
                .help(store.isBuiltIn ? "Put the built-in list back as it shipped" : "Delete this list")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    private func caption(_ list: GroupingList) -> String {
        let n = list.groupings.filter { $0.parent == nil }.count
        var parts = ["\(n) grouping\(n == 1 ? "" : "s")"]
        if list.name == GroupingList.standardName { parts.append(store.standardChanged ? "built in, changed" : "built in") }
        if !list.entityTypes.isEmpty { parts.append("standard for " + list.entityTypes.map(short).joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }

    /// "S Corporation (Form 1120-S)" → "S Corporation"
    private func short(_ type: String) -> String {
        String(type.split(separator: "(")[0]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: The selected list

    @ViewBuilder
    private var detail: some View {
        if let list = store.current {
            let e = store.scratch
            let rows = e.groupingOutline
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if store.isBuiltIn {
                            Text(list.name).font(.title3.bold())
                            Text(store.standardChanged ? "Built in — changed on this Mac" : "Built in").font(.callout).foregroundStyle(.secondary)
                        } else {
                            TextField("List name", text: $renameText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: 360)
                                .onSubmit { store.rename(to: renameText) }
                            if renameText.trimmingCharacters(in: .whitespaces) != list.name {
                                Button("Rename") { store.rename(to: renameText) }
                            }
                        }
                        Spacer()
                        Menu("Import / Export") {
                            Button("Replace This List's Groupings from a File…") { importList(replacing: true) }
                            if let open = model.engagement {
                                Button("Replace with the Open File's List (\(open.name))") { store.replaceGroupings(with: open.groupings) }
                            }
                            Divider()
                            Button("Export This List (JSON)…") { export(list, csv: false) }
                            Button("Export This List (CSV)…") { export(list, csv: true) }
                        }
                        .fixedSize()
                    }
                    HStack(spacing: 8) {
                        Text("Standard for")
                        Menu {
                            ForEach(Binder.entityTypes, id: \.self) { type in
                                Toggle(type, isOn: Binding(get: { list.entityTypes.contains(type) }, set: { store.setStandard($0, forEntityType: type) }))
                            }
                        } label: {
                            Text(list.entityTypes.isEmpty ? "No entity type" : list.entityTypes.map(short).joined(separator: ", "))
                        }
                        .fixedSize()
                        .help("New files of these entity types start with this list. An entity type has one standard list; types with none use the built-in list.")
                        Spacer()
                        Button("Edit") { edit(groupingSelection, in: e) }
                            .disabled(groupingSelection == nil)
                        Button("Delete", role: .destructive) {
                            if let id = groupingSelection {
                                store.change { $0.deleteGrouping(id) }
                                groupingSelection = nil
                            }
                        }
                        .disabled(groupingSelection == nil)
                        Button {
                            guard let g = e.grouping(groupingSelection) else { return }
                            let parent = e.parentGrouping(of: g) ?? g
                            open(GroupingDraft(groupingID: nil, code: "", name: "", section: parent.section, parent: parent.id), in: e)
                        } label: {
                            Label("New Subgroup", systemImage: "arrow.turn.down.right")
                        }
                        .disabled(groupingSelection == nil)
                        Button {
                            open(GroupingDraft(groupingID: nil, code: "", name: "", section: e.grouping(groupingSelection)?.section ?? e.groupingSections.first ?? ""), in: e)
                        } label: {
                            Label("New Grouping", systemImage: "plus")
                        }
                    }
                }
                .padding(12)
                Divider()
                if rows.isEmpty {
                    EmptyState(title: "No groupings yet", message: "Add groupings with New Grouping, or bring a list in with Import / Export ▸ Replace This List's Groupings from a File.")
                } else {
                    Table(rows.map { OutlineRow(grouping: $0.grouping, depth: $0.depth) }, selection: $groupingSelection) {
                        TableColumn("Section") { r in Text(r.depth == 0 ? r.grouping.section : "").foregroundStyle(.secondary) }
                            .width(min: 110, ideal: 150, max: 220)
                        TableColumn("Code") { r in
                            Text(r.grouping.code.isEmpty ? e.groupingCode(r.grouping.id) : r.grouping.code)
                                .fontWeight(r.depth == 0 ? .medium : .regular)
                                .monospacedDigit()
                                .foregroundStyle(r.grouping.code.isEmpty ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.primary)
                        }
                        .width(min: 60, ideal: 80, max: 110)
                        TableColumn("Name") { r in
                            HStack(spacing: 5) {
                                if r.depth > 0 { Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.secondary) }
                                Text(r.grouping.name)
                            }
                            .padding(.leading, r.depth > 0 ? 14 : 0)
                        }
                        .width(min: 200, ideal: 320)
                        TableColumn("Account Type") { r in
                            Text(e.groupingType(r.id)?.label ?? "Any")
                                .foregroundStyle(r.depth == 0 && r.grouping.type != nil ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.tertiary)
                        }
                        .width(min: 80, ideal: 100, max: 130)
                    }
                    .contextMenu(forSelectionType: String.self) { _ in EmptyView() } primaryAction: { ids in
                        edit(ids.first, in: e)
                    }
                }
            }
        } else {
            EmptyState(title: "No list selected", message: "")
        }
    }

    private struct OutlineRow: Identifiable {
        let grouping: Grouping
        let depth: Int
        var id: String { grouping.id }
    }

    private func edit(_ id: String?, in e: Engagement) {
        if let g = e.grouping(id) { open(GroupingDraft(g), in: e) }
    }

    /// The same grouping window the Grouping List screen uses, pointed at this standard list.
    private func open(_ draft: GroupingDraft, in e: Engagement) {
        let store = store
        model.showGroupingEditor(draft, sections: e.groupingSections, key: "standard-grouping", source: { store.scratch }) { d in
            store.change { e in
                if let id = d.groupingID {
                    try e.updateGrouping(id, code: d.code, name: d.name, section: d.section, parent: d.parent, type: d.type)
                } else {
                    _ = try e.addGrouping(code: d.code, name: d.name, section: d.section, parent: d.parent, type: d.type)
                }
            }
        }
    }

    // MARK: Files and prompts

    private func ask(_ title: String, _ message: String, suggestion: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = suggestion
        field.placeholderString = "List name"
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private func importList(replacing: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = (["json"] + SourceReader.fileExtensions).compactMap { UTType(filenameExtension: $0) }
        panel.directoryURL = model.folder
        panel.message = "Choose a grouping list export, a trial balance file, or a sheet with Section, Code and Name columns"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let list = try GroupingTransfer.read(url: url)
            if replacing {
                store.replaceGroupings(with: list.groupings)
            } else if let name = ask("Import as a Standard List", "\(list.groupings.count) groupings and subgroups read from \(url.lastPathComponent).", suggestion: list.name) {
                store.add(list, named: name)
            }
        } catch {
            model.alert = AlertInfo(title: "Couldn't read \(url.lastPathComponent)", message: error.localizedDescription)
        }
    }

    private func export(_ list: GroupingList, csv: Bool) {
        let panel = NSSavePanel()
        panel.directoryURL = model.folder
        panel.nameFieldStringValue = "\(list.name.replacingOccurrences(of: "/", with: "-")).\(csv ? "csv" : "json")"
        if let type = UTType(filenameExtension: csv ? "csv" : "json") { panel.allowedContentTypes = [type] }
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (csv ? Data(GroupingTransfer.csv(list).utf8) : GroupingTransfer.json(list)).write(to: url, options: .atomic)
            model.reveal(url)
        } catch {
            model.alert = AlertInfo(title: "Export failed", message: error.localizedDescription)
        }
    }
}
