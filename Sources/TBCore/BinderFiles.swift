import Foundation

// The binder is the folder a trial balance file sits in: the year's folder for one client, with
// numbered folders ("2000 Client Financials") holding indexed workpapers ("2000.02 GL.xlsx").
// This file knows how to read that folder, how its index numbers work, how to renumber without
// ever giving two items the same index, and how to roll the whole thing forward to next year.

// MARK: - Index numbers

/// The number at the front of a binder item's name. A file's index has a suffix ("2000.02");
/// a folder's is the number alone ("2000").
public struct BinderIndex: Equatable, Hashable, Sendable {
    public var prefix: String
    public var suffix: Int?
    /// How many digits the suffix is written with ("02" is 2).
    public var width: Int

    public init(prefix: String, suffix: Int? = nil, width: Int = 2) {
        self.prefix = prefix
        self.suffix = suffix
        self.width = max(width, 1)
    }

    public var text: String {
        guard let suffix else { return prefix }
        let digits = String(suffix)
        return prefix + "." + String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    /// The index typed by a person: "2000.3", "2000.03", or for a folder "5010".
    public init?(typed raw: String, isFolder: Bool) {
        let t = raw.trimmed
        let parts = t.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        func digits(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0 >= "0" && $0 <= "9" } }
        if isFolder {
            guard parts.count == 1, digits(parts[0]) else { return nil }
            self.init(prefix: parts[0])
        } else {
            guard parts.count == 2, digits(parts[0]), digits(parts[1]), let n = Int(parts[1]), n > 0 else { return nil }
            self.init(prefix: parts[0], suffix: n, width: max(2, parts[1].count))
        }
    }

    /// Splits a name into its index and the rest. A file counts as indexed only with the full
    /// "number.number" form; a folder with a leading number.
    public static func parse(_ name: String, isFolder: Bool) -> (index: BinderIndex?, title: String) {
        let pattern = isFolder ? #"^(\d{2,6})(?:\.(\d{1,4}))?[\s_]+(.+)$"# : #"^(\d{2,6})\.(\d{1,4})[\s_]+(.+)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) else { return (nil, name) }
        func group(_ i: Int) -> String? { Range(m.range(at: i), in: name).map { String(name[$0]) } }
        guard let prefix = group(1), let title = group(3) else { return (nil, name) }
        if let s = group(2), let n = Int(s) { return (BinderIndex(prefix: prefix, suffix: n, width: s.count), title) }
        return (BinderIndex(prefix: prefix), title)
    }
}

// MARK: - The folder as a tree

public struct BinderItem: Equatable, Identifiable, Sendable {
    /// Path relative to the binder folder, with "/" between parts.
    public var path: String
    public var name: String
    public var isFolder: Bool
    public var index: BinderIndex?
    /// The name without its index.
    public var title: String
    public var children: [BinderItem] = []
    /// A stand-in left by a roll forward for a document that hasn't arrived yet.
    public var isPlaceholder = false
    /// Finder tags on the item.
    public var tags: [String] = []

    public var id: String { path }
    /// The name to show: for a placeholder, the document it stands for.
    public var displayTitle: String { isPlaceholder ? BinderPlaceholder.document(title) : title }
    public var parentPath: String { (path as NSString).deletingLastPathComponent }
    public var depth: Int { path.split(separator: "/").count - 1 }
}

public enum BinderPlaceholder {
    /// Goes between the index and the document's name: "4000.03 (PLACEHOLDER) Bank statement.pdf.txt".
    static let tag = "(PLACEHOLDER) "
    /// How placeholders were named before version 1.5: "4000.03 Bank statement.pdf (placeholder).txt".
    static let earlierMarker = " (placeholder).txt"

    public static func isPlaceholder(_ name: String) -> Bool {
        if name.hasSuffix(earlierMarker) { return true }
        let title = BinderIndex.parse(name, isFolder: false).title
        return title.hasPrefix(tag) && title.lowercased().hasSuffix(".txt") && title.count > tag.count + 4
    }

    /// "2000.02 GL.xlsx" → "2000.02 (PLACEHOLDER) GL.xlsx.txt". A placeholder keeps its name
    /// (one named the earlier way takes the present form).
    public static func name(for original: String) -> String {
        let parsed = BinderIndex.parse(original, isFolder: false)
        let front = parsed.index.map { $0.text + " " } ?? ""
        if original.hasSuffix(earlierMarker) { return front + tag + parsed.title.dropLast(earlierMarker.count) + ".txt" }
        if isPlaceholder(original) { return original }
        return front + tag + parsed.title + ".txt"
    }

