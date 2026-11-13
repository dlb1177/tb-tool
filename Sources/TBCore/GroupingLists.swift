import Foundation

/// A grouping list on its own: what gets exported from one trial balance file and imported into
/// another, or kept in the library so new files can start from it (1065, S corporation, …).
public struct GroupingList: Equatable, Sendable {
    public var name: String
    public var groupings: [Grouping]
    /// The entity types (as in the binder: "Partnership (Form 1065)"…) this list is the standard for.
    public var entityTypes: [String] = []

    public init(name: String, groupings: [Grouping], entityTypes: [String] = []) {
        self.name = name
        self.groupings = groupings
        self.entityTypes = entityTypes
    }

    public static let standardName = "Standard (Form 1065 / 8825)"
    /// The list that ships with the app. `GroupingLibrary.standard()` returns the user's changed copy if there is one.
    public static var standard: GroupingList {
        GroupingList(name: standardName, groupings: DefaultGroupings.list, entityTypes: [Binder.entityTypes[0]])
    }
}

public enum GroupingImportMode: String, CaseIterable, Sendable {
    /// The file's list becomes the imported list.
    case replace
    /// Imported groupings are added; ones already here (same id) take the imported code, name and section.
    case merge
}

public struct GroupingImportPlan: Equatable, Sendable {
    public var result: [Grouping] = []
    public var added: [Grouping] = []
    public var updated: [Grouping] = []
    public var removed: [Grouping] = []
    /// Accounts whose grouping moves to a different id in the new list (same code and name).
    public var remapped: [String: String] = [:]
    /// Accounts that lose their grouping because it isn't in the new list.
    public var ungrouped: [Account] = []

    public var isEmpty: Bool { added.isEmpty && updated.isEmpty && removed.isEmpty && remapped.isEmpty }
}

public enum GroupingTransfer {
    public static let fileType = "grouping-list"

    public static func list(of e: Engagement) -> GroupingList {
        GroupingList(name: e.groupingListName.isEmpty ? "\(e.name) groupings" : e.groupingListName, groupings: e.groupings)
    }

    public static func json(_ list: GroupingList) -> Data {
        var fields = [
            JSONField("fileType", .string(fileType)),
            JSONField("schemaVersion", .int(2)),
            JSONField("name", .string(list.name)),
        ]
        if !list.entityTypes.isEmpty { fields.append(JSONField("entityTypes", .array(list.entityTypes.map { .string($0) }))) }
        fields.append(JSONField("groupings", .array(list.groupings.map(Store.json))))
        return Data(JSONValue.object(fields).render().utf8)
    }

    public static func csv(_ list: GroupingList) -> String {
        var t = ReportTable(title: "", subtitle: "", sheetName: "Groupings", flat: true,
                            columns: ["Section", "Code", "Name", "Account Type", "ID", "Subgroup Of"].map { .text($0, 100) })
        for g in list.groupings {
            t.rows.append(ReportRow(id: g.id, cells: [g.section, g.code, g.name, g.type?.label ?? "", g.id, g.parent ?? ""].map { .text($0) }))
        }
        return Exporter.csv(t)
    }

    /// Reads a grouping list from a grouping-list JSON, a chart of accounts export, a whole trial
    /// balance file, or a table (CSV, Excel, text) with Code and Name columns and optionally Section,
    /// ID, and "Subgroup Of" (the id or code of the grouping a subgroup sits under).
    public static func read(url: URL) throws -> GroupingList {
        let name = url.deletingPathExtension().lastPathComponent
        if url.pathExtension.lowercased() == "json" {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw TBError("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
            }
            return try decodeJSON(data, name: name)
        }
        let sheets = try SourceReader.read(url: url)
        return try fromTable(sheets[0].rows, name: name)
    }

    public static func decodeJSON(_ data: Data, name: String) throws -> GroupingList {
        guard let any = try? JSONSerialization.jsonObject(with: data), let root = any as? [String: Any] else {
            throw TBError("\(name) isn't valid JSON.")
        }
        switch root["fileType"] as? String {
        case Store.fileType:
            let e = try Store.decode(data)
            return GroupingList(name: e.groupingListName.isEmpty ? "\(e.name) groupings" : e.groupingListName,
                                groupings: Engagement.mergingSharedCodes(e.groupings))
        case fileType, ChartTransfer.fileType:
            var out: [Grouping] = []
            for (i, item) in ((root["groupings"] as? [Any]) ?? []).enumerated() {
                out.append(try Store.decodeGrouping(item, path: "groupings[\(i)]", defaultSection: DefaultGroupings.sectionOther))
            }
            guard !out.isEmpty else { throw TBError("\(name) has no groupings in it.") }
            // A list exported before groupings had account types (schema 1) takes the built-in types where it matches the built-in list.
            if ((root["schemaVersion"] as? Int) ?? 1) < 2 { out = Engagement.fillingStandardTypes(out) }
            var list = GroupingList(name: (root["name"] as? String) ?? name, groupings: Engagement.mergingSharedCodes(unique(out)))
            list.entityTypes = ((root["entityTypes"] as? [Any]) ?? []).compactMap { $0 as? String }
            return list
        default:
            throw TBError("\(name) isn't a grouping list, a chart of accounts or a trial balance file.")
        }
    }

