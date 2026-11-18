import AppKit
import QuickLook
import QuickLookUI
import SwiftUI
import TBCore
import UniformTypeIdentifiers

/// What the Binder screen remembers while it is open: the selected item, the file being
/// previewed, and where a dragged file is hovering.
final class BinderScreen: ObservableObject {
    @Published var selection: String?
    @Published var preview: URL?
    @Published var hover: BinderDrop?
    @Published var hoverBackground = false
    @Published var onlyProblems = false
    var monitor: Any?

    /// The rows on screen: everything, less what sits inside a closed folder.
    func rows(_ tree: BinderTree, collapsed: Set<String>, problems: Set<String>) -> [BinderItem] {
        if onlyProblems { return tree.all.filter { problems.contains($0.path) } }
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

/// The whole binder for the year, opened out: every folder and file with its index. Files are
/// brought in, moved, renumbered, previewed and signed off here instead of in Finder.
struct BinderView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var screen = BinderScreen()

    static let rowHeight: CGFloat = 25

    var body: some View {
        VStack(spacing: 0) {
            if let tree = model.binder {
                let duplicates = Set(tree.duplicateIndexes.flatMap { $0.items.map(\.path) })
                let problems = duplicates.union(tree.unindexed.map(\.path)).union(tree.unfiled.map(\.path))
                    .union(model.staleSignOffs.map { $0.components(separatedBy: "\u{1F}")[0] })
                let rows = screen.rows(tree, collapsed: model.collapsedFolders, problems: problems)
                let picked = screen.selection.flatMap { tree.item($0) }
                PageHeader(title: "Binder", subtitle: subtitle(tree)) {
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
                            Button("Remove the Index from “\(p.displayTitle)”") {
                                model.applyBinderRenames(BinderIndexer.removeIndex(from: p.path, in: tree), actionName: "Remove Index")
                            }
                        }
                    } label: {
                        Label("Index", systemImage: "number")
                    }
                    .fixedSize()
                    Button {
                        if let p = picked, !p.isFolder { screen.preview = tree.url(p) }
                    } label: {
                        Label("Preview", systemImage: "eye")
                    }
                    .disabled(picked == nil || picked?.isFolder == true)
                    .help("Look at the selected file without opening it. Or press Space.")
                    Button {
                        model.refreshBinder()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Read the folder again. It is also read whenever you come back to TB Tool.")
                    Button("Show in Finder") { model.reveal(picked.map { tree.url($0) } ?? tree.root) }
                }
                Divider()
                bar(tree)
                Divider()
                alerts(tree)
                if tree.isEmpty {
                    VStack(spacing: 10) {
                        EmptyState(title: "Nothing in the binder yet",
                                   message: "The binder is the folder this trial balance is in. Make the standard folders, or drop folders and files here.",
                                   button: "Make the Standard Folders") { model.createBinderFolders() }
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
                } else {
                    list(rows, tree: tree, duplicates: duplicates)
                }
            } else {
                PageHeader(title: "Binder", subtitle: "") { EmptyView() }
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
            if path.hasPrefix(root + "/") { screen.selection = String(path.dropFirst(root.count + 1)) }
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

    private func subtitle(_ tree: BinderTree) -> String {
        let files = tree.files.count, folders = tree.folders.count
        return "\(model.displayPath(tree.root)) · \(folders) folder\(folders == 1 ? "" : "s"), \(files) file\(files == 1 ? "" : "s")"
            + (tree.truncated ? " · too large to read in full" : "")
    }

    /// The strip under the header: open and close every folder, and what the marks mean.
    private func bar(_ tree: BinderTree) -> some View {
        let signed = Set(model.engagement?.signOffs.map(\.path) ?? []).count
        return HStack(spacing: 10) {
            Button {
                model.collapsedFolders = []
            } label: {
                Label("Expand All", systemImage: "chevron.down.2")
            }
            .disabled(model.collapsedFolders.isEmpty || screen.onlyProblems)
            Button {
                model.collapsedFolders = Set(tree.folders.map(\.path))
            } label: {
                Label("Collapse All", systemImage: "chevron.right.2")
            }
            .disabled(tree.folders.isEmpty || screen.onlyProblems)
            Toggle("Only what needs attention", isOn: $screen.onlyProblems)
                .toggleStyle(.checkbox)
                .fixedSize()
            Spacer()
            Text("Drop files on a folder to add them · drag a file to move or renumber it · Space previews")
                .foregroundStyle(.secondary)
                .lineLimit(1)
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

    // MARK: The list

    private func list(_ rows: [BinderItem], tree: BinderTree, duplicates: Set<String>) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.path) { n, item in
                        rowView(item, tree: tree, duplicate: duplicates.contains(item.path), stripe: n % 2 == 1)
                            .id(item.path)
                    }
                }
                .padding(.vertical, 4)
                // Below the last row: files dropped there go into the binder folder itself.
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .contentShape(Rectangle())
                    .onTapGesture { screen.selection = nil }
                    .onDrop(of: [.fileURL], isTargeted: $screen.hoverBackground) { providers in
                        load(providers) { urls in dropped(urls, nil, tree) }
                        return true
                    }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2).opacity(screen.hoverBackground ? 1 : 0).padding(2))
            .onChange(of: screen.selection) { _, path in
                if let path { proxy.scrollTo(path) }
            }
        }
    }