    /// The document a placeholder stands for, from its name without the index:
    /// "(PLACEHOLDER) GL.xlsx.txt" → "GL.xlsx".
    public static func document(_ title: String) -> String {
        if title.hasSuffix(earlierMarker) { return String(title.dropLast(earlierMarker.count)) }
        if title.hasPrefix(tag), title.lowercased().hasSuffix(".txt") { return String(title.dropFirst(tag.count).dropLast(4)) }
        return title
    }
}

public struct BinderTree: Equatable, Sendable {
    public var root: URL
    /// What sits directly in the binder folder, in name order.
    public var items: [BinderItem] = []
    /// True when the folder was too big to read in full (it is probably not a binder).
    public var truncated = false

    public init(root: URL, items: [BinderItem] = []) {
        self.root = root
        self.items = items
    }

    /// Every item, each folder followed by what is inside it.
    public var all: [BinderItem] {
        var out: [BinderItem] = []
        func walk(_ list: [BinderItem]) {
            for i in list {
                out.append(i)
                walk(i.children)
            }
        }
        walk(items)
        return out
    }

    public var files: [BinderItem] { all.filter { !$0.isFolder } }

    /// Every indexed file, in index order whatever folder it is in: what a journal entry can refer to.
    public var indexedFiles: [BinderItem] {
        files.filter { $0.index != nil }.sorted { a, b in
            let x = a.index!, y = b.index!
            if x.prefix != y.prefix { return x.prefix.compare(y.prefix, options: .numeric) == .orderedAscending }
            if x.suffix != y.suffix { return (x.suffix ?? 0) < (y.suffix ?? 0) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
    public var folders: [BinderItem] { all.filter(\.isFolder) }
    public func item(_ path: String) -> BinderItem? { all.first { $0.path == path } }
    public func children(of folderPath: String) -> [BinderItem] { folderPath.isEmpty ? items : (item(folderPath)?.children ?? []) }
    public func url(_ item: BinderItem) -> URL { root.appendingPathComponent(item.path) }
    public var isEmpty: Bool { items.isEmpty }

    // MARK: What needs attention

    /// Files sitting loose beside the trial balance instead of in one of the binder's folders.
    public var unfiled: [BinderItem] { items.filter { !$0.isFolder } }

    /// Files and folders inside the binder with no index. (Loose files are reported as unfiled.)
    public var unindexed: [BinderItem] { all.filter { $0.index == nil && ($0.isFolder || !$0.parentPath.isEmpty) } }

    /// Indexes that more than one item has. Files are compared with files and folders with folders.
    public var duplicateIndexes: [(index: String, items: [BinderItem])] {
        var order: [String] = []
        var by: [String: [BinderItem]] = [:]
        for i in all {
            guard let index = i.index else { continue }
            let key = (i.isFolder ? "d:" : "f:") + BinderIndex(prefix: index.prefix, suffix: index.suffix, width: 1).text
            if by[key] == nil { order.append(key) }
            by[key, default: []].append(i)
        }
        return order.compactMap { key in by[key]!.count > 1 ? (by[key]![0].index!.text, by[key]!) : nil }
    }
}

public enum BinderScanner {
    /// Names that are never part of the binder's contents.
    static let skipped: Set<String> = ["TB Backups"]

    /// Reads the folder. The trial balance files themselves, the backups folder, hidden files
    /// and apps are left out. Reading stops after `limit` items.
    public static func scan(_ root: URL, limit: Int = 4000) -> BinderTree {
        var tree = BinderTree(root: root.standardizedFileURL)
        var seen = 0
        let fm = FileManager.default

        func read(_ dir: URL, _ relative: String) -> [BinderItem] {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .tagNamesKey],
                                                            options: [.skipsHiddenFiles]) else { return [] }
            var out: [BinderItem] = []
            for url in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                if seen >= limit {
                    tree.truncated = true
                    break
                }
                let name = url.lastPathComponent
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .tagNamesKey])
                if values?.isSymbolicLink == true || values?.isPackage == true || skipped.contains(name) { continue }
                let isFolder = values?.isDirectory ?? false
                // The trial balance files live at the top of the binder and aren't workpapers.
                if !isFolder && relative.isEmpty && Store.looksLikeTrialBalance(url) { continue }
                seen += 1
                let path = relative.isEmpty ? name : relative + "/" + name
                let parsed = BinderIndex.parse(name, isFolder: isFolder)
                var item = BinderItem(path: path, name: name, isFolder: isFolder, index: parsed.index, title: parsed.title)
                item.isPlaceholder = !isFolder && BinderPlaceholder.isPlaceholder(name)
                item.tags = values?.tagNames ?? []
                if isFolder { item.children = read(url, path) }
                out.append(item)
            }
            return out
        }

        tree.items = read(tree.root, "")
        return tree
    }

    /// Folders that are a person's general-purpose places, not a client's binder: a trial balance
    /// saved there doesn't make everything beside it a workpaper.
    public static func isLikelyBinder(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        let home = NSHomeDirectory()
        let general = [home, home + "/Desktop", home + "/Documents", home + "/Downloads", "/", "/Applications", "/tmp", "/private/tmp"]
        return !general.contains(path)
    }
}