    public static func fromTable(_ rows: [[String]], name: String) throws -> GroupingList {
        func norm(_ s: String) -> String { s.trimmed.lowercased() }
        let headerAt = rows.prefix(15).firstIndex { row in
            let cells = row.map(norm)
            return cells.contains { $0 == "code" || $0.contains("grouping") || $0 == "name" || $0 == "description" || $0.contains("tax line") }
        }
        var code: Int?, nameCol: Int?, section: Int?, id: Int?, parent: Int?, type: Int?
        if let h = headerAt {
            for (i, raw) in rows[h].enumerated() {
                let c = norm(raw)
                if c.contains("subgroup") || c.contains("parent") {
                    if parent == nil { parent = i }
                } else if c == "type" || c.contains("account type") {
                    if type == nil { type = i }
                } else if c == "id" || c.hasSuffix(" id") {
                    if id == nil { id = i }
                } else if c.contains("section") || c.contains("category") || c.contains("schedule") || c.contains("form") {
                    if section == nil { section = i }
                } else if c.contains("code") || c.contains("number") || c.hasSuffix("#") || c == "line" || c.contains("tax line") {
                    if code == nil { code = i }
                } else if c.contains("name") || c.contains("description") || c.contains("grouping") || c.contains("title") {
                    if nameCol == nil { nameCol = i }
                }
            }
        } else {
            // No headings: code, name, then section if there's a third column.
            code = 0
            nameCol = 1
            if rows.contains(where: { $0.count >= 3 && !$0[2].trimmed.isEmpty }) { section = 2 }
        }
        guard let code, let nameCol else {
            throw TBError("\(name): couldn't find the grouping columns. Use headings like Section, Code, Name.")
        }
        var out: [Grouping] = []
        var lastSection = DefaultGroupings.sectionOther
        for row in rows.dropFirst((headerAt ?? -1) + 1) {
            func cell(_ i: Int?) -> String {
                guard let i, i < row.count else { return "" }
                return row[i].trimmed
            }
            let c = cell(code), n = cell(nameCol), under = cell(parent)
            if !cell(section).isEmpty { lastSection = cell(section) }
            // A subgroup may leave its code blank; everything else needs a code and a name.
            if n.isEmpty || (c.isEmpty && under.isEmpty) { continue }
            let own = cell(id).isEmpty ? (c.isEmpty ? "\(under)/\(Engagement.slug(n).uppercased())" : c) : cell(id)
            out.append(Grouping(id: own, code: c, name: n, section: lastSection, parent: under.isEmpty ? nil : under,
                                type: AccountType.parse(cell(type))))
        }
        guard !out.isEmpty else { throw TBError("\(name): no groupings found. Each row needs a code and a name.") }
        out = unique(out)
        // "Subgroup Of" may name the parent by its id or, when only one grouping has it, by its code.
        let tops = out.filter { $0.parent == nil }
        for i in out.indices {
            guard let under = out[i].parent, !tops.contains(where: { $0.id == under }) else { continue }
            let byCode = tops.filter { $0.code.caseInsensitiveCompare(under) == .orderedSame }
            let byID = tops.filter { $0.id.caseInsensitiveCompare(under) == .orderedSame }
            out[i].parent = byID.first?.id ?? (byCode.count == 1 ? byCode[0].id : under)
        }
        // Rows that share a code come in as one grouping with subgroups, since a code is used once.
        return GroupingList(name: name, groupings: Engagement.mergingSharedCodes(out))
    }

    /// Several groupings may share a code (the "815 Other" lines); each still needs its own id.
    static func unique(_ list: [Grouping]) -> [Grouping] {
        var used = Set<String>()
        return list.map { g in
            var x = g
            if used.contains(x.id) { x.id = "\(g.code)-\(Engagement.slug(g.name).uppercased())" }
            var n = 2
            while used.contains(x.id) {
                x.id = "\(g.code)-\(n)"
                n += 1
            }
            used.insert(x.id)
            return x
        }
    }
}

extension Engagement {

