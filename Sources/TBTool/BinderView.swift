import AppKit
import QuickLook
import QuickLookUI
import SwiftUI
import TBCore
import UniformTypeIdentifiers

/// Which files the Binder screen shows, by how far they have been signed off.
enum BinderStatus: String, CaseIterable {
    case any, notPrepared, prepared, notReviewed, reviewed, notSecond, second, changed

    var label: String {
        switch self {
        case .any: return "Any Status"
        case .notPrepared: return "Not Prepared"
        case .prepared: return "Prepared"
        case .notReviewed: return "Not Reviewed"
        case .reviewed: return "Reviewed"
        case .notSecond: return "Not Second Reviewed"
        case .second: return "Second Reviewed"
        case .changed: return "Changed Since Sign-off"
        }
    }
}

/// What the Binder screen remembers while it is open: what is selected, the file being
/// previewed, what is being searched for, and where a dragged file is hovering.
final class BinderScreen: ObservableObject {
    @Published var selection: Set<String> = []
    /// The row last clicked: where a Shift-click's range starts, and what Space previews.
    @Published var anchor: String?
    @Published var preview: URL?
    @Published var hover: BinderDrop?
    @Published var hoverBackground = false
    @Published var onlyProblems = false
    @Published var query = ""
    @Published var status = BinderStatus.any
    @Published var sort: GridSort?
    var monitor: Any?

