import Foundation

/// A chart of accounts carried between trial balance files: accounts with their types and
/// groupings, plus the grouping list they refer to. Accounts without numbers are matched by name.
public struct ChartData: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var number: String
        public var name: String
        public var type: AccountType?
        public var groupingID: String?
        public var groupingCode: String?
        public var groupingName: String?
        public var groupingSection: String?
        /// A grouping given as free text ("L01", "815-MGMT", "L01 CASH") — resolved against the target's list.
        public var groupingText: String?

        public init(number: String, name: String, type: AccountType? = nil) {
            self.number = number
            self.name = name
            self.type = type
        }

        public var id: String { number.isEmpty ? name : number }
        public var display: String { number.isEmpty ? name : (name.isEmpty ? number : "\(number) \(name)") }
        var hasGrouping: Bool { groupingID != nil || groupingCode != nil || groupingName != nil || groupingText != nil }
    }

    public var name: String
    public var accounts: [Entry]
    public var groupings: [Grouping]

    public init(name: String, accounts: [Entry], groupings: [Grouping] = []) {
        self.name = name
        self.accounts = accounts
        self.groupings = groupings
    }
}

public struct ChartImportOptions: Equatable, Sendable {
    /// Give matched accounts the source's grouping.
    public var applyGroupings = true
    /// Replace groupings this file already has. Off: only ungrouped accounts are filled in.
    public var overwriteGroupings = false
    /// Give matched accounts the source's account type.
    public var applyTypes = true
    /// Add source accounts this file doesn't have yet.
    public var addMissing = false

    public init() {}
}

public struct ChartImportPlan: Equatable, Sendable {
    public struct Change: Equatable, Identifiable, Sendable {
        public var accountID: String
        public var display: String
        public var oldGrouping: String?
        public var newGrouping: String?
        public var oldType: AccountType
        public var newType: AccountType
        public var id: String { accountID }
    }

    public var changes: [Change] = []
    public var added: [Account] = []
    public var newGroupings: [Grouping] = []
    /// Matched accounts whose existing grouping differs from the source and was kept.
    public var keptExisting: [String] = []
    /// Source accounts with no match here (and not added).
    public var unmatched: [String] = []
    /// Source groupings that couldn't be found in, or added to, this file's list.
    public var unresolved: [String] = []
    public var matched = 0

    public var isEmpty: Bool { changes.isEmpty && added.isEmpty && newGroupings.isEmpty }
    public var groupingChanges: Int { changes.filter { $0.oldGrouping != $0.newGrouping }.count }
    public var typeChanges: Int { changes.filter { $0.oldType != $0.newType }.count }
}

public enum ChartTransfer {
    public static let fileType = "chart-of-accounts"

    // MARK: Export

    public static func chart(of e: Engagement) -> ChartData {
        ChartData(name: e.name, accounts: e.sortedAccounts.map { a in
            var x = ChartData.Entry(number: a.number, name: a.name, type: a.type)
            if let g = e.grouping(a.grouping) {
                x.groupingID = g.id
                x.groupingCode = e.groupingCode(g.id)  // a subgroup with no code of its own reports under its grouping's
                x.groupingName = g.name
                x.groupingSection = g.section
            }
            return x
        }, groupings: e.groupings)
    }

    public static func json(_ c: ChartData) -> Data {
        let doc = JSONValue.object([
            JSONField("fileType", .string(fileType)),
            JSONField("schemaVersion", .int(2)),
            JSONField("name", .string(c.name)),
            JSONField("exportedAt", .string(Timestamp.now())),
            JSONField("accounts", .array(c.accounts.map { x in
                .object([
                    JSONField("number", .string(x.number)),
                    JSONField("name", .string(x.name)),
                    JSONField("type", x.type.map { .string($0.rawValue) } ?? .null),
                    JSONField("grouping", x.groupingID.map { .string($0) } ?? .null),
                ])
            })),
            JSONField("groupings", .array(c.groupings.map(Store.json))),
        ])
        return Data(doc.render().utf8)
    }