// MARK: - Renaming and renumbering

/// One item's move from a path to another, both relative to the binder folder.
public struct BinderRename: Equatable, Sendable {
    public var from: String
    public var to: String
    public var isFolder: Bool

    public init(from: String, to: String, isFolder: Bool = false) {
        self.from = from
        self.to = to
        self.isFolder = isFolder
    }
}

/// Where a dragged file is let go.
public enum BinderDrop: Equatable, Sendable {
    /// Above this file: it goes in at that file's number.
    case before(String)
    /// Below this file: it goes in at the number after.
    case after(String)
    /// On this item. On a file, it takes that file's index and the file loses it. On a folder, it is filed there.
    case onto(String)

    public var target: String {
        switch self {
        case .before(let p), .after(let p), .onto(let p): return p
        }
    }
}

public enum BinderIndexConflict: Sendable {
    /// The item that has the number loses its index.
    case replace
    /// The item that has the number, and those after it, move up by one.
    case insert
}

public enum BinderIndexer {

    private static func rename(_ item: BinderItem, to index: BinderIndex?) -> BinderRename? {
        let name = index.map { $0.text + " " + item.title } ?? item.title
        guard name != item.name else { return nil }
        let parent = item.parentPath
        return BinderRename(from: item.path, to: parent.isEmpty ? name : parent + "/" + name, isFolder: item.isFolder)
    }

    private static func rename(_ item: BinderItem, to index: BinderIndex?, in folder: String) -> BinderRename? {
        let name = index.map { $0.text + " " + item.title } ?? item.title
        let to = folder.isEmpty ? name : folder + "/" + name
        return to == item.path ? nil : BinderRename(from: item.path, to: to, isFolder: item.isFolder)
    }

    private static func sameSlot(_ a: BinderIndex, _ b: BinderIndex) -> Bool { a.prefix == b.prefix && a.suffix == b.suffix }

    /// The item (of the same kind) that already has this index, if any.
    public static func holder(of index: BinderIndex, isFolder: Bool, in tree: BinderTree, except path: String? = nil) -> BinderItem? {
        tree.all.first { $0.isFolder == isFolder && $0.path != path && $0.index.map { sameSlot($0, index) } == true }
    }

    /// The next free index for a file in a folder: the folder's own number, then one more than
    /// the highest suffix used with it. Nil when the folder has no number to build on.
    public static func nextFileIndex(in folderPath: String, tree: BinderTree, taking extra: Int = 0) -> BinderIndex? {
        guard let folder = tree.item(folderPath), let prefix = folder.index?.prefix else { return nil }
        let used = tree.files.compactMap { $0.index }.filter { $0.prefix == prefix }.compactMap(\.suffix)
        let width = max(2, tree.files.compactMap { $0.index }.filter { $0.prefix == prefix }.map(\.width).max() ?? 2)
        return BinderIndex(prefix: prefix, suffix: (used.max() ?? 0) + 1 + extra, width: width)
    }

    /// A number to suggest for a folder that has none: ten past the highest number among the
    /// folders beside it (or past its parent's own number).
    public static func suggestedFolderIndex(for folderPath: String, tree: BinderTree) -> BinderIndex? {
        let parent = (folderPath as NSString).deletingLastPathComponent
        let siblings = tree.children(of: parent).filter { $0.isFolder && $0.path != folderPath }.compactMap { $0.index }
        let base = siblings.compactMap { Int($0.prefix) }.max() ?? tree.item(parent)?.index.flatMap { Int($0.prefix) }
        guard var n = base else { return nil }
        let width = siblings.map(\.prefix.count).max() ?? tree.item(parent)?.index?.prefix.count ?? 4
        repeat { n += 10 } while holder(of: BinderIndex(prefix: pad(n, width)), isFolder: true, in: tree) != nil
        return BinderIndex(prefix: pad(n, width))
    }