    var filtering: Bool { onlyProblems || status != .any || !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The one item to act on when an action takes one: the row last clicked, if it is selected.
    var primary: String? {
        if let anchor, selection.contains(anchor) { return anchor }
        return selection.count == 1 ? selection.first : nil
    }

    func select(_ path: String?) {
        selection = path.map { [$0] } ?? []
        anchor = path
    }

    /// Whether a file passes the search box and the status menu.
    func matches(_ item: BinderItem, e: Engagement?, stale: Set<String>, problems: Set<String>) -> Bool {
        if onlyProblems && !problems.contains(item.path) { return false }
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        if !terms.isEmpty {
            let text = item.path.lowercased()
            if !terms.allSatisfy({ text.contains($0) }) { return false }
        }
        guard status != .any else { return true }
        guard !item.isFolder, !item.isPlaceholder else { return false }
        func has(_ level: SignOffLevel) -> Bool { e?.signOff(level, for: item.path) != nil }
        switch status {
        case .any: return true
        case .notPrepared: return !has(.prepared)
        case .prepared: return has(.prepared)
        case .notReviewed: return !has(.reviewed)
        case .reviewed: return has(.reviewed)
        case .notSecond: return !has(.secondReviewed)
        case .second: return has(.secondReviewed)
        case .changed: return SignOffLevel.allCases.contains { stale.contains(AppModel.signOffKey(item.path, $0)) }
        }
    }

    /// The rows of the nested view. While searching or filtering: the files that pass, each
    /// under the folders it is in. Otherwise everything, less what sits inside a closed folder.
    func rows(_ tree: BinderTree, collapsed: Set<String>, e: Engagement?, stale: Set<String>, problems: Set<String>) -> [BinderItem] {
        if filtering {
            let hits = tree.all.filter { (status == .any || !$0.isFolder) && matches($0, e: e, stale: stale, problems: problems) }
            var keep = Set(hits.map(\.path))
            for item in hits {
                var parent = item.parentPath
                while !parent.isEmpty {
                    keep.insert(parent)
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
            return tree.all.filter { keep.contains($0.path) }
        }
        guard !collapsed.isEmpty else { return tree.all }
        return tree.all.filter { item in
            var parent = item.parentPath
            while !parent.isEmpty {
                if collapsed.contains(parent) { return false }
                parent = (parent as NSString).deletingLastPathComponent
            }
            return true
        }
    }
}

/// The whole binder for the year: every folder and file with its index. Files are brought in,
/// moved, renumbered, previewed, opened, signed off and removed here instead of in Finder. It
/// can be seen as folders opened out, or as one flat list of every file.
struct BinderView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var screen = BinderScreen()
    @AppStorage("binder.flat") private var flat = false

    static let rowHeight: CGFloat = 25

    private func problems(_ tree: BinderTree) -> Set<String> {
        Set(tree.duplicateIndexes.flatMap { $0.items.map(\.path) }).union(tree.unindexed.map(\.path)).union(tree.unfiled.map(\.path))
            .union(model.staleSignOffs.map { $0.components(separatedBy: "\u{1F}")[0] })
    }

    var body: some View {
        VStack(spacing: 0) {
            if let tree = model.binder {
                let duplicates = Set(tree.duplicateIndexes.flatMap { $0.items.map(\.path) })
                let flagged = problems(tree)
                let picked = screen.selection.compactMap { tree.item($0) }
                let one = screen.primary.flatMap { tree.item($0) }
                PageHeader(title: "Binder", subtitle: subtitle(tree)) {
                    Menu {
                        Button("New Folder…") { model.newBinderFolder(in: "") }
                        if let one, one.isFolder {
                            Button("New Folder in “\(one.title)”…") { model.newBinderFolder(in: one.path) }
                        }
                        Button("New Placeholder…") { if let home = home(one) { model.newPlaceholder(in: home) } }
                            .disabled(home(one) == nil)
                        Divider()
                        Button("Add the Standard Folders to This Binder…") { model.makeStandardFolders(elsewhere: false) }
                        Button("Make the Standard Folders in Another Folder…") { model.makeStandardFolders(elsewhere: true) }
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    .fixedSize()
                    .help("A folder, a subfolder, a placeholder, or the standard set of binder folders")
                    Menu {
                        Button("Set Index…") { if let one { model.showSetIndex(for: one.path) } }
                            .disabled(one == nil || (one.map { !$0.isFolder && $0.parentPath.isEmpty } ?? true))
                        Button(picked.count > 1 ? "Index the \(picked.count) Selected Files" : "Index the Selected File") {
                            model.applyBinderRenames(BinderIndexer.index(screen.selection, in: tree), actionName: "Index Files")
                        }
                        .disabled(BinderIndexer.index(screen.selection, in: tree).isEmpty)
                        if let one, one.index != nil {
                            Button("Remove the Index from “\(one.displayTitle)”") {
                                model.applyBinderRenames(BinderIndexer.removeIndex(from: one.path, in: tree), actionName: "Remove Index")
                            }
                        }
                        Divider()
                        if let folder = folder(one, tree) {
                            Button("Close the Gaps in “\(folder.title)”") {
                                model.applyBinderRenames(BinderIndexer.closeGaps(in: folder.path, tree: tree), actionName: "Close Gaps")
                            }
                            .disabled(BinderIndexer.closeGaps(in: folder.path, tree: tree).isEmpty)
                            Button("Index the Unindexed Files in “\(folder.title)”") {
                                model.applyBinderRenames(BinderIndexer.indexUnindexed(under: folder.path, in: tree), actionName: "Index Files")
                            }
                            .disabled(BinderIndexer.indexUnindexed(under: folder.path, in: tree).isEmpty)
                        }
                        Button("Index Every Unindexed File in the Binder") {
                            model.applyBinderRenames(BinderIndexer.indexUnindexed(under: "", in: tree), actionName: "Index Files")
                        }
                        .disabled(BinderIndexer.indexUnindexed(under: "", in: tree).isEmpty)
                    } label: {
                        Label("Index", systemImage: "number")
                    }
                    .fixedSize()
                    .help("Give the selection index numbers, or renumber a folder to close its gaps")
                    Button("Open") { model.openBinderItems(screen.selection) }
                        .disabled(picked.isEmpty)
                        .help("Open what is selected (⌘O)")
                    Button {
                        if let one, !one.isFolder { screen.preview = tree.url(one) }
                    } label: {
                        Label("Preview", systemImage: "eye")
                    }
                    .disabled(one == nil || one?.isFolder == true)
                    .help("Look at the selected file without opening it. Or press Space.")
                    Button {
                        model.trashBinderItems(screen.selection)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(picked.isEmpty)
                    .help("Move what is selected to the Trash (⌘⌫)")
                    Button {
                        model.refreshBinder()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Read the folder again. It is also read whenever you come back to TB Tool.")
                    Button("Show in Finder") { model.reveal(one.map { tree.url($0) } ?? tree.root) }
                }
                Divider()
                bar(tree)
                Divider()
                alerts(tree)
                if tree.isEmpty {
                    VStack(spacing: 10) {
                        EmptyState(title: "Nothing in the binder yet",
                                   message: "The binder is the folder this trial balance is in. Make the standard folders, or drop folders and files here.",
                                   button: "Make the Standard Folders") { model.makeStandardFolders(elsewhere: false) }
                            .frame(maxHeight: 180)
                        Spacer()
                    }
                    .padding(.top, 60)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onDrop(of: [.fileURL], isTargeted: $screen.hoverBackground) { providers in
                        load(providers) { urls in dropped(urls, nil, tree) }
                        return true
                    }
                } else if flat {
                    flatList(tree, flagged: flagged)
                } else {
                    let rows = screen.rows(tree, collapsed: model.collapsedFolders, e: model.engagement, stale: model.staleSignOffs, problems: flagged)
                    if rows.isEmpty {
                        EmptyState(title: "No files match", message: "Nothing in the binder passes the search and the status chosen above.")
                    } else {
                        list(rows, tree: tree, duplicates: duplicates)
                    }
                }
            } else {
                PageHeader(title: "Binder", subtitle: "") {
                    Button("Make the Standard Folders in a Folder…") { model.makeStandardFolders(elsewhere: true) }
                }
                Divider()
                EmptyState(title: "This folder isn't being treated as a binder",
                           message: "The binder is the folder the trial balance file is in — one folder per client per year. This file sits in a general folder (your home folder, Desktop, Documents or Downloads), so what is beside it isn't read as workpapers. Move the file into the year's folder for this client.")
            }
        }
        .quickLookPreview($screen.preview, in: model.binder.map { tree in tree.files.map { tree.url($0) } } ?? [])
        .onChange(of: screen.preview) { _, url in
            // Arrowing through files in the preview moves the selection along with it.
            guard let url, let tree = model.binder else { return }
            let root = tree.root.resolvingSymlinksInPath().path, path = url.resolvingSymlinksInPath().path
            if path.hasPrefix(root + "/") {
                let relative = String(path.dropFirst(root.count + 1))
                if screen.primary != relative { screen.select(relative) }
            }
        }
        .onChange(of: model.binder) { _, tree in
            // What was renamed or removed is no longer selected.
            let here = Set(tree?.all.map(\.path) ?? [])
            if !screen.selection.isSubset(of: here) { screen.selection.formIntersection(here) }
        }
        .onAppear {
            model.refreshBinder()
            installKeys()
        }
        .onDisappear {
            if let m = screen.monitor { NSEvent.removeMonitor(m) }
            screen.monitor = nil
            screen.preview = nil
        }
    }

    /// The folder a new placeholder goes in: the selected folder, or the folder the selected file is in.
    private func home(_ item: BinderItem?) -> String? {
        guard let item else { return nil }
        if item.isFolder { return item.path }
        return item.parentPath.isEmpty ? nil : item.parentPath
    }

    private func folder(_ item: BinderItem?, _ tree: BinderTree) -> BinderItem? {
        home(item).flatMap { tree.item($0) }
    }

    private func subtitle(_ tree: BinderTree) -> String {
        let files = tree.files.count, folders = tree.folders.count
        return "\(model.displayPath(tree.root)) · \(folders) folder\(folders == 1 ? "" : "s"), \(files) file\(files == 1 ? "" : "s")"
            + (tree.truncated ? " · too large to read in full" : "")
    }

    /// The strip under the header: the two views, opening and closing folders, the search box
    /// and the status menu.
    private func bar(_ tree: BinderTree) -> some View {
        let signed = Set(model.engagement?.signOffs.map(\.path) ?? []).count
        return HStack(spacing: 10) {
            Picker("", selection: $flat) {
                Text("Folders").tag(false)
                Text("All Files").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Folders opened out, or every file in one flat list with its folder beside it")
            if !flat {
                Button {
                    model.collapsedFolders = []
                } label: {
                    Label("Expand All", systemImage: "chevron.down.2")
                }
                .disabled(model.collapsedFolders.isEmpty || screen.filtering)
                Button {
                    model.collapsedFolders = Set(tree.folders.map(\.path))
                } label: {
                    Label("Collapse All", systemImage: "chevron.right.2")
                }
                .disabled(tree.folders.isEmpty || screen.filtering)
            }
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search files — index, name, folder…", text: $screen.query)
                    .textFieldStyle(.plain)
                if !screen.query.isEmpty {
                    Button {
                        screen.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .frame(maxWidth: 280)
            Picker("", selection: $screen.status) {
                ForEach(BinderStatus.allCases, id: \.self) { s in
                    Text(s.label).tag(s)
                    if s == .any || s == .second { Divider() }
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Show only the files at this point of sign-off")
            Toggle("Needs attention", isOn: $screen.onlyProblems)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help("Only loose files, items with no index, numbers used twice, and workpapers changed since sign-off")
            Spacer(minLength: 4)
            if screen.selection.count > 1 { Text("\(screen.selection.count) selected").foregroundStyle(.secondary) }
            Text("\(signed) signed off")
                .foregroundStyle(.secondary)
                .help("P is prepared, R is reviewed, 2R is second reviewed. Click a mark on a file to sign it off as yourself.")
        }
        .font(.system(size: 11.5))
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func alerts(_ tree: BinderTree) -> some View {
        let lines = model.binderAlerts
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(lines, id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color.orange.opacity(0.08))
            Divider()
        }
    }

    // MARK: Every file in one list

    private func flatList(_ tree: BinderTree, flagged: Set<String>) -> some View {
        let e = model.engagement
        let files = tree.files.filter { screen.matches($0, e: e, stale: model.staleSignOffs, problems: flagged) }
        var table = ReportTable(title: "Binder", subtitle: "", sheetName: "Binder", flat: true,
                                columns: [.text("Index", 70), .text("File", 280), .text("Folder", 260)]
                                    + SignOffLevel.allCases.map { .text($0.label, 110) } + [.text("Tags", 120)])
        for item in files {
            var cells: [ReportCell] = [.text(item.index?.text ?? (item.parentPath.isEmpty ? "not filed" : "")),
                                       .text(item.isPlaceholder ? "\(item.displayTitle) (placeholder)" : item.title),
                                       .text(item.parentPath)]
            for level in SignOffLevel.allCases {
                if let mark = e?.signOff(level, for: item.path) {
                    let stale = model.staleSignOffs.contains(AppModel.signOffKey(item.path, level))
                    cells.append(.text("\(SignOffMark.initials(mark.actor.display)) \(Stamp.day(mark.at))" + (stale ? " — changed since" : "")))
                } else {
                    cells.append(.empty)
                }
            }
            cells.append(.text(item.tags.joined(separator: ", ")))
            table.rows.append(ReportRow(id: item.path, cells: cells))
        }
        let shown = screen.sort.map { table.sorted(by: $0.column, ascending: $0.ascending) } ?? table
        return VStack(spacing: 0) {
            if files.isEmpty {
                EmptyState(title: "No files match", message: "Nothing in the binder passes the search and the status chosen above.")
            } else {
                DataGrid(table: shown, key: "binder.flat", sort: $screen.sort, onActivate: { row in
                    if let item = tree.item(row.id) { NSWorkspace.shared.open(tree.url(item)) }
                }, selected: screen.selection, onSelect: { ids in
                    if screen.selection != ids {
                        screen.selection = ids
                        if !ids.contains(screen.anchor ?? "") { screen.anchor = ids.count == 1 ? ids.first : nil }
                    }
                }, menu: { ids in flatMenu(ids, tree) })
            }
        }
    }

    private func flatMenu(_ ids: Set<String>, _ tree: BinderTree) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let items = ids.compactMap { tree.item($0) }
        let one = items.count == 1 ? items[0] : nil
        menu.addItem(ActionItem(items.count > 1 ? "Open \(items.count) Files" : "Open", enabled: !items.isEmpty) { model.openBinderItems(ids) })
        if let one {
            menu.addItem(ActionItem("Preview") {
                screen.select(one.path)
                screen.preview = tree.url(one)
            })
            menu.addItem(ActionItem("Show in Finder") { model.reveal(tree.url(one)) })
            menu.addItem(.separator())
            menu.addItem(ActionItem(one.index == nil ? "Set Index…" : "Change Index…", enabled: !one.parentPath.isEmpty) { model.showSetIndex(for: one.path) })
            menu.addItem(ActionItem("Rename…") { model.renameBinderItem(one.path) })
        } else {
            menu.addItem(.separator())
        }
        let renames = BinderIndexer.index(ids, in: tree)
        if !renames.isEmpty {
            menu.addItem(ActionItem(renames.count > 1 ? "Index the \(renames.count) Unindexed Files" : "Index This File") {
                model.applyBinderRenames(renames, actionName: "Index Files")
            })
        }
        menu.addItem(.separator())
        for level in SignOffLevel.allCases {
            if let one, model.engagement?.signOff(level, for: one.path) != nil {
                menu.addItem(ActionItem("Remove the “\(level.label)” Mark…") { model.toggleSignOff(level, on: one.path) })
            } else {
                menu.addItem(ActionItem("Mark as \(level.label)", enabled: items.contains { !$0.isPlaceholder }) { model.markSignOff(level, on: ids) })
            }
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Move to Trash", enabled: !items.isEmpty) { model.trashBinderItems(ids) })
        return menu
    }

    // MARK: The folders opened out

    private func list(_ rows: [BinderItem], tree: BinderTree, duplicates: Set<String>) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.path) { n, item in
                        rowView(item, tree: tree, rows: rows, duplicate: duplicates.contains(item.path), stripe: n % 2 == 1)
                            .id(item.path)
                    }
                }
                .padding(.vertical, 4)
                // Below the last row: files dropped there go into the binder folder itself.
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .contentShape(Rectangle())
                    .onTapGesture { screen.select(nil) }
                    .onDrop(of: [.fileURL], isTargeted: $screen.hoverBackground) { providers in
                        load(providers) { urls in dropped(urls, nil, tree) }
                        return true
                    }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2).opacity(screen.hoverBackground ? 1 : 0).padding(2))
            .onChange(of: screen.anchor) { _, path in
                if let path { proxy.scrollTo(path) }
            }
        }
    }

    /// A click selects; ⌘-click adds or removes one; ⇧-click takes everything from the last
    /// click to this one.
    private func clicked(_ item: BinderItem, in rows: [BinderItem]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if screen.selection.contains(item.path) { screen.selection.remove(item.path) } else { screen.selection.insert(item.path) }
            screen.anchor = item.path
        } else if flags.contains(.shift), let from = screen.anchor, let a = rows.firstIndex(where: { $0.path == from }),
                  let b = rows.firstIndex(where: { $0.path == item.path }) {
            screen.selection = Set(rows[min(a, b)...max(a, b)].map(\.path))
        } else {
            screen.select(item.path)
        }
    }

    private func rowView(_ item: BinderItem, tree: BinderTree, rows: [BinderItem], duplicate: Bool, stripe: Bool) -> some View {
        let loose = !item.isFolder && item.parentPath.isEmpty
        let selected = screen.selection.contains(item.path)
        let closed = model.collapsedFolders.contains(item.path) && !screen.filtering
        let hover = screen.hover?.target == item.path ? screen.hover : nil
        let primary: Color = selected ? .white : .primary
        let secondary: Color = selected ? .white.opacity(0.8) : .secondary
        let row = HStack(spacing: 8) {
            // A folder opens and closes on its arrow.
            Group {
                if item.isFolder {
                    Button {
                        toggle(item.path)
                    } label: {
                        Image(systemName: closed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(secondary)
                            .frame(width: 14, height: Self.rowHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(screen.filtering)
                    .help(closed ? "Open this folder" : "Close this folder")
                } else {
                    Color.clear.frame(width: 14)
                }
            }
            .padding(.leading, CGFloat(item.depth) * 18)
            Group {
                if let index = item.index {
                    Text(index.text)
                        .monospacedDigit()
                        .fontWeight(item.isFolder ? .semibold : .regular)
                        .foregroundStyle(duplicate ? Color.orange : primary)
                } else {
                    Text(loose ? "not filed" : "no index").foregroundStyle(selected ? Color.white : Color.orange)
                }
            }
            .frame(width: 70, alignment: .leading)
            Image(systemName: item.isFolder ? "folder.fill" : (item.isPlaceholder ? "doc.badge.ellipsis" : "doc"))
                .foregroundStyle(selected ? Color.white : (item.isFolder ? Color.accentColor : Color.secondary))
                .frame(width: 18)
            Text(item.displayTitle)
                .fontWeight(item.isFolder ? .semibold : .regular)
                .foregroundStyle(item.isPlaceholder ? secondary : primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if item.isFolder && closed {
                let inside = item.children.count
                Text("\(inside) item\(inside == 1 ? "" : "s")").font(.caption).foregroundStyle(secondary)
            }
            if item.isPlaceholder {
                Text("placeholder").font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(selected ? Color.white.opacity(0.2) : Color.primary.opacity(0.08)))
                    .foregroundStyle(primary)
                    .help("A stand-in for a document that hasn't arrived. Drag the document onto it when it does.")
            }
            if duplicate {
                Text("number used twice").font(.caption).foregroundStyle(selected ? Color.white : Color.orange)
            }
            Spacer(minLength: 8)
            if !item.tags.isEmpty {
                Text(item.tags.joined(separator: ", ")).font(.caption).foregroundStyle(secondary).lineLimit(1)
                    .help("Finder tags")
            }
            if !item.isFolder && !item.isPlaceholder {
                HStack(spacing: 4) {
                    ForEach(SignOffLevel.allCases, id: \.self) { level in
                        SignOffMark(path: item.path, level: level, selected: selected)
                    }
                }
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.rowHeight)
        .background(selected ? Color.accentColor : (stripe ? Color.primary.opacity(0.03) : Color.clear))
        .overlay(alignment: .top) { dropLine(hover.map { $0 == .before(item.path) } ?? false, depth: item.depth) }
        .overlay(alignment: .bottom) { dropLine(hover.map { $0 == .after(item.path) } ?? false, depth: item.depth) }
        .overlay {
            if hover == .onto(item.path) {
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.18))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 1.5))
                    .padding(.horizontal, 4)
            }
        }
        .contentShape(Rectangle())
        .gesture(TapGesture().onEnded { clicked(item, in: rows) })
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if item.isFolder { toggle(item.path) } else { NSWorkspace.shared.open(tree.url(item)) }
        })
        .contextMenu { menu(item, tree) }
        .onDrop(of: [.fileURL], delegate: BinderRowDrop(item: item, height: Self.rowHeight, hover: $screen.hover) { providers, drop in
            load(providers) { urls in dropped(urls, drop, tree) }
        })
        return Group {
            if item.isFolder {
                row
            } else {
                // A file can be dragged to a new place in the list.
                row.onDrag {
                    if !screen.selection.contains(item.path) { screen.select(item.path) }
                    return NSItemProvider(object: tree.url(item) as NSURL)
                }
            }
        }
    }

    private func dropLine(_ on: Bool, depth: Int) -> some View {
        Rectangle().fill(Color.accentColor).frame(height: 2.5)
            .padding(.leading, 12 + CGFloat(depth) * 18)
            .padding(.trailing, 12)
            .opacity(on ? 1 : 0)
    }

    private func toggle(_ path: String) {
        if model.collapsedFolders.contains(path) { model.collapsedFolders.remove(path) } else { model.collapsedFolders.insert(path) }
    }

    // MARK: Dropping

    private func load(_ providers: [NSItemProvider], then: @escaping ([URL]) -> Void) {
        var urls: [URL?] = Array(repeating: nil, count: providers.count)
        let group = DispatchGroup()
        for (i, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    urls[i] = url
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { then(urls.compactMap { $0 }) }
    }

    /// A file from the binder itself is being moved. If only it has to be renamed (it lands on
    /// a free number, or is filed in a folder) that is simply done; if other files have to be
    /// renumbered, the move is shown first. Files from anywhere else are being added: one is
    /// asked about, several come in unindexed, to be numbered afterwards.
    private func dropped(_ urls: [URL], _ drop: BinderDrop?, _ tree: BinderTree) {
        let root = tree.root.resolvingSymlinksInPath().path
        func inside(_ u: URL) -> String? {
            let p = u.resolvingSymlinksInPath().path
            return p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : nil
        }
        let outside = urls.filter { inside($0) == nil }
        let target = drop.flatMap { tree.item($0.target) }
        if outside.isEmpty {
            guard let drop, let target, let path = urls.first.flatMap(inside) else { return }
            if target.isPlaceholder && drop == .onto(target.path) && path != target.path {
                model.showReplacePlaceholder(.inside(path), placeholder: target.path)
                return
            }
            let renames = BinderIndexer.move(path, drop, in: tree)
            if renames.isEmpty {
                model.status = "Nothing to move: “\((path as NSString).lastPathComponent)” is already there."
            } else if renames.count == 1 && renames[0].from == path {
                model.applyBinderMove(renames)
            } else {
                model.showBinderMove(path, drop)
            }
            return
        }
        let folderPath = target.map { $0.isFolder ? $0.path : $0.parentPath } ?? ""
        if outside.count > 1 {
            // Several at once: they come in as they are, to be selected and indexed afterwards.
            if model.addToBinder(outside, folderPath: folderPath, start: nil, copy: UserDefaults.standard.bool(forKey: "binder.addCopies")), !folderPath.isEmpty {
                let names = Set(outside.map { folderPath + "/" + $0.lastPathComponent })
                screen.selection = names
                screen.anchor = nil
                model.status = "Added \(outside.count) files without an index. They are selected: choose Index ▸ Index the Selected Files to number them."
            }
            return
        }
        if let drop, let target, target.isPlaceholder, drop == .onto(target.path) {
            model.showReplacePlaceholder(.outside(outside[0]), placeholder: target.path)
            return
        }
        // Let go between two files with a number free between them: that number is the offer.
        var at: BinderIndex?
        var free = false
        if let drop, let target, !target.isFolder, let index = target.index, let suffix = index.suffix {
            if let gap = BinderIndexer.freeIndex(at: drop, in: tree) {
                at = gap
                free = true
            } else if drop == .before(target.path) {
                at = index
            } else if drop == .after(target.path) {
                at = BinderIndex(prefix: index.prefix, suffix: suffix + 1, width: index.width)
            }
        }
        model.showAddToBinder(outside, folderPath: folderPath, suggested: at, preferSuggested: free)
    }

    // MARK: Keys

    /// Space previews the selected file (and closes the preview), the arrows move through the
    /// list, ← → close and open a folder, ⌘O opens and ⌘⌫ moves to the Trash — as in Finder.
    private func installKeys() {
        guard screen.monitor == nil else { return }
        screen.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak screen, weak model] event in
            guard let screen, let model, model.selection == .binder, let tree = model.binder else { return event }
            let inPreview = event.window is QLPreviewPanel
            let inMain = event.window?.identifier?.rawValue.hasPrefix("main") ?? false
            guard inPreview || (inMain && !(event.window?.firstResponder is NSText)) else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let isFlat = UserDefaults.standard.bool(forKey: "binder.flat")
            if flags == .command {
                switch event.keyCode {
                case 31 where !screen.selection.isEmpty: // ⌘O
                    model.openBinderItems(screen.selection)
                    return nil
                case 51 where !screen.selection.isEmpty: // ⌘⌫
                    model.trashBinderItems(screen.selection)
                    return nil
                case 0 where !isFlat: // ⌘A
                    screen.selection = Set(tree.all.map(\.path))
                    return nil
                default: return event
                }
            }
            guard flags.isEmpty || flags == .shift else { return event }
            let flagged = Set(tree.duplicateIndexes.flatMap { $0.items.map(\.path) }).union(tree.unindexed.map(\.path)).union(tree.unfiled.map(\.path))
                .union(model.staleSignOffs.map { $0.components(separatedBy: "\u{1F}")[0] })
            let rows = isFlat ? tree.files : screen.rows(tree, collapsed: model.collapsedFolders, e: model.engagement, stale: model.staleSignOffs, problems: flagged)
            let at = screen.primary.flatMap { s in rows.firstIndex { $0.path == s } }
            func go(_ item: BinderItem) {
                if flags == .shift { screen.selection.insert(item.path) } else { screen.selection = [item.path] }
                screen.anchor = item.path
                if screen.preview != nil, !item.isFolder { screen.preview = tree.url(item) }
            }
            switch event.keyCode {
            case 49: // Space
                if screen.preview != nil {
                    screen.preview = nil
                } else if let item = screen.primary.flatMap({ tree.item($0) }), !item.isFolder {
                    screen.preview = tree.url(item)
                } else {
                    return event
                }
                return nil
            case 125 where !isFlat || inPreview: // ↓
                guard !rows.isEmpty else { return event }
                go(rows[min((at ?? -1) + 1, rows.count - 1)])
                return nil
            case 126 where !isFlat || inPreview: // ↑
                guard !rows.isEmpty else { return event }
                go(rows[max((at ?? 1) - 1, 0)])
                return nil
            case 123 where !isFlat: // ←
                guard !inPreview, let item = screen.primary.flatMap({ tree.item($0) }) else { return event }
                if item.isFolder && !model.collapsedFolders.contains(item.path) {
                    model.collapsedFolders.insert(item.path)
                } else if !item.parentPath.isEmpty {
                    screen.select(item.parentPath)
                }
                return nil
            case 124 where !isFlat: // →
                guard !inPreview, let item = screen.primary.flatMap({ tree.item($0) }), item.isFolder else { return event }
                model.collapsedFolders.remove(item.path)
                return nil
            default:
                return event
            }
        }
    }

