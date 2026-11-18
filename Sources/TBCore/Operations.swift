import Foundation

// Every change to an engagement goes through these functions, so the posting rules are
// enforced in one place for the app, the command line, and the tests.

extension Engagement {

    // MARK: Lookups

    public func entity(_ id: String) -> Entity? { entities.first { $0.id == id } }
    public func account(_ id: String) -> Account? { accounts.first { $0.id == id } }
    public func grouping(_ id: String?) -> Grouping? {
        guard let id else { return nil }
        return groupings.first { $0.id == id }
    }
    public func entry(_ id: String) -> JournalEntry? { journalEntries.first { $0.id == id } }

    public var sortedAccounts: [Account] { accounts.sorted(by: accountPrecedes) }

    /// Sections in the order they first appear in the grouping list.
    public var groupingSections: [String] {
        var seen = Set<String>()
        return groupings.map(\.section).filter { seen.insert($0).inserted }
    }

    /// Finds the account a person most plausibly means by typed text: the full "number name"
    /// label, the number, the name, or a fragment that matches exactly one account.
    public func resolveAccount(_ text: String) -> Account? {
        let t = text.trimmed.lowercased()
        guard !t.isEmpty else { return nil }
        if let a = accounts.first(where: { $0.display.lowercased() == t }) { return a }
        if let a = accounts.first(where: { !$0.number.isEmpty && $0.number.lowercased() == t }) { return a }
        if let a = accounts.first(where: { $0.name.lowercased() == t }) { return a }
        let hits = accounts.filter { $0.display.lowercased().contains(t) }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Accounts matching typed text, best first: every word must appear in the number or the name.
    /// An exact number comes first, then numbers that start with the text, then names that start
    /// with it, then a word in the name that starts with it, then anything containing it.
    public func searchAccounts(_ text: String, limit: Int = 200) -> [Account] {
        Engagement.searchAccounts(sortedAccounts, text, limit: limit)
    }

    public static func searchAccounts(_ sorted: [Account], _ text: String, limit: Int = 200) -> [Account] {
        let query = text.trimmed.lowercased()
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return Array(sorted.prefix(limit)) }
        var scored: [(rank: Int, index: Int, account: Account)] = []
        for (i, a) in sorted.enumerated() {
            let number = a.number.lowercased(), name = a.name.lowercased()
            let display = a.display.lowercased()
            guard terms.allSatisfy({ display.contains($0) }) else { continue }
            let rank: Int
            if number == query || display == query {
                rank = 0
            } else if !number.isEmpty && number.hasPrefix(terms[0]) {
                rank = 1
            } else if name.hasPrefix(query) {
                rank = 2
            } else if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(terms[0]) }) {
                rank = 3
            } else {
                rank = 4
            }
            scored.append((rank, i, a))
        }
        scored.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.index < $1.index }
        return scored.prefix(limit).map(\.account)
    }

    // MARK: Entities

    @discardableResult
    public mutating func addEntity(named raw: String) throws -> String {
        let name = raw.trimmed
        guard !name.isEmpty else { throw TBError("Give the trial balance a name.") }
        guard !entities.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw TBError("There is already a trial balance named “\(name)”.")
        }
        let base = Engagement.slug(name)
        var id = base
        var n = 2
        while entities.contains(where: { $0.id == id }) {
            id = "\(base)-\(n)"
            n += 1
        }
        entities.append(Entity(id: id, name: name))
        return id
    }

    public mutating func renameEntity(_ id: String, to raw: String) throws {
        let name = raw.trimmed
        guard !name.isEmpty else { throw TBError("Give the trial balance a name.") }
        guard let i = entities.firstIndex(where: { $0.id == id }) else { throw TBError("Trial balance not found.") }
        guard !entities.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw TBError("There is already a trial balance named “\(name)”.")
        }
        entities[i].name = name
    }

    /// Sets the activity number a trial balance is imported under in the tax software. Blank
    /// clears it. Two trial balances can't share a number.
    public mutating func setActivityNumber(_ raw: String, for id: String) throws {
        let number = raw.trimmed
        guard let i = entities.firstIndex(where: { $0.id == id }) else { throw TBError("Trial balance not found.") }
        if !number.isEmpty, let other = entities.first(where: { $0.id != id && $0.activityNumber.caseInsensitiveCompare(number) == .orderedSame }) {
            throw TBError("Activity \(number) is already “\(other.name)”. Each trial balance needs its own activity number.")
        }
        entities[i].activityNumber = number
    }

    public func entries(touching entityID: String) -> [JournalEntry] {
        journalEntries.filter { je in je.lines.contains { $0.entity == entityID } }
    }

    /// Removes a trial balance together with the entries posted only to it. Refuses while an
    /// eliminating entry still references it, because deleting half an elimination would
    /// leave the consolidation out of balance.
    public mutating func deleteEntity(_ id: String) throws {
        guard let ent = entity(id) else { throw TBError("Trial balance not found.") }
        let elims = entries(touching: id).filter { $0.type == .eliminating }
        if !elims.isEmpty {
            let list = elims.map(\.number).joined(separator: ", ")
            throw TBError("“\(ent.name)” is used by eliminating entr\(elims.count == 1 ? "y" : "ies") \(list). Edit or delete \(elims.count == 1 ? "it" : "them") first.")
        }
        journalEntries.removeAll { je in je.lines.contains { $0.entity == id } }
        entities.removeAll { $0.id == id }
    }

    // MARK: Accounts

    public mutating func addAccount(number rawNumber: String, name rawName: String, type: AccountType?) throws -> Account {
        let number = rawNumber.trimmed
        let name = rawName.trimmed
        guard !name.isEmpty else { throw TBError("Give the account a name.") }
        let a = Account(number: number, name: name, type: type)
        guard account(a.id) == nil else { throw TBError("Account \(a.id) is already in the chart of accounts.") }
        accounts.append(a)
        accounts.sort(by: accountPrecedes)
        return a
    }

    /// Accounts with no grouping (or one that isn't in the list), in chart order. Until they are
    /// grouped they sit outside every tax line, so the app keeps an alert up while there are any.
    public var ungroupedAccounts: [Account] {
        sortedAccounts.filter { grouping($0.grouping) == nil }
    }

    public func isAccountUsed(_ id: String) -> Bool {
        entities.contains { $0.balances.contains { $0.account == id } }
            || entities.contains { $0.priorPeriods.contains { $0.balances.contains { $0.account == id } } }
            || journalEntries.contains { $0.lines.contains { $0.account == id } }
    }

    public mutating func deleteAccount(_ id: String) throws {
        guard !isAccountUsed(id) else {
            throw TBError("Account \(id) has balances (this year or a prior year) or journal entry lines, so it can't be deleted.")
        }
        accounts.removeAll { $0.id == id }
    }

    public mutating func updateAccount(_ id: String, _ change: (inout Account) -> Void) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        var a = accounts[i]
        change(&a)
        a.id = id
        // The type isn't the account's to choose: its grouping decides it.
        if let type = groupingType(a.grouping) { a.type = type }
        accounts[i] = a
    }

    /// Puts accounts in a grouping (or, with nil, takes them out). An account's type is its
    /// grouping's, so it changes with the grouping. Returns how many types changed.
    @discardableResult
    public mutating func setGrouping(_ groupingID: String?, forAccounts ids: Set<String>) -> Int {
        for i in accounts.indices where ids.contains(accounts[i].id) {
            accounts[i].grouping = groupingID
        }
        return alignTypes(ofAccounts: ids)
    }

    // MARK: Groupings

    /// The grouping a subgroup sits under. Nil for a top-level grouping, and for a subgroup whose
    /// parent is missing or is itself a subgroup (it is then treated as top-level).
    public func parentGrouping(of g: Grouping) -> Grouping? {
        guard let pid = g.parent, pid != g.id, let p = groupings.first(where: { $0.id == pid }), p.parent == nil else { return nil }
        return p
    }

    /// A grouping's subgroups, in order (see `groupingPrecedes`).
    public func subgroups(of id: String) -> [Grouping] {
        guard let p = groupings.first(where: { $0.id == id }), p.parent == nil else { return [] }
        return groupings.filter { $0.parent == id && $0.id != id }.sorted(by: Engagement.groupingPrecedes)
    }

    /// The groupings of one section (not their subgroups), in order by code.
    public func topGroupings(in section: String) -> [Grouping] {
        groupings.filter { $0.section == section && parentGrouping(of: $0) == nil }.sorted(by: Engagement.groupingPrecedes)
    }

    /// The order groupings are always shown in within a section, and subgroups within a grouping:
    /// by code, reading numbers as numbers (802, 802B, 803 … 9, 10), then by name. Subgroups that
    /// have no code of their own follow the ones that do, by name.
    public static func groupingPrecedes(_ a: Grouping, _ b: Grouping) -> Bool {
        if a.code.isEmpty != b.code.isEmpty { return !a.code.isEmpty }
        let byCode = a.code.compare(b.code, options: [.numeric, .caseInsensitive])
        if byCode != .orderedSame { return byCode == .orderedAscending }
        let byName = a.name.compare(b.name, options: [.numeric, .caseInsensitive])
        if byName != .orderedSame { return byName == .orderedAscending }
        return a.id < b.id
    }

    /// The grouping list as an outline: each section's groupings in list order, every one followed
    /// by its subgroups.
    public var groupingOutline: [(grouping: Grouping, depth: Int)] {
        var out: [(Grouping, Int)] = []
        for section in groupingSections {
            for g in topGroupings(in: section) {
                out.append((g, 0))
                for sub in subgroups(of: g.id) { out.append((sub, 1)) }
            }
        }
        return out
    }

    /// "815 · OTHER › Office supplies" for a subgroup, "815 · OTHER" for a grouping.
    public func groupingLabel(_ id: String?) -> String {
        guard let g = grouping(id) else { return "" }
        guard let p = parentGrouping(of: g) else { return g.display }
        return "\(p.display) › \(g.name)"
    }

    /// The code an account in this grouping reports under: the subgroup's own, or its parent's.
    public func groupingCode(_ id: String?) -> String {
        guard let g = grouping(id) else { return "" }
        if !g.code.isEmpty { return g.code }
        return parentGrouping(of: g)?.code ?? ""
    }

    /// The grouping or subgroup that already has this code. Codes are unique across the whole list.
    public func groupingUsing(code raw: String, except id: String? = nil) -> Grouping? {
        let code = raw.trimmed
        guard !code.isEmpty else { return nil }
        return groupings.first { $0.id != id && $0.code.caseInsensitiveCompare(code) == .orderedSame }
    }

    private func codeTaken(_ code: String, by other: Grouping) -> TBError {
        TBError("Code \(code.trimmed) is already used by “\(groupingLabel(other.id))”. Every grouping and subgroup needs its own code. (A subgroup can leave its code blank to use its grouping's.)")
    }

    /// Codes that more than one grouping or subgroup has, with who has them. Empty in a sound list;
    /// files from before codes had to be unique can have some.
    public var sharedGroupingCodes: [(code: String, groupings: [Grouping])] {
        Engagement.sharedCodes(groupings)
    }

    static func sharedCodes(_ list: [Grouping]) -> [(code: String, groupings: [Grouping])] {
        var order: [String] = []
        var byCode: [String: [Grouping]] = [:]
        for g in list where !g.code.isEmpty {
            let key = g.code.lowercased()
            if byCode[key] == nil { order.append(key) }
            byCode[key, default: []].append(g)
        }
        return order.compactMap { key in byCode[key]!.count > 1 ? (byCode[key]![0].code, byCode[key]!) : nil }
    }

    /// Puts groupings that share a code under one grouping with that code, as its subgroups
    /// (six "815 OTHER - …" lines become "815 OTHER" with six subgroups). Ids don't change, so
    /// every account keeps its assignment. Returns how many groupings became subgroups.
    @discardableResult
    public mutating func mergeSharedGroupingCodes() -> Int {
        let before = groupings.filter { $0.parent != nil }.count
        groupings = Engagement.mergingSharedCodes(groupings)
        alignAccountTypes()
        return groupings.filter { $0.parent != nil }.count - before
    }

    public static func mergingSharedCodes(_ raw: [Grouping]) -> [Grouping] {
        var list = tidiedGroupings(raw)
        // A subgroup that repeats its grouping's code just uses it.
        let codeByID = Dictionary(list.map { ($0.id, $0.code) }, uniquingKeysWith: { a, _ in a })
        for i in list.indices {
            if let p = list[i].parent, let code = codeByID[p], !code.isEmpty, list[i].code.caseInsensitiveCompare(code) == .orderedSame { list[i].code = "" }
        }
        for (code, sharing) in sharedCodes(list) {
            let tops = sharing.filter { $0.parent == nil }
            guard tops.count == sharing.count, tops.count > 1 else { continue }  // a subgroup elsewhere has it: left for a person to sort out
            let withChildren = tops.filter { t in list.contains { $0.parent == t.id } }
            guard withChildren.count <= 1 else { continue }
            let names = tops.map(\.name)
            var parentID: String
            var prefix = ""
            if let keep = withChildren.first {
                // One of them already has subgroups: the others join it.
                parentID = keep.id
            } else {
                // The part of the names they share, when it ends at a separator: "OTHER - ".
                var common = names[0]
                for n in names.dropFirst() { common = String(zip(common, n).prefix { $0.0.lowercased() == $0.1.lowercased() }.map(\.0)) }
                if let cut = common.range(of: #"\s*[-–—:/]\s*$"#, options: .regularExpression), !String(common[..<cut.lowerBound]).trimmed.isEmpty,
                   names.allSatisfy({ $0.count > common.count }) {
                    prefix = common
                    common = String(common[..<cut.lowerBound]).trimmed
                } else {
                    common = "\(code) (combined)"
                }
                parentID = code
                var n = 2
                while list.contains(where: { $0.id == parentID }) {
                    parentID = "\(code)-\(n)"
                    n += 1
                }
                let at = list.firstIndex { $0.id == tops[0].id } ?? list.count
                // The new grouping takes the type they share. With none (a list from before groupings had
                // types), it takes the built-in grouping's when it is one of those; otherwise any type.
                let shared = (Set(tops.map(\.type)).count == 1 ? tops[0].type : nil)
                    ?? DefaultGroupings.list.first { $0.id == parentID && $0.parent == nil && $0.code.caseInsensitiveCompare(code) == .orderedSame }?.type
                list.insert(Grouping(id: parentID, code: code, name: common, section: tops[0].section, type: shared), at: at)
            }
            for i in list.indices where tops.contains(where: { $0.id == list[i].id }) && list[i].id != parentID {
                list[i].parent = parentID
                list[i].code = ""
                if !prefix.isEmpty { list[i].name = String(list[i].name.dropFirst(prefix.count)).trimmed }
            }
            list = tidiedGroupings(list)
        }
        return list
    }

    /// A grouping, or — with `parent` — a subgroup under one. A subgroup takes its parent's section
    /// and may leave the code blank. A code that is given must not be in use already.
    @discardableResult
    public mutating func addGrouping(code rawCode: String, name rawName: String, section rawSection: String, parent: String? = nil,
                                     type: AccountType? = nil) throws -> Grouping {
        let code = rawCode.trimmed, name = rawName.trimmed
        var section = rawSection.trimmed
        guard !name.isEmpty else { throw TBError("A grouping needs a name.") }
        if let other = groupingUsing(code: code) { throw codeTaken(code, by: other) }
        var id = code
        if let parent {
            guard let p = grouping(parent) else { throw TBError("The grouping this subgroup belongs to isn't in the list.") }
            guard p.parent == nil else { throw TBError("“\(p.name)” is itself a subgroup. Subgroups go one level deep.") }
            guard !subgroups(of: p.id).contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw TBError("“\(p.name)” already has a subgroup named “\(name)”.")
            }
            section = p.section
            if code.isEmpty { id = "\(p.id)/\(Engagement.slug(name).uppercased())" }
        } else {
            guard !code.isEmpty else { throw TBError("A grouping needs a code and a name.") }
        }
        if groupings.contains(where: { $0.id == id }) {
            id = "\(id)-\(Engagement.slug(name).uppercased())"
        }
        var n = 2
        let base = id
        while parent != nil && groupings.contains(where: { $0.id == id }) {
            id = "\(base)-\(n)"
            n += 1
        }
        guard !groupings.contains(where: { $0.id == id }) else { throw TBError("That grouping already exists.") }
        // A subgroup has no type of its own; it uses its grouping's.
        let g = Grouping(id: id, code: code, name: name, section: section.isEmpty ? DefaultGroupings.sectionOther : section, parent: parent,
                         type: parent == nil ? type : nil)
        // It falls into place by code within its section (or among its grouping's subgroups).
        groupings = Engagement.tidiedGroupings(groupings + [g])
        return g
    }

    public mutating func updateGrouping(_ id: String, code: String, name: String, section: String) throws {
        try updateGrouping(id, code: code, name: name, section: section, parent: grouping(id)?.parent)
    }

    /// Changes a grouping. Giving it a `parent` makes it a subgroup; nil makes it a top-level grouping.
    public mutating func updateGrouping(_ id: String, code: String, name: String, section: String, parent: String?) throws {
        try updateGrouping(id, code: code, name: name, section: section, parent: parent, type: grouping(id)?.type)
    }

    /// As above, and sets the account type the grouping calls for (nil for any). The accounts in
    /// the grouping — and in its subgroups, or in the grouping it is moved under — follow.
    public mutating func updateGrouping(_ id: String, code: String, name: String, section: String, parent: String?, type: AccountType?) throws {
        guard let i = groupings.firstIndex(where: { $0.id == id }) else { throw TBError("Grouping not found.") }
        guard !name.trimmed.isEmpty else { throw TBError("A grouping needs a name.") }
        // Changing the code to one that's taken isn't allowed. (Leaving an old shared code alone is.)
        if code.trimmed.caseInsensitiveCompare(groupings[i].code) != .orderedSame, let other = groupingUsing(code: code, except: id) {
            throw codeTaken(code, by: other)
        }
        if let parent {
            guard parent != id, let p = grouping(parent) else { throw TBError("The grouping this subgroup belongs to isn't in the list.") }
            guard p.parent == nil else { throw TBError("“\(p.name)” is itself a subgroup. Subgroups go one level deep.") }
            guard subgroups(of: id).isEmpty else {
                throw TBError("“\(groupings[i].name)” has subgroups of its own, so it can't become a subgroup.")
            }
            groupings[i].section = p.section
        } else {
            guard !code.trimmed.isEmpty else { throw TBError("A grouping needs a code and a name.") }
            if !section.trimmed.isEmpty { groupings[i].section = section.trimmed }
        }
        groupings[i].code = code.trimmed
        groupings[i].name = name.trimmed
        groupings[i].parent = parent
        groupings[i].type = parent == nil ? type : nil
        groupings = Engagement.tidiedGroupings(groupings)
        let inside = Set([id] + subgroups(of: id).map(\.id))
        alignTypes(ofAccounts: Set(accounts.filter { $0.grouping.map(inside.contains) ?? false }.map(\.id)))
    }

    /// Deletes a grouping. Accounts in a deleted subgroup move up to its parent; deleting a
    /// grouping also deletes its subgroups and un-groups every account that pointed at them.
    public mutating func deleteGrouping(_ id: String) {
        guard let g = grouping(id) else { return }
        if let p = parentGrouping(of: g) {
            groupings.removeAll { $0.id == id }
            for i in accounts.indices where accounts[i].grouping == id { accounts[i].grouping = p.id }
            return
        }
        let gone = Set([id] + subgroups(of: id).map(\.id))
        groupings.removeAll { gone.contains($0.id) }
        for i in accounts.indices {
            if let g = accounts[i].grouping, gone.contains(g) { accounts[i].grouping = nil }
        }
    }

    /// A grouping list put in order: subgroups whose parent is missing (or is a subgroup itself)
    /// become top-level, every subgroup takes its parent's section, and each sits after its parent.
    public static func tidiedGroupings(_ list: [Grouping]) -> [Grouping] {
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var fixed = list.map { g -> Grouping in
            var x = g
            if let pid = g.parent {
                if pid != g.id, let p = byID[pid], p.parent == nil {
                    x.section = p.section
                    x.type = nil  // a subgroup uses its grouping's type
                } else {
                    x.parent = nil
                }
            }
            return x
        }
        // Sections stay in the order they first appear; inside a section groupings are kept in
        // order by code, each followed by its subgroups, so a new or renamed one falls into place.
        var sections: [String] = []
        for g in fixed where g.parent == nil && !sections.contains(g.section) { sections.append(g.section) }
        let children = Dictionary(grouping: fixed.filter { $0.parent != nil }, by: { $0.parent! })
        fixed = sections.flatMap { section in
            fixed.filter { $0.parent == nil && $0.section == section }.sorted(by: groupingPrecedes)
                .flatMap { [$0] + (children[$0.id] ?? []).sorted(by: groupingPrecedes) }
        }
        return fixed
    }

    /// Replaces the grouping list with the built-in one. Assignments to groupings that still exist are kept.
    public mutating func resetGroupingsToDefault() {
        groupings = DefaultGroupings.list
        let ids = Set(groupings.map(\.id))
        for i in accounts.indices {
            if let g = accounts[i].grouping, !ids.contains(g) { accounts[i].grouping = nil }
        }
        alignAccountTypes()
    }

    public func resolveGrouping(_ text: String) -> Grouping? {
        let t = text.trimmed.lowercased()
        guard !t.isEmpty else { return nil }
        if let g = groupings.first(where: { $0.id.lowercased() == t }) { return g }
        let byCode = groupings.filter { $0.code.lowercased() == t }
        if byCode.count == 1 { return byCode[0] }
        if let g = groupings.first(where: { "\($0.code) \($0.name)".lowercased() == t }) { return g }
        // A subgroup by its grouping's code: "815 MANAGEMENT FEES", or "815 OTHER - MANAGEMENT FEES".
        for g in groupings {
            guard let p = parentGrouping(of: g) else { continue }
            let code = g.code.isEmpty ? p.code : g.code
            if "\(code) \(g.name)".lowercased() == t || "\(code) \(p.name) - \(g.name)".lowercased() == t
                || "\(p.name) - \(g.name)".lowercased() == t { return g }
        }
        let byName = groupings.filter { $0.name.lowercased() == t }
        return byName.count == 1 ? byName[0] : nil
    }

    /// Applies a two-column CSV (account, grouping) to the chart. The grouping may be given by id
    /// (`815-MGMT`), by code when the code is unique (`L01`), or as "code name". Returns how many
    /// accounts were mapped plus a note for every row that couldn't be applied.
    public mutating func applyGroupingMap(csv: String) -> (applied: Int, warnings: [String]) {
        var applied = 0
        var warnings: [String] = []
        for (n, row) in TBImporter.parseCSV(csv).enumerated() {
            guard row.count >= 2 else { continue }
            let acctText = row[0].trimmed, groupText = row[1].trimmed
            if acctText.isEmpty { continue }
            let number = TBImporter.splitAccount(acctText).number
            guard let i = accounts.firstIndex(where: { $0.id == acctText || (!number.isEmpty && $0.id == number) }) else {
                if n == 0 { continue }  // header row
                warnings.append("Row \(n + 1): no account “\(acctText)” in the chart.")
                continue
            }
            if groupText.isEmpty {
                accounts[i].grouping = nil
                applied += 1
            } else if let g = resolveGrouping(groupText) {
                accounts[i].grouping = g.id
                alignTypes(ofAccounts: [accounts[i].id])
                applied += 1
            } else {
                warnings.append("Row \(n + 1): grouping “\(groupText)” isn't in the list (or its code is shared — use the id).")
            }
        }
        return (applied, warnings)
    }

    // MARK: Trial balance import

    /// Loads an imported trial balance into an entity, replacing whatever unadjusted balances it had.
    /// New accounts join the shared chart. Journal entries are untouched.
    ///
    /// `resolving` carries the decisions made about accounts the file names differently from the
    /// chart, by account number (see `accountNameConflicts`). Without a decision the chart's name is
    /// kept and a note says so.
    public mutating func importTrialBalance(_ source: ImportedTB, into entityID: String,
                                            resolving resolutions: [String: AccountNameResolution] = [:]) throws -> [String] {
        guard let ei = entities.firstIndex(where: { $0.id == entityID }) else { throw TBError("Trial balance not found.") }
        // Decided on a copy, so an import that is refused leaves the chart as it was.
        var copy = self
        let (tb, separate) = try copy.resolveNameConflicts(resolutions, in: source)
        self = copy
        defer { applyGroupings(separate) }
        var warnings = tb.warnings
        var balances: [Balance] = []
        var index: [String: Int] = [:]
        var renamed: [String] = []
        for row in tb.rows {
            let incoming = Account(number: row.number, name: row.name, type: row.type)
            if let existing = account(incoming.id) {
                if Engagement.namesDiffer(existing.name, row.name) && !renamed.contains(incoming.id) {
                    renamed.append(incoming.id)
                    if renamed.count <= 5 {
                        warnings.append("Account \(incoming.id) is “\(existing.name)” in the chart but “\(row.name)” in this file. Kept the chart name.")
                    }
                }
            } else {
                accounts.append(incoming)
            }
            if let at = index[incoming.id] {
                balances[at].amount += row.amount
            } else {
                index[incoming.id] = balances.count
                balances.append(Balance(account: incoming.id, amount: row.amount))
            }
        }
        if renamed.count > 5 {
            warnings.append("…and \(renamed.count - 5) more accounts named differently here than in the chart. The chart names were kept.")
        }
        accounts.sort(by: accountPrecedes)
        let order = Dictionary(uniqueKeysWithValues: accounts.enumerated().map { ($1.id, $0) })
        balances.sort { (order[$0.account] ?? 0) < (order[$1.account] ?? 0) }
        entities[ei].balances = balances
        entities[ei].source = tb.sourceName
        entities[ei].importedAt = Timestamp.now()
        entities[ei].editedAt = ""
        return warnings
    }

    /// Loads a file as one trial balance's closing balances for a prior year (book and tax the same).
    /// Replaces that year if it was there already. New accounts join the shared chart.
    public mutating func importPriorPeriod(_ source: ImportedTB, into entityID: String, year: Int,
                                           resolving resolutions: [String: AccountNameResolution] = [:]) throws -> [String] {
        guard let ei = entities.firstIndex(where: { $0.id == entityID }) else { throw TBError("Trial balance not found.") }
        if let current = currentYear, year >= current {
            throw TBError("\(year) isn't a prior year: this file's current year is \(current).")
        }
        // Decided on a copy, so an import that is refused leaves the chart as it was.
        var copy = self
        let (tb, separate) = try copy.resolveNameConflicts(resolutions, in: source)
        self = copy
        defer { applyGroupings(separate) }
        var net: [String: Money] = [:]
        var order: [String] = []
        for row in tb.rows {
            let incoming = Account(number: row.number, name: row.name, type: row.type)
            if account(incoming.id) == nil { accounts.append(incoming) }
            if net[incoming.id] == nil { order.append(incoming.id) }
            net[incoming.id, default: .zero] += row.amount
        }
        accounts.sort(by: accountPrecedes)
        var period = PriorPeriod(year: year)
        period.source = tb.sourceName
        period.importedAt = Timestamp.now()
        period.balances = order.map { PriorBalance(account: $0, book: net[$0]!) }
        sortPrior(&period)
        entities[ei].priorPeriods.removeAll { $0.year == year }
        entities[ei].priorPeriods.append(period)
        entities[ei].priorPeriods.sort { $0.year > $1.year }
        return tb.warnings
    }

    /// Gives accounts that came in as separate accounts the grouping chosen for them.
    private mutating func applyGroupings(_ list: [(id: String, grouping: String?)]) {
        for (id, grouping) in list where grouping != nil {
            updateAccount(id) { if $0.grouping == nil { $0.grouping = grouping } }
        }
    }

    private func sortPrior(_ period: inout PriorPeriod) {
        let order = Dictionary(accounts.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        period.balances.sort { (order[$0.account] ?? 0) < (order[$1.account] ?? 0) }
    }

    // MARK: Editing balances by hand

    /// The balances a person would edit for one trial balance: this year's unadjusted amounts, or a
    /// prior year's closing (book) amounts.
    public func editableBalances(entity entityID: String, priorYear: Int? = nil) -> [Balance] {
        guard let ent = entity(entityID) else { return [] }
        guard let year = priorYear else { return ent.balances }
        return ent.priorPeriods.first { $0.year == year }?.balances.map { Balance(account: $0.account, amount: $0.book) } ?? []
    }

    /// Replaces one trial balance's unadjusted balances (or a prior year's closing balances) with
    /// amounts typed in the app. Journal entries are untouched. Accounts left at zero drop out
    /// unless they were there before.
    public mutating func setBalances(_ new: [Balance], for entityID: String, priorYear: Int? = nil) throws {
        guard let ei = entities.firstIndex(where: { $0.id == entityID }) else { throw TBError("Trial balance not found.") }
        var seen = Set<String>()
        for b in new {
            guard account(b.account) != nil else { throw TBError("Account “\(b.account)” isn't in the chart of accounts.") }
            guard seen.insert(b.account).inserted else { throw TBError("Account \(b.account) is listed twice.") }
        }
        let order = Dictionary(accounts.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let year = priorYear {
            if let current = currentYear, year >= current {
                throw TBError("\(year) isn't a prior year: this file's current year is \(current).")
            }
            let old = entities[ei].priorPeriods.first { $0.year == year }
            let before = Dictionary((old?.balances ?? []).map { ($0.account, $0) }, uniquingKeysWith: { a, _ in a })
            var period = old ?? PriorPeriod(year: year)
            // A book-to-tax difference and the eliminations that were rolled forward stay as they were.
            period.balances = new.map { b in
                let was = before[b.account]
                return PriorBalance(account: b.account, book: b.amount, tax: b.amount + ((was?.tax ?? .zero) - (was?.book ?? .zero)),
                                    elim: was?.elim ?? .zero)
            }.filter { !$0.isZero }
            guard period.balances != old?.balances else { return }
            sortPrior(&period)
            if period.source.isEmpty { period.source = "Entered by hand" }
            period.importedAt = Timestamp.now()
            entities[ei].priorPeriods.removeAll { $0.year == year }
            if !period.balances.isEmpty { entities[ei].priorPeriods.append(period) }
            entities[ei].priorPeriods.sort { $0.year > $1.year }
        } else {
            let had = Set(entities[ei].balances.map(\.account))
            let balances = new.filter { !$0.amount.isZero || had.contains($0.account) }
                .sorted { (order[$0.account] ?? 0) < (order[$1.account] ?? 0) }
            guard balances != entities[ei].balances else { return }
            entities[ei].balances = balances
            entities[ei].editedAt = Timestamp.now()
        }
    }

    public mutating func deletePriorPeriod(_ year: Int, entity entityID: String? = nil) {
        for i in entities.indices where entityID == nil || entities[i].id == entityID {
            entities[i].priorPeriods.removeAll { $0.year == year }
        }
    }

    // MARK: Journal entries

    public func nextEntryNumber(for type: JEType, excluding entryID: String? = nil) -> String {
        let prefix = type.prefix + "-"
        let used = journalEntries
            .filter { $0.id != entryID && $0.number.uppercased().hasPrefix(prefix) }
            .compactMap { Int($0.number.dropFirst(prefix.count)) }
        return "\(prefix)\((used.max() ?? 0) + 1)"
    }

    /// The posting rules. An empty result means the entry may be posted.
    public func validationErrors(for entry: JournalEntry) -> [String] {
        var errors: [String] = []
        let number = entry.number.trimmed
        if number.isEmpty {
            errors.append("The entry needs a number.")
        } else if journalEntries.contains(where: { $0.id != entry.id && $0.number.caseInsensitiveCompare(number) == .orderedSame }) {
            errors.append("Entry number \(number) is already used.")
        }
        if !Timestamp.isValidDay(entry.date) {
            errors.append("The date must be a real date in YYYY-MM-DD form.")
        }
        if entry.lines.count < 2 {
            errors.append("An entry needs at least two lines.")
        }
        let entityIDs = Set(entities.map(\.id))
        let accountIDs = Set(accounts.map(\.id))
        for (i, line) in entry.lines.enumerated() {
            if !entityIDs.contains(line.entity) {
                errors.append("Line \(i + 1): choose a trial balance.")
            }
            if !accountIDs.contains(line.account) {
                errors.append(line.account.isEmpty ? "Line \(i + 1): choose an account."
                                                   : "Line \(i + 1): account “\(line.account)” isn't in the chart of accounts.")
            }
            if line.amount.isZero && !entry.pending {
                errors.append("Line \(i + 1): enter a debit or a credit.")
            }
        }
        if !entry.imbalance.isZero {
            errors.append("Out of balance by \(entry.imbalance.cents > 0 ? entry.imbalance.grouped : (-entry.imbalance).grouped): debits \(entry.totalDebits.grouped), credits \(entry.totalCredits.grouped).")
        }
        if !entry.type.canSpanTrialBalances && Set(entry.lines.map(\.entity)).count > 1 {
            let article = entry.type == .adjusting ? "An" : "A"
            errors.append("\(article) \(entry.type.label.lowercased()) entry must post to a single trial balance. Only reclassifying and eliminating entries can span trial balances.")
        }
        return errors
    }

    /// Posts a new entry, or replaces the entry with the same id. Throws with every rule the entry breaks.
    public mutating func post(_ entry: JournalEntry) throws {
        var e = entry
        e.number = e.number.trimmed
        e.description = e.description.trimmed
        // Posting completes an entry that was rolled forward without amounts.
        e.pending = false
        let errors = validationErrors(for: e)
        guard errors.isEmpty else { throw TBError(errors.joined(separator: "\n")) }
        e.modifiedAt = Timestamp.now()
        if let i = journalEntries.firstIndex(where: { $0.id == e.id }) {
            e.createdAt = journalEntries[i].createdAt
            journalEntries[i] = e
        } else {
            journalEntries.append(e)
        }
    }

    public mutating func deleteEntry(_ id: String) {
        journalEntries.removeAll { $0.id == id }
    }

    // MARK: Integrity

    /// Everything that is wrong or suspicious about the file as a whole. Used after loading a file
    /// that may have been edited outside the app.
    public func issues() -> [String] {
        var out: [String] = []
        func duplicates(_ ids: [String]) -> [String] {
            var seen = Set<String>(), dup = Set<String>()
            for id in ids where !seen.insert(id).inserted { dup.insert(id) }
            return dup.sorted()
        }
        for d in duplicates(entities.map(\.id)) { out.append("Trial balance id “\(d)” is used more than once.") }
        for d in duplicates(accounts.map(\.id)) { out.append("Account “\(d)” is in the chart more than once.") }
        for d in duplicates(groupings.map(\.id)) { out.append("Grouping id “\(d)” is used more than once.") }

        let accountIDs = Set(accounts.map(\.id))
        let groupingIDs = Set(groupings.map(\.id))
        for a in accounts {
            if let g = a.grouping, !groupingIDs.contains(g) {
                out.append("Account \(a.id) points at grouping “\(g)”, which isn't in the grouping list.")
            }
        }
        for (code, sharing) in sharedGroupingCodes {
            out.append("Code \(code) is used by \(sharing.count) groupings (\(sharing.prefix(3).map(\.name).joined(separator: ", "))\(sharing.count > 3 ? ", …" : "")). Every code should be used once: on the Grouping List screen, choose Combine as Subgroups, or change the codes.")
        }
        for g in groupings where g.parent != nil && parentGrouping(of: g) == nil {
            out.append("Subgroup “\(g.name)” points at grouping “\(g.parent!)”, which isn't a grouping in the list. It is being treated as a grouping of its own.")
        }
        for ent in entities {
            let missing = ent.balances.map(\.account).filter { !accountIDs.contains($0) }
            if !missing.isEmpty {
                out.append("\(ent.name): balances for accounts not in the chart (\(missing.joined(separator: ", "))).")
            }
            for d in duplicates(ent.balances.map(\.account)) {
                out.append("\(ent.name): account \(d) has more than one balance row.")
            }
            let total = ent.unadjustedTotal
            if !total.isZero {
                out.append("\(ent.name): imported trial balance is out of balance by \(total.formatted).")
            }
        }
        for je in journalEntries {
            for err in validationErrors(for: je) {
                out.append("\(je.number.isEmpty ? "Unnumbered entry" : je.number): \(err)")
            }
        }
        return out
    }

    // MARK: Helpers

    static func slug(_ s: String) -> String {
        var out = ""
        var pendingDash = false
        for u in s.lowercased().unicodeScalars {
            let isAlnum = (u >= "a" && u <= "z") || (u >= "0" && u <= "9")
            if isAlnum {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(u)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "tb" : out
    }
}