    private static func pad(_ n: Int, _ width: Int) -> String {
        let s = String(n)
        return String(repeating: "0", count: max(0, width - s.count)) + s
    }

    /// Gives an item an index. If another item has it, that item either loses its index or it —
    /// and whatever follows it without a gap — moves up by one, so no two ever share a number.
    /// Renumbering a folder renumbers the files inside that carry its number.
    public static func setIndex(_ index: BinderIndex, on path: String, in tree: BinderTree, conflict: BinderIndexConflict = .insert) -> [BinderRename] {
        guard let item = tree.item(path) else { return [] }
        var out: [BinderRename] = []
        // New index for every item that has to move, by path.
        var changes: [String: BinderIndex?] = [path: index]

        if let other = holder(of: index, isFolder: item.isFolder, in: tree, except: path) {
            switch conflict {
            case .replace:
                changes[other.path] = .some(nil)
            case .insert:
                // Walk up from the wanted number; each item in the way moves to the next one.
                var moving: BinderItem? = other
                var slot = index
                while let m = moving {
                    slot = next(after: slot)
                    changes[m.path] = slot
                    moving = holder(of: slot, isFolder: item.isFolder, in: tree, except: path).flatMap { changes[$0.path] == nil ? $0 : nil }
                }
            }
        }

        for (p, target) in changes {
            guard let i = tree.item(p) else { continue }
            if i.isFolder, let target, let old = i.index, old.prefix != target.prefix {
                // The files inside that carry the folder's number follow it.
                for child in i.children where !child.isFolder && child.index?.prefix == old.prefix {
                    let moved = BinderIndex(prefix: target.prefix, suffix: child.index!.suffix, width: child.index!.width)
                    let name = moved.text + " " + child.title
                    let folderName = target.text + " " + i.title
                    let parent = i.parentPath
                    out.append(BinderRename(from: child.path, to: (parent.isEmpty ? folderName : parent + "/" + folderName) + "/" + name))
                }
            }
            if let r = rename(i, to: target) { out.append(r) }
        }
        return ordered(out)
    }

    private static func next(after index: BinderIndex) -> BinderIndex {
        if let s = index.suffix { return BinderIndex(prefix: index.prefix, suffix: s + 1, width: max(index.width, String(s + 1).count)) }
        let n = (Int(index.prefix) ?? 0) + 1
        return BinderIndex(prefix: pad(n, index.prefix.count))
    }

    public static func removeIndex(from path: String, in tree: BinderTree) -> [BinderRename] {
        guard let item = tree.item(path), let r = rename(item, to: nil) else { return [] }
        return [r]
    }

    /// Indexes every unindexed file under a folder (or the whole binder, with ""), each with the
    /// next free number of the folder it is in. Files in a folder that has no number are left.
    public static func indexUnindexed(under folderPath: String, in tree: BinderTree) -> [BinderRename] {
        var out: [BinderRename] = []
        func visit(_ folder: BinderItem) {
            var taken = 0
            for file in folder.children where !file.isFolder && file.index == nil {
                guard let index = nextFileIndex(in: folder.path, tree: tree, taking: taken), let r = rename(file, to: index) else { continue }
                out.append(r)
                taken += 1
            }
            folder.children.filter(\.isFolder).forEach(visit)
        }
        if folderPath.isEmpty {
            tree.items.filter(\.isFolder).forEach(visit)
        } else if let folder = tree.item(folderPath) {
            visit(folder)
        }
        return ordered(out)
    }

    /// Indexes the files among `paths` that have no index, each with the next free number of the
    /// folder it is in, in the order the binder lists them. Files that already have an index,
    /// loose files beside the trial balance, and files in a folder with no number are left.
    public static func index(_ paths: Set<String>, in tree: BinderTree) -> [BinderRename] {
        var taken: [String: Int] = [:]
        var out: [BinderRename] = []
        for item in tree.all where paths.contains(item.path) && !item.isFolder && item.index == nil && !item.parentPath.isEmpty {
            guard let index = nextFileIndex(in: item.parentPath, tree: tree, taking: taken[item.parentPath, default: 0]),
                  let r = rename(item, to: index) else { continue }
            out.append(r)
            taken[item.parentPath, default: 0] += 1
        }
        return ordered(out)
    }