    // MARK: The menu on a row

    @ViewBuilder
    private func menu(_ item: BinderItem, _ tree: BinderTree) -> some View {
        // A right-click on one of several selected rows is about all of them.
        let several = screen.selection.contains(item.path) && screen.selection.count > 1
        if several {
            let ids = screen.selection
            let renames = BinderIndexer.index(ids, in: tree)
            Button("Open \(ids.count) Items") { model.openBinderItems(ids) }
            Divider()
            Button(renames.isEmpty ? "Index the Selected Files" : "Index the \(renames.count) Unindexed File\(renames.count == 1 ? "" : "s")") {
                model.applyBinderRenames(renames, actionName: "Index Files")
            }
            .disabled(renames.isEmpty)
            Divider()
            ForEach(SignOffLevel.allCases, id: \.self) { level in
                Button("Mark as \(level.label)") { model.markSignOff(level, on: ids) }
            }
            Divider()
            Button("Move \(ids.count) Items to Trash") { model.trashBinderItems(ids) }
        } else {
            single(item, tree)
        }
    }

    @ViewBuilder
    private func single(_ item: BinderItem, _ tree: BinderTree) -> some View {
        let loose = !item.isFolder && item.parentPath.isEmpty
        if !item.isFolder {
            Button("Preview") {
                screen.select(item.path)
                screen.preview = tree.url(item)
            }
            Button("Open") { NSWorkspace.shared.open(tree.url(item)) }
            Divider()
        } else {
            Button("New Folder Inside…") { model.newBinderFolder(in: item.path) }
            Button("New Placeholder Here…") { model.newPlaceholder(in: item.path) }
            Divider()
        }
        if !loose {
            Button(item.index == nil ? "Set Index…" : "Change Index…") { model.showSetIndex(for: item.path) }
        }
        if item.index != nil {
            Button("Remove Index") { model.applyBinderRenames(BinderIndexer.removeIndex(from: item.path, in: tree), actionName: "Remove Index") }
        }
        Button("Rename…") { model.renameBinderItem(item.path) }
        if item.isFolder {
            Divider()
            Button("Close the Gaps in the Numbering") { model.applyBinderRenames(BinderIndexer.closeGaps(in: item.path, tree: tree), actionName: "Close Gaps") }
                .disabled(BinderIndexer.closeGaps(in: item.path, tree: tree).isEmpty)
            Button("Index the Unindexed Files Inside") {
                model.applyBinderRenames(BinderIndexer.indexUnindexed(under: item.path, in: tree), actionName: "Index Files")
            }
            .disabled(BinderIndexer.indexUnindexed(under: item.path, in: tree).isEmpty)
        } else {
            // Filing a file gives it the next index of the folder it goes into.
            Menu(loose ? "File In" : "Move To") {
                ForEach(tree.folders.filter { $0.path != item.parentPath }) { folder in
                    Button(String(repeating: "    ", count: folder.depth) + folder.name) {
                        model.applyBinderRenames(BinderIndexer.file(item.path, into: folder.path, in: tree), actionName: "File \(item.title)")
                    }
                }
            }
            if !item.isPlaceholder {
                Divider()
                ForEach(SignOffLevel.allCases, id: \.self) { level in
                    let signed = model.engagement?.signOff(level, for: item.path) != nil
                    Button(signed ? "Remove the “\(level.label)” Mark…" : "Mark as \(level.label)") { model.toggleSignOff(level, on: item.path) }
                }
            }
        }
        Divider()
        Button("Show in Finder") { model.reveal(tree.url(item)) }
        Button("Move to Trash") { model.trashBinderItems([item.path]) }
    }
}

