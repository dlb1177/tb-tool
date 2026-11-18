import AppKit
import SwiftUI
import TBCore

/// One row of the binder, laid out: an item and how deep it sits.
private struct BinderRow: Identifiable {
    let item: BinderItem
    var id: String { item.path }
}

/// The whole binder for the year, opened out: every folder and file with its index. Indexes are
/// added and changed here instead of by renaming files in Finder.
struct BinderView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: String?
    @State private var onlyProblems = false

    var body: some View {
        VStack(spacing: 0) {
            if let tree = model.binder {
                let duplicates = Set(tree.duplicateIndexes.flatMap { $0.items.map(\.path) })
                let unindexed = Set(tree.unindexed.map(\.path)), unfiled = Set(tree.unfiled.map(\.path))
                let rows = tree.all.filter { !onlyProblems || duplicates.contains($0.path) || unindexed.contains($0.path) || unfiled.contains($0.path) }
                    .map { BinderRow(item: $0) }
                let picked = selection.flatMap { tree.item($0) }
                PageHeader(title: "Binder", subtitle: subtitle(tree)) {
                    Toggle("Only what needs attention", isOn: $onlyProblems)
                        .toggleStyle(.checkbox)
                        .fixedSize()
                    Button("Set Index…") { if let p = picked { model.showSetIndex(for: p.path) } }
                        .disabled(picked == nil || (picked.map { !$0.isFolder && $0.parentPath.isEmpty } ?? true))
                        .help("Give the selected item an index, or change the one it has")
                    Menu {
                        Button("Index Every Unindexed File") {
                            model.applyBinderRenames(BinderIndexer.indexUnindexed(under: "", in: tree), actionName: "Index Files")
                        }
                        .disabled(BinderIndexer.indexUnindexed(under: "", in: tree).isEmpty)
                        if let p = picked, p.isFolder {
                            Button("Index the Unindexed Files in “\(p.title)”") {
                                model.applyBinderRenames(BinderIndexer.indexUnindexed(under: p.path, in: tree), actionName: "Index Files")
                            }
                            .disabled(BinderIndexer.indexUnindexed(under: p.path, in: tree).isEmpty)
                            Button("Close the Gaps in “\(p.title)”") {
                                model.applyBinderRenames(BinderIndexer.closeGaps(in: p.path, tree: tree), actionName: "Close Gaps")
                            }
                            .disabled(BinderIndexer.closeGaps(in: p.path, tree: tree).isEmpty)
                        }
                        if let p = picked, p.index != nil {
                            Divider()
                            Button("Remove the Index from “\(p.title)”") {
                                model.applyBinderRenames(BinderIndexer.removeIndex(from: p.path, in: tree), actionName: "Remove Index")
                            }
                        }
                    } label: {
                        Label("Index", systemImage: "number")
                    }
                    .fixedSize()
                    Button {
                        model.refreshBinder()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Read the folder again. It is also read whenever you come back to TB Tool.")
                    Button("Show in Finder") { model.reveal(picked.map { tree.url($0) } ?? tree.root) }
                }
                Divider()
                alerts(tree)
                if tree.isEmpty {
                    EmptyState(title: "Nothing in the binder yet",
                               message: "The binder is the folder this trial balance is in. Folders and files you put there show up here, with their index numbers.")
                } else {
                    List(rows, selection: $selection) { row in
                        rowView(row.item, tree: tree, duplicate: duplicates.contains(row.item.path))
                            .contextMenu { menu(row.item, tree) }
                            .tag(row.item.path)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .contextMenu(forSelectionType: String.self) { _ in EmptyView() } primaryAction: { paths in
                        if let item = paths.first.flatMap({ tree.item($0) }), !item.isFolder { NSWorkspace.shared.open(tree.url(item)) }
                    }
                }
            } else {
                PageHeader(title: "Binder", subtitle: "") { EmptyView() }
                Divider()
                EmptyState(title: "This folder isn't being treated as a binder",
                           message: "The binder is the folder the trial balance file is in — one folder per client per year. This file sits in a general folder (your home folder, Desktop, Documents or Downloads), so what is beside it isn't read as workpapers. Move the file into the year's folder for this client.")
            }
        }
        .onAppear { model.refreshBinder() }
    }

    private func subtitle(_ tree: BinderTree) -> String {
        let files = tree.files.count, folders = tree.folders.count
        return "\(model.displayPath(tree.root)) · \(folders) folder\(folders == 1 ? "" : "s"), \(files) file\(files == 1 ? "" : "s")"
            + (tree.truncated ? " · too large to read in full" : "")
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

    private func rowView(_ item: BinderItem, tree: BinderTree, duplicate: Bool) -> some View {
        let loose = !item.isFolder && item.parentPath.isEmpty
        return HStack(spacing: 8) {
            Group {
                if let index = item.index {
                    Text(index.text)
                        .monospacedDigit()
                        .fontWeight(item.isFolder ? .semibold : .regular)
                        .foregroundStyle(duplicate ? Color.orange : Color.primary)
                } else {
                    Text(loose ? "not filed" : "no index").foregroundStyle(.orange)
                }
            }
            .frame(width: 78, alignment: .leading)
            .padding(.leading, CGFloat(item.depth) * 18)
            Image(systemName: item.isFolder ? "folder.fill" : (item.isPlaceholder ? "doc.badge.ellipsis" : "doc"))
                .foregroundStyle(item.isFolder ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            Text(item.isPlaceholder ? String(item.title.dropLast(BinderPlaceholder.name(for: "").count)) : item.title)
                .fontWeight(item.isFolder ? .semibold : .regular)
                .foregroundStyle(item.isPlaceholder ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if item.isPlaceholder {
                Text("placeholder").font(.caption).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .help("A stand-in from the roll forward: the document hasn't been added for this year yet.")
            }
            if duplicate {
                Text("number used twice").font(.caption).foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            if !item.tags.isEmpty {
                Text(item.tags.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help("Finder tags")
            }
        }
        .font(.system(size: 12.5))
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private func menu(_ item: BinderItem, _ tree: BinderTree) -> some View {
        let loose = !item.isFolder && item.parentPath.isEmpty
        if !loose {
            Button(item.index == nil ? "Set Index…" : "Change Index…") { model.showSetIndex(for: item.path) }
        }
        if item.index != nil {
            Button("Remove Index") { model.applyBinderRenames(BinderIndexer.removeIndex(from: item.path, in: tree), actionName: "Remove Index") }
        }
        if item.isFolder {
            Button("Index the Unindexed Files Inside") {
                model.applyBinderRenames(BinderIndexer.indexUnindexed(under: item.path, in: tree), actionName: "Index Files")
            }
            .disabled(BinderIndexer.indexUnindexed(under: item.path, in: tree).isEmpty)
            Button("Close the Gaps") { model.applyBinderRenames(BinderIndexer.closeGaps(in: item.path, tree: tree), actionName: "Close Gaps") }
                .disabled(BinderIndexer.closeGaps(in: item.path, tree: tree).isEmpty)
        } else {
            // Filing a file gives it the next index of the folder it goes into.
            Menu(loose ? "File In" : "Move To") {
                ForEach(tree.folders.filter { $0.path != item.parentPath }) { folder in
                    Button(String(repeating: "    ", count: folder.depth) + folder.name) {
                        model.applyBinderRenames(BinderIndexer.file(item.path, into: folder.path, in: tree), actionName: "File \(item.title)")
                    }
                }
            }
        }
        Divider()
        if !item.isFolder { Button("Open") { NSWorkspace.shared.open(tree.url(item)) } }
        Button("Show in Finder") { model.reveal(tree.url(item)) }
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