    /// A number for a new folder made inside `parentPath` ("" for the top of the binder). At the
    /// top it is the next thousand after the highest folder there (5000 → 6000); inside a folder
    /// it is ten past the highest folder beside it, or past the folder's own number (5030 → 5040).
    public static func newFolderIndex(in parentPath: String, tree: BinderTree) -> BinderIndex? {
        let siblings = tree.children(of: parentPath).filter(\.isFolder).compactMap { $0.index }
        let numbers = siblings.compactMap { Int($0.prefix) }
        let parent = tree.item(parentPath)?.index
        let top = parentPath.isEmpty
        if !top && parent == nil && numbers.isEmpty { return nil }
        let width = siblings.map(\.prefix.count).max() ?? parent?.prefix.count ?? 4
        let step = top ? 1000 : 10
        var n = numbers.max() ?? parent.flatMap { Int($0.prefix) } ?? 0
        n = top ? (n / step + 1) * step : n + step
        while holder(of: BinderIndex(prefix: pad(n, width)), isFolder: true, in: tree) != nil { n += step }
        return BinderIndex(prefix: pad(n, width))
    }

    /// The name an item has after its title is changed: the index stays in front.
    public static func retitle(_ path: String, to title: String, in tree: BinderTree) -> [BinderRename] {
        guard let item = tree.item(path) else { return [] }
        let clean = title.trimmed
        guard !clean.isEmpty, !clean.contains("/"), !clean.contains(":") else { return [] }
        let name = item.index.map { $0.text + " " + clean } ?? clean
        guard name != item.name else { return [] }
        let parent = item.parentPath
        return [BinderRename(from: path, to: parent.isEmpty ? name : parent + "/" + name, isFolder: item.isFolder)]
    }

    /// Renumbers a folder's indexed files 01, 02, 03… in their present order, closing any gaps.
    public static func closeGaps(in folderPath: String, tree: BinderTree) -> [BinderRename] {
        guard let folder = tree.item(folderPath), let prefix = folder.index?.prefix else { return [] }
        let files = folder.children.filter { !$0.isFolder && $0.index?.prefix == prefix }
            .sorted { ($0.index!.suffix ?? 0, $0.name) < ($1.index!.suffix ?? 0, $1.name) }
        let width = max(2, String(files.count).count)
        return ordered(files.enumerated().compactMap { n, file in rename(file, to: BinderIndex(prefix: prefix, suffix: n + 1, width: width)) })
    }

    /// Moves a file into a folder and gives it that folder's next index.
    public static func file(_ path: String, into folderPath: String, in tree: BinderTree) -> [BinderRename] {
        guard let item = tree.item(path), !item.isFolder, tree.item(folderPath)?.isFolder == true, item.parentPath != folderPath else { return [] }
        let name = nextFileIndex(in: folderPath, tree: tree).map { $0.text + " " + item.title } ?? item.name
        return [BinderRename(from: path, to: folderPath + "/" + name)]
    }