    public static func csv(_ c: ChartData) -> String {
        var t = ReportTable(title: "", subtitle: "", sheetName: "Chart", flat: true,
                            columns: ["Account Number", "Account Name", "Type", "Grouping ID", "Grouping Code", "Grouping Name", "Grouping Section"]
                                .map { .text($0, 100) })
        for x in c.accounts {
            t.rows.append(ReportRow(id: x.id, cells: [x.number, x.name, x.type?.label ?? "", x.groupingID ?? "", x.groupingCode ?? "",
                                                      x.groupingName ?? "", x.groupingSection ?? ""].map { .text($0) }))
        }
        return Exporter.csv(t)
    }

    // MARK: Read

    /// Reads a chart from a chart JSON, a whole trial balance JSON, or a table (CSV, Excel, text)
    /// with columns such as Account, Name, Type, Grouping.
    public static func read(url: URL) throws -> ChartData {
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

    public static func decodeJSON(_ data: Data, name: String) throws -> ChartData {
        guard let any = try? JSONSerialization.jsonObject(with: data), let root = any as? [String: Any] else {
            throw TBError("\(name) isn't valid JSON.")
        }
        switch root["fileType"] as? String {
        case Store.fileType:
            return chart(of: try Store.decode(data))
        case fileType:
            var groupings: [Grouping] = []
            for (i, item) in ((root["groupings"] as? [Any]) ?? []).enumerated() {
                groupings.append(try Store.decodeGrouping(item, path: "groupings[\(i)]"))
            }
            if ((root["schemaVersion"] as? Int) ?? 1) < 2 { groupings = Engagement.fillingStandardTypes(groupings) }
            groupings = Engagement.mergingSharedCodes(groupings)  // charts exported before codes had to be unique
            let byID = Dictionary(groupings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var accounts: [ChartData.Entry] = []
            for (i, item) in ((root["accounts"] as? [Any]) ?? []).enumerated() {
                let o = try JSONObject(item, "accounts[\(i)]")
                var x = ChartData.Entry(number: o.optString("number"), name: o.optString("name"), type: AccountType(rawValue: o.optString("type")))
                if x.number.isEmpty && x.name.isEmpty { continue }
                if let gid = o.optStringOrNil("grouping") {
                    x.groupingID = gid
                    if let g = byID[gid] {
                        x.groupingCode = g.code.isEmpty ? (g.parent.flatMap { byID[$0]?.code } ?? "") : g.code
                        x.groupingName = g.name
                        x.groupingSection = g.section
                    }
                }
                accounts.append(x)
            }
            return ChartData(name: (root["name"] as? String) ?? name, accounts: accounts, groupings: groupings)
        default:
            throw TBError("\(name) isn't a chart of accounts or a trial balance file.")
        }
    }

    public static func fromTable(_ rows: [[String]], name: String) throws -> ChartData {
        func norm(_ s: String) -> String { s.trimmed.lowercased() }
        let headerAt = rows.prefix(15).firstIndex { row in
            row.contains { let c = norm($0); return c.contains("account") || c.contains("acct") || c.contains("grouping") || c == "name" }
        }
        var number: Int?, nameCol: Int?, combined: Int?, type: Int?, gid: Int?, gcode: Int?, gname: Int?, gsection: Int?, gtext: Int?
        if let h = headerAt {
            for (i, raw) in rows[h].enumerated() {
                let c = norm(raw)
                let grouping = c.contains("group") || c.contains("tax line") || c.contains("mapping") || c.contains("lead")
                if grouping {
                    if c.contains("id") && gid == nil { gid = i } else if c.contains("code") && gcode == nil { gcode = i } else if c.contains("section") && gsection == nil {
                        gsection = i
                    } else if c.contains("name") && gname == nil { gname = i } else if gtext == nil { gtext = i }
                } else if c == "type" || c == "account type" {
                    type = i
                } else if (c.contains("number") || c.contains(" no") || c.hasSuffix("#") || c == "no" || c == "code") && number == nil {
                    number = i
                } else if (c.contains("name") || c.contains("description") || c.contains("title")) && nameCol == nil {
                    nameCol = i
                } else if (c.contains("account") || c.contains("acct")) && combined == nil {
                    combined = i
                }
            }
        } else if rows.first.map({ $0.count >= 2 }) == true {
            combined = 0
            gtext = 1
        }
        guard number != nil || nameCol != nil || combined != nil else {
            throw TBError("\(name): couldn't find an account column. Use headings like Account, Name, Type, Grouping.")
        }
        var out: [ChartData.Entry] = []
        for row in rows.dropFirst((headerAt ?? -1) + 1) {
            func cell(_ i: Int?) -> String? {
                guard let i, i < row.count else { return nil }
                let t = row[i].trimmed
                return t.isEmpty ? nil : t
            }
            var num = cell(number) ?? "", nm = cell(nameCol) ?? ""
            if let c = cell(combined) {
                let s = TBImporter.splitAccount(c)
                if num.isEmpty { num = s.number }
                if nm.isEmpty { nm = s.name.isEmpty ? (s.number.isEmpty ? c : "") : s.name }
            }
            if num.isEmpty && nm.isEmpty { continue }
            var x = ChartData.Entry(number: num, name: nm.isEmpty ? num : nm,
                                    type: cell(type).flatMap { t in AccountType.allCases.first { $0.rawValue == t.lowercased() || $0.label.lowercased() == t.lowercased() } })
            x.groupingID = cell(gid)
            x.groupingCode = cell(gcode)
            x.groupingName = cell(gname)
            x.groupingSection = cell(gsection)
            x.groupingText = cell(gtext)
            out.append(x)
        }
        return ChartData(name: name, accounts: out)
    }
}

extension Engagement {

    /// The account here that a source chart line refers to: same number, or — when the source
    /// line has no number — same name.
    func matchAccount(_ x: ChartData.Entry) -> Account? {
        if !x.number.isEmpty {
            if let a = account(x.number) { return a }
            return accounts.first { !$0.number.isEmpty && $0.number.caseInsensitiveCompare(x.number) == .orderedSame }
        }
        let n = x.name.trimmed
        return accounts.first { $0.number.isEmpty && $0.name.caseInsensitiveCompare(n) == .orderedSame }
            ?? accounts.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }
    }

    /// What importing a chart would change, without changing anything.
    public func planChartImport(_ source: ChartData, options: ChartImportOptions = ChartImportOptions()) -> ChartImportPlan {
        var plan = ChartImportPlan()
        var pending: [Grouping] = []

        func resolve(_ x: ChartData.Entry) -> String? {
            let all = groupings + pending
            /// The code a grouping reports under: its own, or its parent's for a subgroup without one.
            func reportingCode(_ g: Grouping) -> String {
                g.code.isEmpty ? (g.parent.flatMap { p in all.first { $0.id == p }?.code } ?? "") : g.code
            }
            func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
            if let id = x.groupingID, let g = all.first(where: { $0.id == id }),
               x.groupingCode == nil || same(x.groupingCode!, reportingCode(g)) {
                return g.id
            }
            if let code = x.groupingCode, !code.isEmpty {
                let byCode = all.filter { same($0.code, code) }
                if let name = x.groupingName {
                    if let g = byCode.first(where: { same($0.name, name) }) { return g.id }
                    // The grouping with this code may hold it as a subgroup: "815 OTHER - MANAGEMENT FEES".
                    for p in byCode where p.parent == nil {
                        if let s = all.first(where: { $0.parent == p.id && (same($0.name, name) || same("\(p.name) - \($0.name)", name)) }) { return s.id }
                    }
                }
                // A code is used once, so the code alone says which grouping — unless the source says this
                // is a subgroup this file doesn't have yet; that comes across below, under its grouping.
                let isNewSubgroup = x.groupingID.flatMap { id in source.groupings.first { $0.id == id } }?.parent != nil
                if byCode.count == 1 && !isNewSubgroup { return byCode[0].id }
            }
            for text in [x.groupingText, x.groupingName, x.groupingID].compactMap({ $0 }) {
                if let g = resolveGrouping(text) { return g.id }
                if let g = pending.first(where: { $0.id.caseInsensitiveCompare(text) == .orderedSame }) { return g.id }
            }
            // Not in this file's list: bring the source's definition across.
            var def: Grouping? = x.groupingID.flatMap { id in source.groupings.first { $0.id == id } }
            if def == nil, let code = x.groupingCode, let name = x.groupingName {
                def = Grouping(id: code, code: code, name: name, section: x.groupingSection ?? DefaultGroupings.sectionOther)
            }
            guard var g = def else { return nil }
            // A subgroup comes across under the same grouping here, bringing that grouping along if
            // this file doesn't have it; failing that it comes in as a grouping of its own.
            if let pid = g.parent {
                if let p = all.first(where: { $0.id == pid && $0.parent == nil }) {
                    g.section = p.section
                } else if let p = source.groupings.first(where: { $0.id == pid && $0.parent == nil }), !all.contains(where: { $0.id == pid }) {
                    pending.append(p)
                    g.section = p.section
                } else {
                    g.parent = nil
                }
            }
            let base = g.id
            var n = 2
            while (groupings + pending).contains(where: { $0.id == g.id }) {
                g.id = "\(base)-\(n)"
                n += 1
            }
            pending.append(g)
            return g.id
        }

        var seen = Set<String>()
        for x in source.accounts {
            let target = matchAccount(x)
            let groupingID = (options.applyGroupings && x.hasGrouping) ? resolve(x) : nil
            if options.applyGroupings && x.hasGrouping && groupingID == nil {
                plan.unresolved.append("\(x.display): \(x.groupingText ?? x.groupingCode ?? x.groupingID ?? x.groupingName ?? "")")
            }
            if let a = target {
                guard seen.insert(a.id).inserted else { continue }
                plan.matched += 1
                var newGrouping = a.grouping
                if let groupingID, groupingID != a.grouping {
                    if a.grouping == nil || options.overwriteGroupings {
                        newGrouping = groupingID
                    } else {
                        plan.keptExisting.append(a.display)
                    }
                }
                // A grouped account's type is its grouping's; the source's type only matters for an account
                // that stays ungrouped (or sits in an "any type" grouping).
                let all = groupings + pending
                let fromGrouping: AccountType? = newGrouping.flatMap { id in all.first { $0.id == id } }
                    .flatMap { g in g.parent.flatMap { p in all.first { $0.id == p } }?.type ?? g.type }
                let newType = fromGrouping ?? (options.applyTypes ? x.type : nil) ?? a.type
                if newGrouping != a.grouping || newType != a.type {
                    plan.changes.append(.init(accountID: a.id, display: a.display, oldGrouping: a.grouping, newGrouping: newGrouping,
                                              oldType: a.type, newType: newType))
                }
            } else if options.addMissing {
                let a = Account(number: x.number, name: x.name.isEmpty ? x.number : x.name, type: x.type, grouping: groupingID)
                guard account(a.id) == nil, seen.insert(a.id).inserted else { continue }
                plan.added.append(a)
            } else {
                plan.unmatched.append(x.display)
            }
        }
        // Only bring across groupings something actually uses.
        var used = Set(plan.changes.compactMap(\.newGrouping) + plan.added.compactMap(\.grouping))
        used.formUnion(pending.filter { used.contains($0.id) }.compactMap(\.parent))
        plan.newGroupings = pending.filter { used.contains($0.id) }
        return plan
    }

    public mutating func applyChartImport(_ plan: ChartImportPlan) {
        for g in plan.newGroupings where !groupings.contains(where: { $0.id == g.id }) { groupings.append(g) }
        groupings = Engagement.mergingSharedCodes(groupings)
        for c in plan.changes {
            updateAccount(c.accountID) {
                $0.grouping = c.newGrouping
                $0.type = c.newType
            }
        }
        for a in plan.added where account(a.id) == nil { accounts.append(a) }
        accounts.sort(by: accountPrecedes)
        alignAccountTypes()
    }

    /// Account types by account id, for reading signs from a file that shows normal balances as positive.
    public var accountTypes: [String: AccountType] {
        Dictionary(accounts.map { ($0.id, $0.type) }, uniquingKeysWith: { a, _ in a })
    }
}
