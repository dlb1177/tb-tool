import Foundation

/// Reads and writes the trial balance JSON file.
///
/// The file identifies itself with `"fileType": "trial-balance"`. Amounts are written as plain
/// two-decimal numbers split into debit / credit, one record per line, in a fixed key order.
public enum Store {
    public static let fileType = "trial-balance"
    public static let schemaVersion = 5

    private static let knownKeys: Set<String> = [
        "fileType", "schemaVersion", "name", "periodEnd", "binder", "groupingListName", "rolledForwardFrom",
        "entities", "journalEntries", "accounts", "groupings", "signOffs", "auditLog",
    ]

    // MARK: Files

    public static func load(_ url: URL) throws -> Engagement {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw TBError("Couldn't read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        return try decode(data)
    }

    public static func save(_ engagement: Engagement, to url: URL) throws {
        do {
            try encode(engagement).write(to: url, options: .atomic)
        } catch {
            throw TBError("Couldn't save \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Cheap check used when scanning a folder: is this a JSON file that says it is a trial balance?
    public static func looksLikeTrialBalance(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "json",
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 2048),
              let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1) else { return false }
        let compact = text.filter { !$0.isWhitespace }
        return compact.contains("\"fileType\":\"\(fileType)\"")
    }

    // MARK: Encode

    public static func encode(_ e: Engagement) -> Data {
        Data(json(e).render().utf8)
    }

    public static func json(_ e: Engagement) -> JSONValue {
        var fields: [JSONField] = [
            JSONField("fileType", .string(fileType)),
            JSONField("schemaVersion", .int(schemaVersion)),
            JSONField("name", .string(e.name)),
            JSONField("periodEnd", .string(e.periodEnd)),
            JSONField("binder", json(e.binder)),
        ]
        if !e.groupingListName.isEmpty { fields.append(JSONField("groupingListName", .string(e.groupingListName))) }
        if !e.rolledForwardFrom.isEmpty { fields.append(JSONField("rolledForwardFrom", .string(e.rolledForwardFrom))) }
        fields += [
            JSONField("entities", .array(e.entities.map(json))),
            JSONField("journalEntries", .array(e.journalEntries.map(json))),
            JSONField("accounts", .array(e.accounts.map(json))),
            JSONField("groupings", .array(e.groupings.map(json))),
        ]
        if !e.signOffs.isEmpty {
            fields.append(JSONField("signOffs", .array(e.signOffs.map { s in
                .object([JSONField("path", .string(s.path)), JSONField("level", .string(s.level.rawValue)), JSONField("at", .string(s.at)),
                         JSONField("by", json(s.actor)), JSONField("fileHash", .string(s.fileHash))])
            })))
        }
        if !e.auditLog.isEmpty {
            fields.append(JSONField("auditLog", .array(e.auditLog.map { a in
                .object([JSONField("at", .string(a.at)), JSONField("action", .string(a.action)),
                         JSONField("details", .array(a.details.map { .string($0) })), JSONField("by", json(a.actor)), JSONField("hash", .string(a.hash))])
            })))
        }
        fields.append(contentsOf: e.extras)
        return .object(fields)
    }

    static func json(_ a: Actor) -> JSONValue {
        .object([JSONField("name", .string(a.name)), JSONField("account", .string(a.account)),
                 JSONField("computer", .string(a.computer)), JSONField("device", .string(a.device))])
    }

    static func actor(_ any: Any?, _ path: String) throws -> Actor {
        guard let any else { return Actor(name: "", account: "", computer: "", device: "") }
        let o = try JSONObject(any, path)
        return Actor(name: o.optString("name"), account: o.optString("account"), computer: o.optString("computer"), device: o.optString("device"))
    }

    static func json(_ b: Binder) -> JSONValue {
        .object([
            JSONField("clientNumber", .string(b.clientNumber)),
            JSONField("engagement", .string(b.engagement)),
            JSONField("entityType", .string(b.entityType)),
            JSONField("taxID", .string(b.taxID)),
            JSONField("firm", .string(b.firm)),
            JSONField("preparedBy", .string(b.preparedBy)),
            JSONField("reviewedBy", .string(b.reviewedBy)),
        ])
    }

    static func json(_ ent: Entity) -> JSONValue {
        var fields = [
            JSONField("id", .string(ent.id)),
            JSONField("name", .string(ent.name)),
            JSONField("source", .string(ent.source)),
            JSONField("importedAt", .string(ent.importedAt)),
        ]
        if !ent.editedAt.isEmpty { fields.append(JSONField("editedAt", .string(ent.editedAt))) }
        if !ent.activityNumber.isEmpty { fields.append(JSONField("activityNumber", .string(ent.activityNumber))) }
        fields.append(JSONField("balances", .array(ent.balances.map { b in
            .object([
                JSONField("account", .string(b.account)),
                JSONField("debit", .money(b.amount.debit)),
                JSONField("credit", .money(b.amount.credit)),
            ])
        })))
        if !ent.priorPeriods.isEmpty {
            // Prior years are closing figures, written signed: debits positive, credits negative.
            fields.append(JSONField("priorPeriods", .array(ent.priorPeriods.map { p in
                .object([
                    JSONField("year", .int(p.year)),
                    JSONField("source", .string(p.source)),
                    JSONField("importedAt", .string(p.importedAt)),
                    JSONField("balances", .array(p.balances.map { b in
                        .object([
                            JSONField("account", .string(b.account)),
                            JSONField("book", .money(b.book)),
                            JSONField("tax", .money(b.tax)),
                            JSONField("elim", .money(b.elim)),
                        ])
                    })),
                ])
            })))
        }
        return .object(fields)
    }

    public static func json(_ je: JournalEntry) -> JSONValue {
        var head = [
            JSONField("id", .string(je.id)),
            JSONField("number", .string(je.number)),
            JSONField("type", .string(je.type.rawValue)),
            JSONField("date", .string(je.date)),
            JSONField("description", .string(je.description)),
            JSONField("rollForward", .string(je.rollForward.rawValue)),
        ]
        if je.pending { head.append(JSONField("pending", .bool(true))) }
        return .object(head + [
            JSONField("createdAt", .string(je.createdAt)),
            JSONField("modifiedAt", .string(je.modifiedAt)),
            JSONField("lines", .array(je.lines.map { l in
                .object([
                    JSONField("entity", .string(l.entity)),
                    JSONField("account", .string(l.account)),
                    JSONField("debit", .money(l.amount.debit)),
                    JSONField("credit", .money(l.amount.credit)),
                    JSONField("memo", .string(l.memo)),
                ])
            })),
            JSONField("references", .array(je.references.map { r in
                var fields = [JSONField("path", .string(r.path)), JSONField("note", .string(r.note))]
                if !r.sheet.isEmpty { fields.append(JSONField("sheet", .string(r.sheet))) }
                if !r.cells.isEmpty { fields.append(JSONField("cells", .string(r.cells))) }
                return .object(fields)
            })),
        ])
    }

    static func json(_ a: Account) -> JSONValue {
        .object([
            JSONField("id", .string(a.id)),
            JSONField("number", .string(a.number)),
            JSONField("name", .string(a.name)),
            JSONField("type", .string(a.type.rawValue)),
            JSONField("grouping", a.grouping.map { .string($0) } ?? .null),
        ])
    }

    public static func json(_ g: Grouping) -> JSONValue {
        var fields = [
            JSONField("id", .string(g.id)),
            JSONField("code", .string(g.code)),
            JSONField("name", .string(g.name)),
            JSONField("section", .string(g.section)),
        ]
        if let parent = g.parent { fields.append(JSONField("parent", .string(parent))) }
        if let type = g.type { fields.append(JSONField("type", .string(type.rawValue))) }
        return .object(fields)
    }

    /// Reads one grouping. A subgroup may leave out its code; a top-level grouping needs one.
    static func decodeGrouping(_ item: Any, path: String, defaultSection: String = "") throws -> Grouping {
        let o = try JSONObject(item, path)
        let parent = o.optStringOrNil("parent")
        let code = parent == nil ? try o.string("code") : o.optString("code")
        let name = o.optString("name")
        let id = o.optString("id", default: code.isEmpty ? name : code)
        guard !id.isEmpty else { throw TBError("\(path): a grouping needs an id, a code or a name.") }
        return Grouping(id: id, code: code, name: name, section: o.optString("section", default: defaultSection), parent: parent,
                        type: AccountType(rawValue: o.optString("type")))
    }

    // MARK: Decode

    /// Reads a file. Every account comes out with the type of its grouping, whatever the file
    /// says (a file edited by hand, or written before the type came from the grouping). Pass
    /// `aligningTypes: false` to see the file exactly as written.
    public static func decode(_ data: Data, aligningTypes: Bool = true) throws -> Engagement {
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TBError("This file isn't valid JSON. \(error.localizedDescription)")
        }
        let root = try JSONObject(any, "file")
        guard root.optString("fileType") == fileType else {
            throw TBError("This JSON file doesn't identify itself as a trial balance (it needs \"fileType\": \"\(fileType)\").")
        }
        let version = root.int("schemaVersion") ?? 1
        guard version <= schemaVersion else {
            throw TBError("This file was written by a newer version of TB Tool (schema \(version)). Update the app to open it.")
        }

        var e = Engagement(name: root.optString("name", default: "Trial Balance"),
                           periodEnd: root.optString("periodEnd"),
                           groupings: [])
        e.groupingListName = root.optString("groupingListName")
        e.rolledForwardFrom = root.optString("rolledForwardFrom")
        if let b = root.dict["binder"] {
            let o = try JSONObject(b, "binder")
            e.binder.clientNumber = o.optString("clientNumber")
            e.binder.engagement = o.optString("engagement")
            e.binder.entityType = o.optString("entityType")
            e.binder.taxID = o.optString("taxID")
            e.binder.firm = o.optString("firm")
            e.binder.preparedBy = o.optString("preparedBy")
            e.binder.reviewedBy = o.optString("reviewedBy")
        }

        for (i, item) in root.array("groupings").enumerated() {
            e.groupings.append(try decodeGrouping(item, path: "groupings[\(i)]"))
        }
        // Files from before groupings had account types: the built-in groupings take the built-in types.
        if version < 4 { e.groupings = Engagement.fillingStandardTypes(e.groupings) }

        for (i, item) in root.array("accounts").enumerated() {
            let o = try JSONObject(item, "accounts[\(i)]")
            let number = o.optString("number")
            let name = o.optString("name")
            var a = Account(number: number, name: name,
                            type: AccountType(rawValue: o.optString("type")),
                            grouping: o.optStringOrNil("grouping"))
            if let id = o.optStringOrNil("id") { a.id = id }
            guard !a.id.isEmpty else { throw TBError("accounts[\(i)]: an account needs a number or a name.") }
            e.accounts.append(a)
        }

        for (i, item) in root.array("entities").enumerated() {
            let o = try JSONObject(item, "entities[\(i)]")
            var ent = Entity(id: try o.string("id"), name: o.optString("name"))
            if ent.name.isEmpty { ent.name = ent.id }
            ent.source = o.optString("source")
            ent.importedAt = o.optString("importedAt")
            ent.editedAt = o.optString("editedAt")
            ent.activityNumber = o.optString("activityNumber")
            for (j, p) in o.array("priorPeriods").enumerated() {
                let po = try JSONObject(p, "entities[\(i)].priorPeriods[\(j)]")
                guard let year = po.int("year") else { throw TBError("entities[\(i)].priorPeriods[\(j)]: missing “year”.") }
                var period = PriorPeriod(year: year)
                period.source = po.optString("source")
                period.importedAt = po.optString("importedAt")
                for (k, b) in po.array("balances").enumerated() {
                    let bo = try JSONObject(b, "entities[\(i)].priorPeriods[\(j)].balances[\(k)]")
                    let book = try bo.money("book")
                    period.balances.append(PriorBalance(account: try bo.string("account"), book: book,
                                                        tax: bo.dict["tax"] == nil ? book : try bo.money("tax"),
                                                        elim: try bo.money("elim")))
                }
                ent.priorPeriods.append(period)
            }
            for (j, b) in o.array("balances").enumerated() {
                let bo = try JSONObject(b, "entities[\(i)].balances[\(j)]")
                ent.balances.append(Balance(account: try bo.string("account"),
                                            amount: try bo.money("debit") - bo.money("credit")))
            }
            e.entities.append(ent)
        }

        for (i, item) in root.array("journalEntries").enumerated() {
            e.journalEntries.append(try decodeEntry(item, path: "journalEntries[\(i)]"))
        }

        for (i, item) in root.array("signOffs").enumerated() {
            let o = try JSONObject(item, "signOffs[\(i)]")
            guard let level = SignOffLevel(rawValue: o.optString("level")) else { continue }
            e.signOffs.append(SignOff(path: try o.string("path"), level: level, actor: try actor(o.dict["by"], "signOffs[\(i)].by"),
                                      at: o.optString("at"), fileHash: o.optString("fileHash")))
        }
        for (i, item) in root.array("auditLog").enumerated() {
            let o = try JSONObject(item, "auditLog[\(i)]")
            e.auditLog.append(AuditEntry(at: o.optString("at"), action: o.optString("action"),
                                         details: o.array("details").compactMap { $0 as? String },
                                         actor: try actor(o.dict["by"], "auditLog[\(i)].by"), hash: o.optString("hash")))
        }
        e.extras = root.dict.keys.sorted()
            .filter { !knownKeys.contains($0) }
            .map { JSONField($0, JSONValue.from(any: root.dict[$0]!)) }
        if aligningTypes { e.alignAccountTypes() }
        return e
    }

    /// Decodes one journal entry object. `id`, `number`, and the timestamps may be omitted
    /// (the caller fills in a number before posting).
    public static func decodeEntry(_ any: Any, path: String = "entry") throws -> JournalEntry {
        let o = try JSONObject(any, path)
        let typeText = try o.string("type")
        guard let type = JEType(rawValue: typeText) else {
            throw TBError("\(path): unknown entry type “\(typeText)”. Use adjusting, reclassifying, tax-only, or eliminating.")
        }
        var je = JournalEntry(number: o.optString("number"), type: type, date: o.optString("date"),
                              description: o.optString("description"))
        if let id = o.optStringOrNil("id") { je.id = id }
        if let c = o.optStringOrNil("createdAt") { je.createdAt = c }
        je.modifiedAt = o.optStringOrNil("modifiedAt") ?? je.createdAt
        je.rollForward = RollForward(rawValue: o.optString("rollForward")) ?? .none
        je.pending = (o.dict["pending"] as? Bool) ?? false
        for (j, l) in o.array("lines").enumerated() {
            let lo = try JSONObject(l, "\(path).lines[\(j)]")
            je.lines.append(JELine(entity: lo.optString("entity"),
                                   account: try lo.string("account"),
                                   amount: try lo.money("debit") - lo.money("credit"),
                                   memo: lo.optString("memo")))
        }
        for (j, r) in o.array("references").enumerated() {
            if let s = r as? String {
                je.references.append(FileReference(path: s))
            } else {
                let ro = try JSONObject(r, "\(path).references[\(j)]")
                je.references.append(FileReference(path: try ro.string("path"), note: ro.optString("note"),
                                                   sheet: ro.optString("sheet"), cells: ro.optString("cells")))
            }
        }
        return je
    }

    public static func decodeEntry(data: Data) throws -> JournalEntry {
        let any: Any
        do {
            any = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TBError("The entry isn't valid JSON. \(error.localizedDescription)")
        }
        return try decodeEntry(any)
    }
}