    /// What dragging a file to a new place does, as renames; nothing is changed here.
    ///
    /// - Above or below a file where a number is free between the two files at that spot: it
    ///   takes the first free number there, and nothing else is renamed.
    /// - Above or below a file in the same run of numbers: the files change places and the run
    ///   keeps the numbers it had, so only the files between the two spots are renumbered.
    /// - Above or below a file from somewhere else (another folder, or with no index): it takes
    ///   the number at that spot, and the file there, with any that follow it without a gap,
    ///   moves up by one.
    /// - Onto a file: it takes that file's index and place, and that file is left with no index.
    /// - Onto a folder: it is filed there with the folder's next index.
    public static func move(_ path: String, _ drop: BinderDrop, in tree: BinderTree) -> [BinderRename] {
        guard let item = tree.item(path), !item.isFolder, drop.target != path, let target = tree.item(drop.target) else { return [] }
        if target.isFolder { return drop == .onto(target.path) ? file(path, into: target.path, in: tree) : [] }
        let folder = target.parentPath
        // A file with no index has no number to give up or to sit beside: the dragged file is filed in its folder.
        guard let at = target.index else { return folder.isEmpty ? [] : file(path, into: folder, in: tree) }

        if case .onto = drop {
            let taken = BinderIndex(prefix: at.prefix, suffix: at.suffix, width: at.width)
            return ordered([rename(item, to: taken, in: folder), rename(target, to: nil, in: folder)].compactMap { $0 })
        }
        let below = drop == .after(target.path)
        let run = tree.files.filter { $0.index?.prefix == at.prefix }
            .sorted { ($0.index!.suffix ?? 0, $0.path) < ($1.index!.suffix ?? 0, $1.path) }

        // A free number between the file above the spot and the file below it: take it, and
        // nothing else has to be renumbered.
        let others = run.filter { $0.path != path }
        if let at0 = others.firstIndex(where: { $0.path == target.path }) {
            let spot = below ? at0 + 1 : at0
            let above = spot > 0 ? (others[spot - 1].index!.suffix ?? 0) : 0
            if spot < others.count, let under = others[spot].index!.suffix, under - above > 1 {
                let free = BinderIndex(prefix: at.prefix, suffix: above + 1, width: max(at.width, String(above + 1).count))
                return [rename(item, to: free, in: folder)].compactMap { $0 }
            }
        }

        if item.index?.prefix == at.prefix {
            // Same run: the numbers stay, the files change places.
            var order = run.filter { $0.path != path }
            guard let spot = order.firstIndex(where: { $0.path == target.path }) else { return [] }
            order.insert(item, at: below ? spot + 1 : spot)
            let numbers = run.map { $0.index! }
            return ordered(order.enumerated().compactMap { n, file in
                rename(file, to: numbers[n], in: file.path == path ? folder : file.parentPath)
            })
        }

        var slot = below ? next(after: at) : at
        var out = [rename(item, to: slot, in: folder)].compactMap { $0 }
        var inTheWay = holder(of: slot, isFolder: false, in: tree, except: path)
        var moved = Set<String>()
        while let file = inTheWay, moved.insert(file.path).inserted {
            slot = next(after: slot)
            if let r = rename(file, to: slot, in: file.parentPath) { out.append(r) }
            inTheWay = holder(of: slot, isFolder: false, in: tree, except: path).flatMap { moved.contains($0.path) ? nil : $0 }
        }
        return ordered(out)
    }

    /// The free number at a spot between two files, if there is one: where a file let go there
    /// can land without anything being renumbered.
    public static func freeIndex(at drop: BinderDrop, in tree: BinderTree) -> BinderIndex? {
        guard let target = tree.item(drop.target), !target.isFolder, let at = target.index, drop != .onto(target.path) else { return nil }
        let run = tree.files.filter { $0.index?.prefix == at.prefix }
            .sorted { ($0.index!.suffix ?? 0, $0.path) < ($1.index!.suffix ?? 0, $1.path) }
        guard let at0 = run.firstIndex(where: { $0.path == target.path }) else { return nil }
        let spot = drop == .after(target.path) ? at0 + 1 : at0
        let above = spot > 0 ? (run[spot - 1].index!.suffix ?? 0) : 0
        guard spot < run.count, let under = run[spot].index!.suffix, under - above > 1 else { return nil }
        return BinderIndex(prefix: at.prefix, suffix: above + 1, width: max(at.width, String(above + 1).count))
    }

    /// Names for files being brought into a folder, numbered from `start` in the order given,
    /// and the renames that make room: files already at those numbers, and any that follow them
    /// without a gap, move up past the new ones. With no `start` the files keep their names.
    public static func place(_ names: [String], at start: BinderIndex?, in tree: BinderTree) -> (names: [String], renames: [BinderRename]) {
        guard let start, let first = start.suffix, !names.isEmpty else { return (names, []) }
        let width = max(start.width, String(first + names.count - 1).count)
        let placed = names.enumerated().map { n, name in
            BinderIndex(prefix: start.prefix, suffix: first + n, width: width).text + " " + BinderIndex.parse(name, isFolder: false).title
        }
        var free = first + names.count
        var renames: [BinderRename] = []
        let run = tree.files.filter { $0.index?.prefix == start.prefix && ($0.index!.suffix ?? 0) >= first }
            .sorted { ($0.index!.suffix ?? 0, $0.path) < ($1.index!.suffix ?? 0, $1.path) }
        for file in run {
            guard (file.index!.suffix ?? 0) < free else { break }
            if let r = rename(file, to: BinderIndex(prefix: start.prefix, suffix: free, width: max(file.index!.width, String(free).count)), in: file.parentPath) { renames.append(r) }
            free += 1
        }
        return (placed, ordered(renames))
    }

    /// Files before folders, deepest first: the order they can be carried out in.
    private static func ordered(_ list: [BinderRename]) -> [BinderRename] {
        list.sorted { a, b in
            if a.isFolder != b.isFolder { return !a.isFolder }
            let da = a.from.split(separator: "/").count, db = b.from.split(separator: "/").count
            return da != db ? da > db : a.from < b.from
        }
    }
}