/// Where on a row a dragged file is hovering: the top edge inserts above, the bottom edge
/// inserts below, the middle lands on the row itself. A folder is all middle.
private struct BinderRowDrop: DropDelegate {
    let item: BinderItem
    let height: CGFloat
    @Binding var hover: BinderDrop?
    let perform: ([NSItemProvider], BinderDrop) -> Void

    private func zone(_ info: DropInfo) -> BinderDrop {
        if item.isFolder { return .onto(item.path) }
        let y = info.location.y
        if y < height * 0.3 { return .before(item.path) }
        if y > height * 0.7 { return .after(item.path) }
        return .onto(item.path)
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) { hover = zone(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let z = zone(info)
        if hover != z { hover = z }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if hover?.target == item.path { hover = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let drop = zone(info)
        hover = nil
        perform(info.itemProviders(for: [.fileURL]), drop)
        return true
    }
}

/// A document let go on a placeholder. It either takes the placeholder's place — its index,
/// with the placeholder sent to the Trash — or is simply put in the folder with no index.
struct ReplacePlaceholderView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var closeWindow
    let source: PlaceholderArrival
    let placeholder: String
    @State private var replace = true

    var body: some View {
        if let tree = model.binder, let target = tree.item(placeholder) {
            let outside: Bool = { if case .outside = source { return true }; return false }()
            VStack(alignment: .leading, spacing: 12) {
                Text("“\(source.name)” was let go on the placeholder for “\(target.displayTitle)”").font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("", selection: $replace) {
                    Text("Replace the placeholder — it becomes \(target.index?.text ?? "the file here"), and the placeholder goes to the Trash").tag(true)
                    Text(outside ? "Add it as a new file in this folder, with no index — the placeholder stays"
                                 : "Put it in this folder with no index — the placeholder stays").tag(false)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(replace ? "Journal entries that refer to the placeholder will refer to this file instead."
                             : "You can give it an index afterwards: select it and choose Index ▸ Index the Selected File.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack {
                    Text(outside ? "The file is \(UserDefaults.standard.bool(forKey: "binder.addCopies") ? "copied" : "moved") into the binder." : "").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { closeWindow() }
                        .keyboardShortcut(.cancelAction)
                    Button(replace ? "Replace" : "Add") {
                        if model.arrive(source, at: placeholder, replace: replace) { closeWindow() }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
            .frame(minWidth: 520, minHeight: 280)
        } else {
            EmptyState(title: "That placeholder isn't in the binder any more", message: "")
                .frame(minWidth: 520, minHeight: 280)
        }
    }
}

/// One of the three marks on a file: P, R or 2R. Empty until someone signs; then it shows who
/// and when. Orange means the file has changed since.
struct SignOffMark: View {
    @EnvironmentObject private var model: AppModel
    let path: String
    let level: SignOffLevel
    var selected = false

    var body: some View {
        let mark = model.engagement?.signOff(level, for: path)
        let stale = model.staleSignOffs.contains(AppModel.signOffKey(path, level))
        let tint: Color = stale ? .orange : .green
        Button {
            model.toggleSignOff(level, on: path)
        } label: {
            Group {
                if let mark {
                    Text("\(level.short) \(Self.initials(mark.actor.display)) \(Stamp.day(mark.at))")
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 6)
                        .frame(height: 17)
                        .background(Capsule().fill(tint))
                } else {
                    Text(level.short)
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : Color.secondary)
                        .frame(minWidth: 24)
                        .frame(height: 17)
                        .overlay(Capsule().strokeBorder(selected ? Color.white.opacity(0.6) : Color.primary.opacity(0.22), lineWidth: 1))
                }
            }
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help(mark, stale))
    }

    private func help(_ mark: SignOff?, _ stale: Bool) -> String {
        guard let mark else { return "Mark as \(level.label.lowercased()), as yourself. Your name, this Mac and the time are recorded." }
        return "\(level.label) by \(mark.actor.display) on \(Stamp.local(mark.at)), on \(mark.actor.computer)."
            + (stale ? " The file has changed since." : "") + " Click to take the mark off."
    }

    static func initials(_ name: String) -> String {
        let letters = name.split(whereSeparator: { !$0.isLetter }).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.prefix(3).joined()
    }
}

/// What a drag inside the binder is about to do, to be confirmed. Closing or cancelling leaves
/// everything as it was.
struct BinderMoveView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var closeWindow
    let path: String
    let drop: BinderDrop

    var body: some View {
        if let tree = model.binder, let item = tree.item(path), let target = tree.item(drop.target) {
            let renames = BinderIndexer.move(path, drop, in: tree)
            VStack(alignment: .leading, spacing: 12) {
                Text(title(item, target)).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(explanation(item, target, tree)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                RenameList(renames: renames)
                HStack {
                    Text("Linked files and sign-offs follow the rename. ⌘Z undoes it.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { closeWindow() }
                        .keyboardShortcut(.cancelAction)
                    Button(renames.count > 1 ? "Renumber" : "Move") {
                        if model.applyBinderMove(renames) { closeWindow() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(renames.isEmpty)
                }
            }
            .padding(18)
            .frame(minWidth: 520, minHeight: 340)
        } else {
            EmptyState(title: "That item isn't in the binder any more", message: "")
                .frame(minWidth: 520, minHeight: 340)
        }
    }

    private func title(_ item: BinderItem, _ target: BinderItem) -> String {
        switch drop {
        case .before: return "Put “\(item.displayTitle)” above “\(target.displayTitle)”?"
        case .after: return "Put “\(item.displayTitle)” below “\(target.displayTitle)”?"
        case .onto: return target.isFolder ? "File “\(item.displayTitle)” in “\(target.name)”?"
                                           : (target.index == nil ? "File “\(item.displayTitle)” beside “\(target.displayTitle)”?" : "Give “\(item.displayTitle)” the index of “\(target.displayTitle)”?")
        }
    }

    private func explanation(_ item: BinderItem, _ target: BinderItem, _ tree: BinderTree) -> String {
        switch drop {
        case .onto where target.isFolder: return "It gets the folder's next index."
        case .onto where target.index != nil:
            return "It becomes \(target.index!.text). “\(target.displayTitle)” stays in the folder but is left with no index."
        case .onto: return "“\(target.displayTitle)” has no index to take or to sit beside, so the file is given the folder's next one."
        default:
            if target.index == nil { return "“\(target.displayTitle)” has no index to sit beside, so the file is given the folder's next one." }
            if item.index?.prefix == target.index?.prefix { return "The files between the two places are renumbered. The folder keeps the same run of numbers." }
            return "It takes the number at that place. The file there, and any that follow it without a gap, move up by one."
        }
    }
}

/// The renames a change will make, old name to new.
struct RenameList: View {
    let renames: [BinderRename]

    var body: some View {
        if renames.isEmpty {
            Spacer()
        } else {
            Text(renames.count == 1 ? "This will rename 1 item:" : "This will rename \(renames.count) items:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(renames, id: \.from) { r in
                        let moved = (r.from as NSString).deletingLastPathComponent != (r.to as NSString).deletingLastPathComponent
                        HStack(spacing: 6) {
                            Text((r.from as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                            Text(moved ? r.to : (r.to as NSString).lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                        }
                        .font(.system(size: 12))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035)))
        }
    }
}

/// Files dropped on the binder from Finder. They get the folder's next index unless a number
/// is typed or they are left unnumbered; nothing moves until Add is clicked.
struct AddToBinderView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var closeWindow
    @AppStorage("binder.addCopies") private var copies = false
    let urls: [URL]
    let folderPath: String
    var suggested: BinderIndex?
    /// The suggested number is free and sits where the file was let go: start on it.
    var preferSuggested = false
    @State private var how = "next"
    @State private var custom = ""
    @State private var loaded = false

    var body: some View {
        if let tree = model.binder {
            let folder = tree.item(folderPath)
            let files = urls.filter { !((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) }
            let next = BinderIndexer.nextFileIndex(in: folderPath, tree: tree)
            let typed = BinderIndex(typed: custom, isFolder: false)
            let start: BinderIndex? = files.isEmpty ? nil : (how == "next" ? next : (how == "custom" ? typed : nil))
            let plan = BinderIndexer.place(files.map(\.lastPathComponent), at: start, in: tree)
            let ready = how != "custom" || typed != nil || files.isEmpty
            VStack(alignment: .leading, spacing: 12) {
                Text("Add \(urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items") to \(folder.map { "“\($0.name)”" } ?? "the binder folder")")
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if folderPath.isEmpty {
                    Text("Files beside the trial balance aren't in a binder folder, so they aren't indexed. Drop them on a folder to file and number them.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !files.isEmpty {
                    Picker("Index", selection: $how) {
                        if let next {
                            Text(files.count == 1 ? "The next index in this folder — \(next.text)" : "The next indexes in this folder — from \(next.text)").tag("next")
                        }
                        HStack(spacing: 8) {
                            Text(files.count == 1 ? "This index:" : "Starting at:")
                            TextField("e.g. \(next?.text ?? "2000.04")", text: $custom)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 110)
                                .onChange(of: custom) { _, new in if !new.isEmpty && loaded && new != suggested?.text { how = "custom" } }
                        }
                        .tag("custom")
                        Text("No index — keep the name\(files.count == 1 ? "" : "s") as \(files.count == 1 ? "it is" : "they are")").tag("none")
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    if how == "custom" && typed == nil && !custom.trimmingCharacters(in: .whitespaces).isEmpty {
                        Label("A file's index is number.number, like 2000.04.", systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.callout)
                    }
                    if next == nil {
                        Text("“\(folder?.name ?? "")” has no number of its own, so there is no next index to give.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                Text(plan.renames.isEmpty ? "Comes in as:" : "Comes in as, with \(plan.renames.count) file\(plan.renames.count == 1 ? "" : "s") moving up to make room:")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(zip(files, plan.names)), id: \.0) { url, name in
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill").foregroundStyle(.green).font(.caption)
                                Text(name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        ForEach(urls.filter { !files.contains($0) }, id: \.self) { url in
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor).font(.caption)
                                Text(url.lastPathComponent).fontWeight(.medium).lineLimit(1)
                            }
                        }
                        ForEach(plan.renames, id: \.from) { r in
                            HStack(spacing: 6) {
                                Text((r.from as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                                Text((r.to as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035)))
                Toggle("Leave the original\(urls.count == 1 ? "" : "s") where \(urls.count == 1 ? "it is" : "they are") (copy instead of move)", isOn: $copies)
                HStack {
                    Text("⌘Z takes it back.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { closeWindow() }
                        .keyboardShortcut(.cancelAction)
                    Button("Add") {
                        if model.addToBinder(urls, folderPath: folderPath, start: start, copy: copies) { closeWindow() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
                }
            }
            .padding(18)
            .frame(minWidth: 540, minHeight: 400)
            .onAppear {
                guard !loaded else { return }
                loaded = true
                // The next index is the default; a folder with no number has none to give. Let go
                // between two files with a number free between them, that number is the default.
                how = next == nil ? "none" : "next"
                if let suggested {
                    custom = suggested.text
                    how = preferSuggested ? "custom" : how
                }
            }
        }
    }
}

/// Sets or changes one item's index. If the number is taken, the person chooses: move the item
/// that has it (and what follows) up by one, or take its index away. Either way the result is
/// shown before anything is renamed.
struct SetIndexView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var closeWindow
    let path: String
    @State private var text = ""
    @State private var conflict = "insert"
    @State private var loaded = false

    var body: some View {
        if let tree = model.binder, let item = tree.item(path) {
            let index = BinderIndex(typed: text, isFolder: item.isFolder)
            let other = index.flatMap { BinderIndexer.holder(of: $0, isFolder: item.isFolder, in: tree, except: path) }
            let renames = index.map { BinderIndexer.setIndex($0, on: path, in: tree, conflict: conflict == "insert" ? .insert : .replace) } ?? []
            VStack(alignment: .leading, spacing: 12) {
                Text(item.index == nil ? "Set Index" : "Change Index").font(.headline)
                Text(item.name).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 8) {
                    Text("Index")
                    TextField(item.isFolder ? "e.g. 5030" : "e.g. 2000.04", text: $text)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                        .onSubmit { apply(renames) }
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty && index == nil {
                        Label(item.isFolder ? "A folder's index is a number, like 5030." : "A file's index is number.number, like 2000.04.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }
                if let other, let index {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("\(index.text) is already “\(other.title)”.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Picker("", selection: $conflict) {
                            Text("Insert here — move it, and what follows it, up by one").tag("insert")
                            Text("Take its place — remove the index from “\(other.title)”").tag("replace")
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                    }
                }
                if !renames.isEmpty {
                    Text(renames.count == 1 ? "This will rename 1 item:" : "This will rename \(renames.count) items:")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(renames, id: \.from) { r in
                                HStack(spacing: 6) {
                                    Text((r.from as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                                    Text((r.to as NSString).lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                                }
                                .font(.system(size: 12))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: .infinity)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035)))
                } else {
                    Spacer()
                }
                HStack {
                    Text("Linked files on journal entries follow the rename. ⌘Z undoes it.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { closeWindow() }
                        .keyboardShortcut(.cancelAction)
                    Button("Rename") { apply(renames) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(renames.isEmpty)
                }
            }
            .padding(18)
            .frame(minWidth: 500, minHeight: 340)
            .onAppear {
                guard !loaded else { return }
                loaded = true
                // Start on the item's own index, or the next free one where it sits.
                text = item.index?.text
                    ?? (item.isFolder ? BinderIndexer.suggestedFolderIndex(for: path, tree: tree) : BinderIndexer.nextFileIndex(in: item.parentPath, tree: tree))?.text
                    ?? ""
                // For documentation pictures: ask for a number that is taken, to show the choice.
                if CommandLine.arguments.contains("--tb-snapshot"), let taken = tree.children(of: item.parentPath).first(where: { !$0.isFolder && $0.index != nil })?.index {
                    text = taken.text
                }
            }
        } else {
            EmptyState(title: "That item isn't in the binder any more", message: "")
                .frame(minWidth: 500, minHeight: 340)
        }
    }

    private func apply(_ renames: [BinderRename]) {
        guard !renames.isEmpty else { return }
        if model.applyBinderRenames(renames, actionName: "Set Index") { closeWindow() }
    }
}

/// A trial balance's own details: its name, and the activity number it goes under in the tax software.
struct EntityDetailsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var closeWindow
    let entityID: String
    @State private var name = ""
    @State private var activity = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trial Balance Details").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("Activity number", text: $activity, prompt: Text("Optional"))
            }
            Text("The activity number is the one this trial balance is imported under in the tax software (the activity in CCH). It is shown beside the name, heads this trial balance's report, and is a column of the data export. Each trial balance has its own.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { closeWindow() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    let ok = model.mutate("Edit Trial Balance") { e in
                        try e.renameEntity(entityID, to: name)
                        try e.setActivityNumber(activity, for: entityID)
                    }
                    if ok { closeWindow() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            guard !loaded, let ent = model.engagement?.entity(entityID) else { return }
            loaded = true
            name = ent.name
            activity = ent.activityNumber
        }
    }
}