    /// What importing a grouping list would change, without changing anything.
    public func planGroupingImport(_ list: GroupingList, mode: GroupingImportMode) -> GroupingImportPlan {
        var plan = GroupingImportPlan()
        let incoming = Engagement.mergingSharedCodes(GroupingTransfer.unique(list.groupings))
        switch mode {
        case .merge:
            var result = groupings
            // Imported groupings that are here already under another id, by imported id.
            var known: [String: String] = [:]
            for var g in incoming {
                if let pid = g.parent, let here = known[pid] { g.parent = here }
                if let i = result.firstIndex(where: { $0.id == g.id }) {
                    if result[i] != g {
                        result[i] = g
                        plan.updated.append(g)
                    }
                } else if let here = result.first(where: { !g.code.isEmpty && $0.code.caseInsensitiveCompare(g.code) == .orderedSame })
                            ?? result.first(where: { $0.code.caseInsensitiveCompare(g.code) == .orderedSame && $0.parent == g.parent
                                                      && $0.name.caseInsensitiveCompare(g.name) == .orderedSame }) {
                    known[g.id] = here.id  // a code is used once, so this one is already here under another id
                    continue
                } else {
                    if let last = result.lastIndex(where: { $0.section == g.section }) {
                        result.insert(g, at: last + 1)
                    } else {
                        result.append(g)
                    }
                    plan.added.append(g)
                }
            }
            plan.result = Engagement.tidiedGroupings(result)
        case .replace:
            plan.result = incoming
            let newIDs = Set(incoming.map(\.id))
            let oldByID = Dictionary(groupings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            plan.added = incoming.filter { oldByID[$0.id] == nil }
            plan.updated = incoming.filter { g in oldByID[g.id].map { $0 != g } ?? false }
            plan.removed = groupings.filter { !newIDs.contains($0.id) }
            for a in sortedAccounts {
                guard let gid = a.grouping, !newIDs.contains(gid) else { continue }
                // Same code and name under a different id: keep the assignment.
                let twins = oldByID[gid].map { old in
                    incoming.filter { $0.code.caseInsensitiveCompare(old.code) == .orderedSame && $0.name.caseInsensitiveCompare(old.name) == .orderedSame }
                } ?? []
                if twins.count == 1 {
                    plan.remapped[a.id] = twins[0].id
                } else {
                    plan.ungrouped.append(a)
                }
            }
        }
        return plan
    }

    public mutating func applyGroupingImport(_ plan: GroupingImportPlan, name: String? = nil) {
        groupings = plan.result
        let ids = Set(groupings.map(\.id))
        for i in accounts.indices {
            if let to = plan.remapped[accounts[i].id] {
                accounts[i].grouping = to
            } else if let g = accounts[i].grouping, !ids.contains(g) {
                accounts[i].grouping = nil
            }
        }
        if let name, !name.trimmed.isEmpty { groupingListName = name.trimmed }
    }
}

/// The standard grouping lists kept on this Mac: the one that ships with the app (which can be
/// changed and restored) and any others — an S corporation list, next year's version of a form.
/// New trial balance files start from one of them, chosen by entity type.
public enum GroupingLibrary {
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("TB Tool/Grouping Lists", isDirectory: true)
    }

    private static func fileURL(_ name: String, in dir: URL) -> URL {
        let safe = String(name.trimmed.map { "/:\\".contains($0) ? "-" : $0 })
        return dir.appendingPathComponent("\(safe).json")
    }

    /// Every list saved in the folder, by name.
    public static func lists(in dir: URL = defaultURL) -> [GroupingList] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return files.compactMap { try? GroupingTransfer.read(url: $0) }
    }

    /// The built-in list as it stands on this Mac: the changed copy if it has been edited, otherwise as shipped.
    public static func standard(in dir: URL = defaultURL) -> GroupingList {
        lists(in: dir).first { $0.name == GroupingList.standardName } ?? .standard
    }

    public static func isStandardChanged(in dir: URL = defaultURL) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(GroupingList.standardName, in: dir).path)
    }

    /// The standard lists to offer: the built-in one first, then the rest by name.
    public static func all(in dir: URL = defaultURL) -> [GroupingList] {
        let saved = lists(in: dir)
        return [saved.first { $0.name == GroupingList.standardName } ?? .standard] + saved.filter { $0.name != GroupingList.standardName }
    }

    /// The list a new file of this entity type starts from: the one marked as its standard, or the built-in list.
    public static func list(forEntityType type: String, in dir: URL = defaultURL) -> GroupingList {
        let lists = all(in: dir)
        let wanted = type.trimmed.lowercased()
        return lists.first { $0.entityTypes.contains { $0.lowercased() == wanted } } ?? lists[0]
    }

    @discardableResult
    public static func save(_ list: GroupingList, in dir: URL = defaultURL) throws -> URL {
        let name = list.name.trimmed
        guard !name.isEmpty else { throw TBError("Give the grouping list a name.") }
        if let (code, sharing) = Engagement.sharedCodes(list.groupings).first {
            throw TBError("Code \(code) is used by \(sharing.count) groupings. Every grouping and subgroup needs its own code.")
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = fileURL(name, in: dir)
            try GroupingTransfer.json(GroupingList(name: name, groupings: list.groupings, entityTypes: list.entityTypes)).write(to: url, options: .atomic)
            return url
        } catch {
            throw TBError("Couldn't save the grouping list: \(error.localizedDescription)")
        }
    }

    /// Removes a saved list. For the built-in list this throws away the changes and brings back the list as shipped.
    public static func delete(named name: String, in dir: URL = defaultURL) {
        try? FileManager.default.removeItem(at: fileURL(name, in: dir))
    }

    /// Makes `name` the standard for an entity type (and no other list), or with nil clears it.
    public static func setStandard(_ name: String?, forEntityType type: String, in dir: URL = defaultURL) throws {
        for var list in all(in: dir) {
            let had = list.entityTypes.contains(type)
            let wants = list.name == name
            guard had != wants else { continue }
            if wants { list.entityTypes.append(type) } else { list.entityTypes.removeAll { $0 == type } }
            try save(list, in: dir)
        }
    }
}