    private func rowView(_ item: BinderItem, tree: BinderTree, duplicate: Bool, stripe: Bool) -> some View {
        let loose = !item.isFolder && item.parentPath.isEmpty
        let selected = screen.selection == item.path
        let closed = model.collapsedFolders.contains(item.path)
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
            Image(systemName: item.isFolder ? (closed ? "folder.fill" : "folder.fill") : (item.isPlaceholder ? "doc.badge.ellipsis" : "doc"))
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
                    .help("A stand-in from the roll forward: the document hasn't been added for this year yet. Drag the document onto it when it arrives.")
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
        .gesture(TapGesture().onEnded { screen.selection = item.path })
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
                // A file can be dragged to a new place here, or out to Finder or another app.
                row.onDrag {
                    screen.selection = item.path
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

    /// A file from the binder itself is being moved: show what that does and ask. Files from
    /// anywhere else are being added: ask how to number them.
    private func dropped(_ urls: [URL], _ drop: BinderDrop?, _ tree: BinderTree) {
        let root = tree.root.resolvingSymlinksInPath().path
        func inside(_ u: URL) -> String? {
            let p = u.resolvingSymlinksInPath().path
            return p.hasPrefix(root + "/") ? String(p.dropFirst(root.count + 1)) : nil
        }
        let outside = urls.filter { inside($0) == nil }
        if outside.isEmpty {
            guard let drop, let path = urls.first.flatMap(inside) else { return }
            if BinderIndexer.move(path, drop, in: tree).isEmpty {
                model.status = "Nothing to move: “\((path as NSString).lastPathComponent)” is already there."
            } else {
                model.showBinderMove(path, drop)
            }
            return
        }
        var folderPath = ""
        var at: BinderIndex?
        if let drop, let target = tree.item(drop.target) {
            folderPath = target.isFolder ? target.path : target.parentPath
            // Let go above or below an indexed file: offer that spot as the custom number.
            if !target.isFolder, let index = target.index, let suffix = index.suffix {
                if drop == .before(target.path) { at = index }
                if drop == .after(target.path) { at = BinderIndex(prefix: index.prefix, suffix: suffix + 1, width: index.width) }
            }
        }
        model.showAddToBinder(outside, folderPath: folderPath, suggested: at)
    }

    // MARK: Keys

    /// Space previews the selected file (and closes the preview), the arrows move through the
    /// list, and ← → close and open a folder — as in Finder.
    private func installKeys() {
        guard screen.monitor == nil else { return }
        screen.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak screen, weak model] event in
            guard let screen, let model, model.selection == .binder, let tree = model.binder else { return event }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            let inPreview = event.window is QLPreviewPanel
            let inMain = event.window?.identifier?.rawValue.hasPrefix("main") ?? false
            guard inPreview || (inMain && !(event.window?.firstResponder is NSText)) else { return event }
            let rows = screen.rows(tree, collapsed: model.collapsedFolders, problems: [])
            let at = screen.selection.flatMap { s in rows.firstIndex { $0.path == s } }
            func select(_ item: BinderItem) {
                screen.selection = item.path
                if screen.preview != nil { screen.preview = item.isFolder ? screen.preview : tree.url(item) }
            }
            switch event.keyCode {
            case 49: // Space
                if screen.preview != nil {
                    screen.preview = nil
                } else if let item = screen.selection.flatMap({ tree.item($0) }), !item.isFolder {
                    screen.preview = tree.url(item)
                } else {
                    return event
                }
                return nil
            case 125: // ↓
                guard !screen.onlyProblems, !rows.isEmpty else { return event }
                select(rows[min((at ?? -1) + 1, rows.count - 1)])
                return nil
            case 126: // ↑
                guard !screen.onlyProblems, !rows.isEmpty else { return event }
                select(rows[max((at ?? 1) - 1, 0)])
                return nil
            case 123: // ←
                guard !inPreview, let item = screen.selection.flatMap({ tree.item($0) }) else { return event }
                if item.isFolder && !model.collapsedFolders.contains(item.path) {
                    model.collapsedFolders.insert(item.path)
                } else if !item.parentPath.isEmpty {
                    screen.selection = item.parentPath
                }
                return nil
            case 124: // →
                guard !inPreview, let item = screen.selection.flatMap({ tree.item($0) }), item.isFolder else { return event }
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
        let loose = !item.isFolder && item.parentPath.isEmpty
        if !item.isFolder {
            Button("Preview") {
                screen.selection = item.path
                screen.preview = tree.url(item)
            }
            Button("Open") { NSWorkspace.shared.open(tree.url(item)) }
            Divider()
        }
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
    @State private var trashPlaceholder = true

    var body: some View {
        if let tree = model.binder, let item = tree.item(path), let target = tree.item(drop.target) {
            let renames = BinderIndexer.move(path, drop, in: tree)
            let replacing = drop == .onto(target.path) && !target.isFolder && target.index != nil
            VStack(alignment: .leading, spacing: 12) {
                Text(title(item, target)).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(explanation(item, target, tree)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if replacing && target.isPlaceholder {
                    Toggle("Move the placeholder to the Trash — the document has arrived", isOn: $trashPlaceholder)
                }
                RenameList(renames: renames)
                HStack {
                    Text("Linked files and sign-offs follow the rename. ⌘Z undoes it.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { closeWindow() }
                        .keyboardShortcut(.cancelAction)
                    Button(renames.count > 1 ? "Renumber" : "Move") {
                        let own = renames.first { $0.from == path }?.to
                        let placeholder = replacing && target.isPlaceholder && trashPlaceholder ? renames.first { $0.from == target.path }?.to : nil
                        if model.applyBinderMove(renames, replacedPlaceholder: placeholder, by: own) { closeWindow() }
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
        case .onto where target.index != nil && target.isPlaceholder:
            return "It becomes \(target.index!.text), in the placeholder's place. With the box ticked, the placeholder goes to the Trash and journal entries that refer to it refer to this file instead; otherwise it stays in the folder with no index."
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
                                .onChange(of: custom) { _, new in if !new.isEmpty { how = "custom" } }
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
                if let suggested { custom = suggested.text }
                // The next index is the default; a folder with no number has none to give.
                how = next == nil ? "none" : "next"
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