public enum BinderFileOps {

    /// Carries out renames on disk. Every item first steps aside to a temporary name, so swaps
    /// and shifts never collide, and nothing is ever overwritten: if a target exists that isn't
    /// part of the change, everything is put back and the change is refused.
    public static func apply(_ renames: [BinderRename], root: URL) throws {
        let fm = FileManager.default
        guard !renames.isEmpty else { return }
        let folderMoves = renames.filter(\.isFolder)
        /// Where a path is once the folders in this change have been renamed.
        func afterFolders(_ path: String) -> String {
            for f in folderMoves where path == f.from || path.hasPrefix(f.from + "/") { return f.to + path.dropFirst(f.from.count) }
            return path
        }
        let sources = Set(renames.map(\.from))
        for r in renames {
            guard fm.fileExists(atPath: root.appendingPathComponent(r.from).path) else { throw TBError("“\(r.from)” isn't there any more. Refresh the binder and try again.") }
            // The target is free if nothing is there, or what is there is itself being moved away
            // (or is this same item, when only the capitals in its name change).
            let occupied = fm.fileExists(atPath: root.appendingPathComponent(r.to).path) && !sources.contains(r.to)
                && r.to.lowercased() != r.from.lowercased()
            if occupied { throw TBError("There is already an item named “\((r.to as NSString).lastPathComponent)” there.") }
        }

        // Files first, inside the folders as they are named now; then the folders.
        var done: [(URL, URL)] = []
        func move(_ a: URL, _ b: URL) throws {
            try fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: a, to: b)
            done.append((a, b))
        }
        do {
            let tag = ".tbtool-moving-" + UUID().uuidString.prefix(8) + "-"
            for group in [renames.filter { !$0.isFolder }, folderMoves] {
                var staged: [(URL, URL)] = []
                for r in group {
                    let from = root.appendingPathComponent(r.from)
                    // A file whose folder is also being renamed is renamed in place; the folder carries it.
                    let sameFolderAfter = afterFolders((r.from as NSString).deletingLastPathComponent) == (r.to as NSString).deletingLastPathComponent
                    let final = (!r.isFolder && sameFolderAfter)
                        ? from.deletingLastPathComponent().appendingPathComponent((r.to as NSString).lastPathComponent)
                        : root.appendingPathComponent(r.to)
                    let temp = from.deletingLastPathComponent().appendingPathComponent(tag + from.lastPathComponent)
                    try move(from, temp)
                    staged.append((temp, final))
                }
                for (temp, final) in staged { try move(temp, final) }
            }
        } catch {
            for (a, b) in done.reversed() { try? fm.moveItem(at: b, to: a) }
            throw TBError("Couldn't rename: \(error.localizedDescription)")
        }
    }

    /// Removes Finder tags (and the coloured label older tags left) from a file.
    public static func removeTags(from url: URL) {
        try? (url as NSURL).setResourceValue([String](), forKey: .tagNamesKey)
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            removexattr(path, "com.apple.metadata:_kMDItemUserTags", 0)
            // The label colour lives in three bits of the Finder info.
            var info = [UInt8](repeating: 0, count: 32)
            let n = getxattr(path, "com.apple.FinderInfo", &info, 32, 0, 0)
            if n == 32, info[9] & 0x0E != 0 {
                info[9] &= ~0x0E
                if info.allSatisfy({ $0 == 0 }) {
                    removexattr(path, "com.apple.FinderInfo", 0)
                } else {
                    setxattr(path, "com.apple.FinderInfo", info, 32, 0, 0)
                }
            }
        }
    }
}

extension Engagement {
    /// Keeps journal entries' linked files, and workpaper sign-offs, pointing at binder items
    /// that were renamed or moved. Returns how many links changed.
    @discardableResult
    public mutating func relink(after renames: [BinderRename]) -> Int {
        var n = 0
        let files = Dictionary(renames.filter { !$0.isFolder }.map { ($0.from, $0.to) }, uniquingKeysWith: { a, _ in a })
        let folders = renames.filter(\.isFolder)
        for i in signOffs.indices {
            let path = signOffs[i].path
            if let to = files[path] {
                signOffs[i].path = to
            } else if let f = folders.first(where: { path.hasPrefix($0.from + "/") }) {
                signOffs[i].path = f.to + path.dropFirst(f.from.count)
            }
        }
        for i in journalEntries.indices {
            for j in journalEntries[i].references.indices {
                let path = journalEntries[i].references[j].path
                if let to = files[path] {
                    journalEntries[i].references[j].path = to
                    n += 1
                } else if let f = folders.first(where: { path.hasPrefix($0.from + "/") }) {
                    journalEntries[i].references[j].path = f.to + path.dropFirst(f.from.count)
                    n += 1
                }
            }
        }
        return n
    }
}

// MARK: - Rolling the binder forward

public enum BinderRollChoice: String, CaseIterable, Sendable {
    /// Bring it into next year's binder: a folder is created, a file is copied (without its Finder tags).
    case copy
    /// Leave an empty stand-in with the file's name, noting where last year's file is.
    case placeholder
    /// Don't bring it.
    case skip
}

public struct BinderRollResult: Equatable, Sendable {
    public var folders = 0
    public var copied = 0
    public var placeholders = 0
    /// Items that were already in the destination and were left as they were.
    public var alreadyThere: [String] = []
    /// Files that have a different name in the new binder (a document left as a placeholder).
    public var renamed: [BinderRename] = []
}

public enum BinderRoller {

    /// What each item does unless the person says otherwise: everything rolls forward, and a
    /// stand-in that was never replaced stays a stand-in.
    public static func defaultChoices(_ tree: BinderTree) -> [String: BinderRollChoice] {
        var out: [String: BinderRollChoice] = [:]
        for i in tree.all { out[i.path] = i.isPlaceholder ? .placeholder : .copy }
        return out
    }

    /// The choice that takes effect for an item: its own, unless a folder above it is skipped.
    public static func effective(_ path: String, _ choices: [String: BinderRollChoice]) -> BinderRollChoice {
        var parent = (path as NSString).deletingLastPathComponent
        while !parent.isEmpty {
            if choices[parent] == .skip { return .skip }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return choices[path] ?? .copy
    }

    /// Where next year's binder goes by default: beside this one, named for the new year.
    public static func defaultDestination(for root: URL, fromYear: Int, toYear: Int) -> URL {
        let name = root.lastPathComponent
        let parent = root.deletingLastPathComponent()
        if name.contains(String(fromYear)) { return parent.appendingPathComponent(name.replacingOccurrences(of: String(fromYear), with: String(toYear)), isDirectory: true) }
        return parent.appendingPathComponent("\(name) \(toYear)", isDirectory: true)
    }

    /// Builds next year's binder folder from this one. Nothing in the source is changed, and
    /// nothing already in the destination is overwritten.
    @discardableResult
    public static func roll(_ tree: BinderTree, to destination: URL, choices: [String: BinderRollChoice]) throws -> BinderRollResult {
        let fm = FileManager.default
        var result = BinderRollResult()
        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for item in tree.all {
                let choice = effective(item.path, choices)
                if choice == .skip { continue }
                let source = tree.url(item)
                if item.isFolder {
                    let target = destination.appendingPathComponent(item.path, isDirectory: true)
                    if !fm.fileExists(atPath: target.path) {
                        try fm.createDirectory(at: target, withIntermediateDirectories: true)
                        result.folders += 1
                    }
                    continue
                }
                let folder = destination.appendingPathComponent(item.parentPath, isDirectory: true)
                let name = choice == .placeholder ? BinderPlaceholder.name(for: item.name) : item.name
                let target = folder.appendingPathComponent(name)
                if fm.fileExists(atPath: target.path) {
                    result.alreadyThere.append(item.parentPath.isEmpty ? name : item.parentPath + "/" + name)
                    continue
                }
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                if choice == .placeholder {
                    // Empty but for where last year's file is (and, for a stand-in rolled again, what it pointed to).
                    var text = source.path + "\n"
                    if item.isPlaceholder, let earlier = try? String(contentsOf: source, encoding: .utf8), !earlier.trimmed.isEmpty { text += earlier.trimmed + "\n" }
                    try Data(text.utf8).write(to: target, options: .atomic)
                    result.placeholders += 1
                    if name != item.name { result.renamed.append(BinderRename(from: item.path, to: item.parentPath.isEmpty ? name : item.parentPath + "/" + name)) }
                } else {
                    try fm.copyItem(at: source, to: target)
                    // A rolled-forward file starts the year unreviewed: no Finder tags.
                    BinderFileOps.removeTags(from: target)
                    result.copied += 1
                }
            }
        } catch {
            throw TBError("Couldn't roll the binder forward: \(error.localizedDescription)")
        }
        return result
    }
}
