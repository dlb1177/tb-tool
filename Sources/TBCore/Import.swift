import Foundation

/// A trial balance read from a file, before it is attached to an entity.
public struct ImportedTB: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public var number: String
        public var name: String
        public var amount: Money
        /// From an account-type column, when the file has one.
        public var type: AccountType? = nil
    }

    public var sourceName: String
    public var rows: [Row] = []
    public var warnings: [String] = []

    public var total: Money { rows.map(\.amount).sum() }
    /// Debits and credits of the accounts' net balances (rows for the same account are netted first).
    public var totalDebits: Money { netByAccount.values.map(\.debit).sum() }
    public var totalCredits: Money { netByAccount.values.map(\.credit).sum() }
    /// Distinct accounts — fewer than rows when a GL detail export lists many postings per account.
    public var accountCount: Int { netByAccount.count }

    var netByAccount: [String: Money] {
        var out: [String: Money] = [:]
        for r in rows { out[r.number.isEmpty ? r.name.lowercased() : r.number, default: .zero] += r.amount }
        return out
    }
}

// MARK: - Mapping

/// What one column of the source file holds.
public enum ColumnRole: String, CaseIterable, Codable, Sendable {
    case ignore, accountNumber, accountName, accountCombined, debit, credit, balance, accountType

    public var label: String {
        switch self {
        case .ignore: return "Ignore"
        case .accountNumber: return "Account #"
        case .accountName: return "Account Name"
        case .accountCombined: return "Account # + Name"
        case .debit: return "Debit"
        case .credit: return "Credit"
        case .balance: return "Balance"
        case .accountType: return "Account Type"
        }
    }

    public var isAccount: Bool { self == .accountNumber || self == .accountName || self == .accountCombined }
    public var isAmount: Bool { self == .debit || self == .credit || self == .balance }
}

/// How to read a single Balance column.
public enum SignConvention: String, CaseIterable, Codable, Sendable {
    case debitPositive, creditPositive, natural

    public var label: String {
        switch self {
        case .debitPositive: return "Debits positive, credits negative"
        case .creditPositive: return "Credits positive, debits negative"
        case .natural: return "Normal balances shown positive (sign from account type)"
        }
    }
}

/// How to turn a sheet of cells into a trial balance: which row is the header, what each
/// column holds, and which rows the person chose to leave out or bring in.
public struct ImportMapping: Equatable, Sendable {
    /// Index into the sheet's rows; nil when the file has no header row.
    public var headerRow: Int?
    public var roles: [ColumnRole]
    public var sign: SignConvention = .debitPositive
    /// Account rows the person chose to leave out.
    public var excluded: Set<Int> = []
    /// Rows that weren't read as accounts — totals, headings, rows above the header, amounts with
    /// no account — that the person chose to bring in anyway.
    public var forced: Set<Int> = []
    /// True when the roles came from a layout saved on an earlier import.
    public var fromSavedLayout = false

    public init(headerRow: Int?, roles: [ColumnRole], sign: SignConvention = .debitPositive) {
        self.headerRow = headerRow
        self.roles = roles
        self.sign = sign
    }

    public func role(_ column: Int) -> ColumnRole { column < roles.count ? roles[column] : .ignore }

    /// Checks or unchecks a row of the preview. Account rows come in unless left out; every other
    /// row stays out unless it is brought in.
    public mutating func setIncluded(_ on: Bool, row: PreviewRow) {
        guard row.toggleable else { return }
        if row.kind == .account {
            if on { excluded.remove(row.index) } else { excluded.insert(row.index) }
        } else {
            if on { forced.insert(row.index) } else { forced.remove(row.index) }
        }
    }
    public func column(_ role: ColumnRole) -> Int? { roles.firstIndex(of: role) }
    public var usesBalance: Bool { roles.contains(.balance) }

    /// Each role except Ignore lives in one column, and Balance excludes Debit / Credit.
    public mutating func setRole(_ role: ColumnRole, for column: Int) {
        while roles.count <= column { roles.append(.ignore) }
        if role != .ignore {
            for i in roles.indices where roles[i] == role { roles[i] = .ignore }
            if role == .balance {
                for i in roles.indices where roles[i] == .debit || roles[i] == .credit { roles[i] = .ignore }
            }
            if role == .debit || role == .credit {
                for i in roles.indices where roles[i] == .balance { roles[i] = .ignore }
            }
        }
        roles[column] = role
    }

    /// Why this mapping can't produce a trial balance yet. Empty when it can.
    public var problems: [String] {
        var out: [String] = []
        let has = Set(roles)
        if !has.contains(where: \.isAccount) {
            out.append("Choose the column that holds the account (its number, its name, or both).")
        }
        let dr = has.contains(.debit), cr = has.contains(.credit)
        if !has.contains(.balance) && !(dr && cr) {
            out.append(dr || cr ? "Choose both a Debit and a Credit column, or one Balance column."
                                : "Choose the column with the amounts: one Balance column, or Debit and Credit.")
        }
        return out
    }
}

public struct PreviewRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case account, header, aboveHeader, blank, total, heading, noAccount, badAmount
    }
    public var index: Int
    public var kind: Kind
    public var included: Bool
    public var number: String
    public var name: String
    public var amount: Money
    public var note: String
    public var type: AccountType? = nil

    /// Whether the person can switch this row in or out: every row with something on it, except
    /// the header row itself.
    public var toggleable: Bool { kind != .header && kind != .blank }
    public var label: String { number.isEmpty ? name : (name.isEmpty || name == number ? number : "\(number) \(name)") }
}

/// The result of applying a mapping to a sheet: a verdict for every row, and the trial balance
/// the included rows make.
public struct ImportPreview: Equatable, Sendable {
    public var rows: [PreviewRow]
    public var tb: ImportedTB
    public var problems: [String]

    public var includedCount: Int { tb.rows.count }
    public func count(_ kind: PreviewRow.Kind) -> Int { rows.filter { $0.kind == kind }.count }
    public var isUsable: Bool { problems.isEmpty && includedCount > 0 }
}

// MARK: - Importer

public enum TBImporter {

    /// Reads a file and imports it without asking: best sheet, best guess (or a saved layout).
    /// Throws when the guess can't be used, so scripts never import something half-understood.
    public static func read(url: URL, profiles: [ImportProfile] = [], sheet: String? = nil) throws -> ImportedTB {
        try automatic(sheets: try SourceReader.read(url: url), sourceName: url.lastPathComponent, profiles: profiles, sheet: sheet).preview.tb
    }

    public static func parse(text: String, sourceName: String) throws -> ImportedTB {
        try automatic(sheets: [RawSheet(name: sourceName, rows: SourceReader.parseDelimited(text))], sourceName: sourceName).preview.tb
    }

    public static func automatic(sheets: [RawSheet], sourceName: String, profiles: [ImportProfile] = [], sheet: String? = nil,
                                 knownTypes: [String: AccountType] = [:])
        throws -> (sheetIndex: Int, mapping: ImportMapping, preview: ImportPreview)
    {
        var indices = Array(sheets.indices)
        if let sheet {
            indices = indices.filter { sheets[$0].name.caseInsensitiveCompare(sheet) == .orderedSame }
            guard !indices.isEmpty else {
                throw TBError("\(sourceName) has no sheet named “\(sheet)”. Sheets: \(sheets.map(\.name).joined(separator: ", ")).")
            }
        }
        let (index, mapping) = bestGuess(sheets: sheets, among: indices, profiles: profiles, knownTypes: knownTypes)
        let preview = evaluate(sheets[index], mapping, sourceName: sourceName, knownTypes: knownTypes)
        if let problem = preview.problems.first { throw TBError("\(sourceName): \(problem)") }
        if let bad = preview.rows.first(where: { $0.kind == .badAmount }) {
            throw TBError("\(sourceName), row \(bad.index + 1): \(bad.note)")
        }
        guard preview.includedCount > 0 else { throw TBError("\(sourceName): no account rows found.") }
        return (index, mapping, preview)
    }

    /// The sheet and mapping most likely to be the trial balance.
    public static func bestGuess(sheets: [RawSheet], among: [Int]? = nil, profiles: [ImportProfile] = [],
                                 knownTypes: [String: AccountType] = [:]) -> (sheetIndex: Int, mapping: ImportMapping) {
        var best: (Int, ImportMapping, Int)? = nil
        for i in among ?? Array(sheets.indices) {
            let m = guess(sheets[i], profiles: profiles, knownTypes: knownTypes)
            let p = evaluate(sheets[i], m, sourceName: "", knownTypes: knownTypes)
            let score = p.problems.isEmpty ? p.includedCount : -1
            if best == nil || score > best!.2 { best = (i, m, score) }
        }
        guard let best else { return (0, ImportMapping(headerRow: nil, roles: [])) }
        return (best.0, best.1)
    }

    // MARK: Guessing

    /// Predicts the header row, the role of every column, and the sign convention.
    public static func guess(_ sheet: RawSheet, profiles: [ImportProfile] = [], knownTypes: [String: AccountType] = [:]) -> ImportMapping {
        let width = sheet.columnCount
        let scanRows = Array(sheet.rows.prefix(60).enumerated())

        // 1. A layout saved from an earlier import of the same kind of file.
        if !profiles.isEmpty {
            for (i, row) in scanRows {
                let sig = ImportProfiles.signature(row)
                if !sig.isEmpty, let p = profiles.first(where: { $0.signature == sig }) {
                    var m = ImportMapping(headerRow: i, roles: p.roles, sign: p.sign)
                    while m.roles.count < width { m.roles.append(.ignore) }
                    m.fromSavedLayout = true
                    return m
                }
            }
        }

        // 2. The header row: the first row that reads like column titles.
        var headerRow: Int? = nil
        var bestScore = 0
        for (i, row) in scanRows {
            var amount = 0, account = 0
            for cell in row {
                let w = words(cell)
                if w.isEmpty { continue }
                if !w.isDisjoint(with: amountWords) { amount += 1 } else if !w.isDisjoint(with: accountWords) { account += 1 }
            }
            let valid = amount >= 1 && (account >= 1 || amount >= 2)
            let score = amount * 2 + account
            if valid && score > bestScore {
                bestScore = score
                headerRow = i
            }
        }

        let dataRows = Array(sheet.rows.dropFirst((headerRow ?? -1) + 1).prefix(500))
        let stats = (0..<width).map { ColumnStats(column: $0, rows: dataRows) }
        var roles = [ColumnRole](repeating: .ignore, count: width)
        func free(_ c: Int) -> Bool { roles[c] == .ignore }

        // 3. Roles from the header text.
        if let h = headerRow {
            let header = sheet.rows[h]
            func headerWords(_ c: Int) -> Set<String> { c < header.count ? words(header[c]) : [] }
            func pick(_ match: (Set<String>) -> Bool) -> Int? {
                let candidates = (0..<width).filter { free($0) && match(headerWords($0)) && stats[$0].nonEmpty > 0 }
                return candidates.max { a, b in
                    let pa = preference(headerWords(a)), pb = preference(headerWords(b))
                    return pa != pb ? pa < pb : a < b
                }
            }
            let balanceWords: Set<String> = ["balance", "balances", "amount", "amounts", "total", "net", "ending", "closing"]
            let balanceCandidate = pick { !$0.isDisjoint(with: balanceWords) && $0.isDisjoint(with: ["debit", "debits", "credit", "credits", "dr", "cr"]) }
            let balancePreference = balanceCandidate.map { preference(headerWords($0)) } ?? -99
            if let d = pick({ !$0.isDisjoint(with: ["debit", "debits", "dr"]) }) {
                roles[d] = .debit
                let c = pick { !$0.isDisjoint(with: ["credit", "credits", "cr"]) }
                let pairPreference = max(preference(headerWords(d)), c.map { preference(headerWords($0)) } ?? -99)
                // "Total debit / Total credit" beside an "Ending balance" is the period's activity, not the balance.
                if let c, !(balancePreference >= 2 && pairPreference < 2) {
                    roles[c] = .credit
                } else {
                    roles[d] = .ignore
                }
            }
            if !roles.contains(.debit), let b = balanceCandidate { roles[b] = .balance }

            let numberWords: Set<String> = ["number", "no", "#", "num", "code"]
            let nameWords: Set<String> = ["name", "description", "desc", "title", "label"]
            // An account-type column (Asset / Liability / Income…) sets types and signs for new accounts.
            if let t = (0..<width).first(where: { c in
                free(c) && !headerWords(c).isDisjoint(with: ["type", "class", "classification", "category"])
                    && stats[c].nonEmpty > 0 && TBImporter.typeFraction(c, dataRows) >= 0.8
            }) {
                roles[t] = .accountType
            }
            for c in 0..<width where free(c) {
                let w = headerWords(c)
                // "Account type", "Account class", "Parent account": not the account itself.
                if !w.isDisjoint(with: ["type", "class", "category", "classification", "parent", "subtype", "memo", "group", "is", "has", "raw"]) { continue }
                if stats[c].looksFlag { continue }
                let acct = !w.isDisjoint(with: ["account", "acct", "gl", "ledger"])
                let hasAccount = roles.contains(.accountCombined) || roles.contains(.accountName)
                if !w.isDisjoint(with: nameWords) {
                    if hasAccount { continue }
                    roles[c] = stats[c].looksCombined && !roles.contains(.accountNumber) ? .accountCombined : .accountName
                } else if !w.isDisjoint(with: numberWords) && (acct || w.isSubset(of: numberWords.union(["account", "acct", "gl"]))),
                          roles.firstIndex(of: .accountNumber) == nil {
                    roles[c] = stats[c].looksCombined ? .accountCombined : (stats[c].looksText && !stats[c].looksCode ? .accountName : .accountNumber)
                } else if acct {
                    let s = stats[c]
                    if hasAccount && !s.looksCode { continue }
                    if s.looksCombined && !roles.contains(.accountCombined) && !roles.contains(.accountNumber) {
                        roles[c] = .accountCombined
                    } else if s.looksCode && !roles.contains(.accountNumber) {
                        roles[c] = .accountNumber
                    } else if s.looksText && !roles.contains(.accountName) {
                        roles[c] = .accountName
                    }
                }
            }
        }

        // 4. Whatever the header didn't settle, from the cells themselves.
        if !roles.contains(where: \.isAccount) {
            if let c = (0..<width).first(where: { free($0) && stats[$0].looksCombined }) {
                roles[c] = .accountCombined
            } else if let c = (0..<width).first(where: { free($0) && stats[$0].looksCode }) {
                roles[c] = .accountNumber
                if let n = ((c + 1)..<max(c + 1, width)).first(where: { free($0) && stats[$0].looksText }) { roles[n] = .accountName }
            } else if let c = (0..<width).first(where: { free($0) && stats[$0].looksText }) {
                roles[c] = .accountName
            }
        }
        if !roles.contains(where: \.isAmount) {
            let amountCols = (0..<width).filter { free($0) && stats[$0].looksAmount }
            var pair: (Int, Int)? = nil
            for (a, b) in zip(amountCols, amountCols.dropFirst()) where b == a + 1 || amountCols.count == 2 {
                if exclusive(a, b, dataRows) { pair = (a, b) }
            }
            if let (a, b) = pair {
                roles[a] = .debit
                roles[b] = .credit
            } else if let last = amountCols.last {
                roles[last] = .balance
            }
        }

        // 5. Sign of a single balance column: pick the reading that balances.
        var m = ImportMapping(headerRow: headerRow, roles: roles)
        if m.usesBalance {
            if !evaluate(sheet, m, sourceName: "", knownTypes: knownTypes).tb.total.isZero {
                var natural = m
                natural.sign = .natural
                if evaluate(sheet, natural, sourceName: "", knownTypes: knownTypes).tb.total.isZero { m = natural }
            }
        }
        return m
    }

    static let amountWords: Set<String> = ["debit", "debits", "dr", "credit", "credits", "cr", "balance", "balances", "amount", "amounts"]
    static let accountWords: Set<String> = ["account", "acct", "gl", "name", "description", "desc", "title", "number", "no", "#", "code", "num"]

    /// Higher for the column a TB tool should take (ending / adjusted), lower for the ones beside it.
    static func preference(_ w: Set<String>) -> Int {
        var s = 0
        if !w.isDisjoint(with: ["ending", "end", "closing", "final", "adjusted", "ytd", "current", "year"]) { s += 2 }
        if !w.isDisjoint(with: ["beginning", "begin", "opening", "prior", "previous", "py", "change", "activity", "movement",
                                "budget", "variance", "difference", "mtd", "month", "period", "unadjusted", "net"]) { s -= 3 }
        return s
    }

    /// Lowercased words, splitting camelCase too: "GLAccountName" → gl, account, name.
    static func words(_ s: String) -> Set<String> {
        var out = Set<String>(), cur = ""
        let chars = Array(s)
        func flush() {
            if !cur.isEmpty { out.insert(cur.lowercased()) }
            cur = ""
        }
        for (i, ch) in chars.enumerated() {
            guard ch.isLetter || ch.isNumber || ch == "#" else {
                flush()
                continue
            }
            if let prev = cur.last {
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                let lowerToUpper = prev.isLowercase && ch.isUppercase
                let acronymEnd = prev.isUppercase && ch.isUppercase && (next?.isLowercase ?? false)
                let letterDigit = prev.isLetter != ch.isLetter && (prev.isNumber || ch.isNumber)
                if lowerToUpper || acronymEnd || letterDigit { flush() }
            }
            cur.append(ch)
        }
        flush()
        return out
    }

    private static func exclusive(_ a: Int, _ b: Int, _ rows: [[String]]) -> Bool {
        var both = 0, either = 0
        for r in rows {
            let x = a < r.count ? (Money.parse(r[a])?.value ?? .zero) : .zero
            let y = b < r.count ? (Money.parse(r[b])?.value ?? .zero) : .zero
            if !x.isZero || !y.isZero { either += 1 }
            if !x.isZero && !y.isZero { both += 1 }
        }
        return either > 0 && Double(both) <= Double(either) * 0.05
    }

    static func typeFraction(_ c: Int, _ rows: [[String]]) -> Double {
        var n = 0, hit = 0
        for r in rows where c < r.count && !r[c].trimmed.isEmpty {
            n += 1
            if AccountType.parse(r[c]) != nil { hit += 1 }
        }
        return n == 0 ? 0 : Double(hit) / Double(n)
    }

    struct ColumnStats {
        var nonEmpty = 0, numeric = 0, amountSignal = 0, code = 0, combined = 0, text = 0, flag = 0
        var unique = Set<String>()

        init(column c: Int, rows: [[String]]) {
            for r in rows {
                guard c < r.count else { continue }
                let t = r[c].trimmed
                if t.isEmpty { continue }
                nonEmpty += 1
                unique.insert(t)
                let hasDigit = t.contains { $0.isNumber }
                let hasLetter = t.contains { $0.isLetter }
                if hasLetter { text += 1 }
                if ["true", "false", "yes", "no", "y", "n"].contains(t.lowercased()) { flag += 1 }
                if hasDigit, !hasLetter, Money.parse(t) != nil {
                    numeric += 1
                    if t.contains(where: { ".,()$-".contains($0) }) && !TBImporter.isCode(t) { amountSignal += 1 }
                }
                if TBImporter.isCode(t) { code += 1 }
                if let f = t.first, f.isNumber, hasLetter, !TBImporter.splitAccount(t).number.isEmpty { combined += 1 }
            }
        }

        private func frac(_ n: Int) -> Double { nonEmpty == 0 ? 0 : Double(n) / Double(nonEmpty) }
        var looksFlag: Bool { nonEmpty > 0 && frac(flag) >= 0.8 }
        var looksCombined: Bool { nonEmpty > 0 && frac(combined) >= 0.5 }
        var looksCode: Bool { nonEmpty > 0 && frac(code) >= 0.8 && frac(amountSignal) < 0.2 && Double(unique.count) >= Double(nonEmpty) * 0.9 }
        var looksText: Bool { nonEmpty > 0 && frac(text) >= 0.6 && !looksFlag }
        var looksAmount: Bool { nonEmpty > 0 && frac(numeric) >= 0.6 && !looksCode }
    }

    /// Account-number shaped: digits, optionally in segments (1000, 1000-01, 6100:20, A1000).
    static func isCode(_ t: String) -> Bool {
        let s = t.trimmed
        guard s.count >= 2, s.count <= 20 else { return false }
        var digits = 0, prev: Character = "-"
        for (i, ch) in s.enumerated() {
            if ch.isASCII && ch.isNumber {
                digits += 1
            } else if ch == "-" || ch == ":" || ch == "." {
                if prev == "-" || prev == ":" || prev == "." || i == s.count - 1 { return false }
            } else if ch.isLetter && ch.isASCII && (i == 0 || i == s.count - 1) {
            } else {
                return false
            }
            prev = ch
        }
        // "1234.56" is an amount, not a code.
        if let dot = s.lastIndex(of: "."), s.filter({ $0 == "." }).count == 1, !s.contains("-"), !s.contains(":") {
            let after = s[s.index(after: dot)...]
            if after.count <= 2 { return false }
        }
        return digits >= 2
    }

    // MARK: Evaluating

    /// Applies a mapping to every row: what kind of row it is, whether it comes in, and as what.
    public static func evaluate(_ sheet: RawSheet, _ m: ImportMapping, sourceName: String,
                                knownTypes: [String: AccountType] = [:]) -> ImportPreview {
        let numberCol = m.column(.accountNumber), nameCol = m.column(.accountName), combinedCol = m.column(.accountCombined)
        let debitCol = m.column(.debit), creditCol = m.column(.credit), balanceCol = m.column(.balance)
        let typeCol = m.column(.accountType)
        let useDrCr = balanceCol == nil && (debitCol != nil || creditCol != nil)
        let start = (m.headerRow ?? -1) + 1
        let headerSig = m.headerRow.map { ImportProfiles.signature(sheet.rows[$0]) } ?? ""

        func cell(_ row: [String], _ c: Int?) -> String {
            guard let c, c < row.count else { return "" }
            return row[c].trimmed
        }

        // Some exports show credits as negative numbers in the Credit column.
        var creditsNegative = false
        if useDrCr, let c = creditCol {
            var neg = 0, nonzero = 0
            for row in sheet.rows.dropFirst(start) {
                if let p = Money.parse(cell(row, c)), !p.value.isZero {
                    nonzero += 1
                    if p.value.cents < 0 { neg += 1 }
                }
            }
            creditsNegative = nonzero > 0 && neg * 2 > nonzero
        }

        var out: [PreviewRow] = []
        var tb = ImportedTB(sourceName: sourceName)
        var rounded = 0
        var declared: (Money, Money)? = nil

        for (i, row) in sheet.rows.enumerated() {
            var pr = PreviewRow(index: i, kind: .blank, included: false, number: "", name: "", amount: .zero, note: "")
            if let h = m.headerRow, i == h {
                pr.kind = .header
                pr.note = "Header row"
                out.append(pr)
                continue
            }
            if row.allSatisfy({ $0.trimmed.isEmpty }) {
                out.append(pr)
                continue
            }
            let aboveHeader = m.headerRow.map { i < $0 } ?? false
            if aboveHeader && !m.forced.contains(i) {
                pr.kind = .aboveHeader
                pr.note = "Above the header"
                out.append(pr)
                continue
            }

            // The account: number and name from whichever columns hold them.
            var number = cell(row, numberCol), name = cell(row, nameCol)
            if combinedCol != nil {
                let t = cell(row, combinedCol)
                if !t.isEmpty {
                    let s = splitAccount(t)
                    if number.isEmpty { number = s.number }
                    if name.isEmpty { name = s.name.isEmpty ? (s.number.isEmpty ? t : "") : s.name }
                }
            }
            if numberCol != nil && nameCol == nil && combinedCol == nil && !number.isEmpty {
                let s = splitAccount(number)
                if s.number.isEmpty {
                    (number, name) = ("", number)  // text in the number column: treat as the name
                } else if !s.name.isEmpty {
                    (number, name) = (s.number, s.name)
                }
            }
            if nameCol != nil && numberCol == nil && combinedCol == nil && !name.isEmpty {
                let s = splitAccount(name)
                if !s.number.isEmpty && !s.name.isEmpty { (number, name) = (s.number, s.name) }
            }
            pr.number = number
            pr.name = name.isEmpty ? number : name
            pr.type = typeCol.flatMap { AccountType.parse(cell(row, $0)) }

            // The amount.
            var bad: String? = nil
            var hasAmount = false
            var roundedHere = false
            func amount(_ c: Int?) -> Money {
                let t = cell(row, c)
                // Words ("n/a", "Dec 31, 2026") are labels, not amounts.
                if t.isEmpty || !t.contains(where: { $0.isNumber }) || t.contains(where: { $0.isLetter }) { return .zero }
                hasAmount = true
                guard let p = Money.parse(t) else {
                    bad = bad ?? "“\(t)” isn't an amount."
                    return .zero
                }
                if p.rounded { roundedHere = true }
                return p.value
            }
            var value = Money.zero
            var dr = Money.zero, cr = Money.zero
            if useDrCr {
                dr = amount(debitCol)
                cr = amount(creditCol)
                if creditsNegative { cr = -cr }
                value = dr - cr
            } else {
                value = amount(balanceCol)
                switch m.sign {
                case .debitPositive: break
                case .creditPositive: value = -value
                case .natural:
                    let id = number.isEmpty ? name : number
                    let type = pr.type ?? knownTypes[id] ?? AccountType.infer(number: number, name: name)
                    if type == .liability || type == .equity || type == .revenue { value = -value }
                }
            }
            pr.amount = value

            let label = (number + " " + name).trimmed
            let lower = label.lowercased()
            if !headerSig.isEmpty && ImportProfiles.signature(row) == headerSig {
                pr.kind = .header
                pr.note = "Repeated header"
            } else if isTotal(label: lower, number: number, row: row) {
                pr.kind = .total
                pr.note = "Total line — not an account"
                if useDrCr && ["total", "totals", "grand total", "total trial balance"].contains(lower) { declared = (dr, cr) }
            } else if let bad {
                pr.kind = .badAmount
                pr.note = bad
            } else if label.isEmpty {
                pr.kind = hasAmount ? .noAccount : .blank
                pr.note = hasAmount ? "Amount with no account" : ""
            } else if !hasAmount {
                pr.kind = .heading
                pr.note = "Heading — no amount"
            } else {
                pr.kind = .account
            }

            // A row above the header only gets this far when the person checked it.
            if aboveHeader && pr.kind != .header { pr.kind = .aboveHeader }
            switch pr.kind {
            case .account: pr.included = !m.excluded.contains(i)
            case .header: pr.included = false
            default: pr.included = m.forced.contains(i)
            }
            if pr.kind == .account && !pr.included { pr.note = "Left out" }
            if pr.kind != .account && pr.included {
                // Brought in by hand. Whatever couldn't be read is filled in so nothing is silently dropped.
                var notes = ["Brought in"]
                if label.isEmpty {
                    pr.name = "Unnamed (row \(i + 1))"
                    notes.append("no account on this row, so it is named for its row")
                }
                if let bad { notes.append("\(bad) Read as 0.00") } else if !hasAmount { notes.append("no amount, so 0.00") }
                pr.note = notes.joined(separator: " — ")
            }
            if pr.included && roundedHere { rounded += 1 }
            out.append(pr)
        }

        resolveSubaccounts(&out)
        var repeated = Set<String>()
        var seen = Set<String>()
        for pr in out where pr.included {
            let key = pr.number.isEmpty ? pr.name.lowercased() : pr.number
            if !seen.insert(key).inserted { repeated.insert(pr.number.isEmpty ? pr.name : pr.number) }
            tb.rows.append(ImportedTB.Row(number: pr.number, name: pr.name.isEmpty ? pr.number : pr.name, amount: pr.amount, type: pr.type))
        }
        if !repeated.isEmpty {
            let list = repeated.sorted().prefix(6).joined(separator: ", ")
            tb.warnings.append("\(repeated.count) account\(repeated.count == 1 ? " appears" : "s appear") on more than one row, so their amounts will be added together (\(list)\(repeated.count > 6 ? ", …" : "")). Expected for a GL detail export; check it if this is a trial balance.")
        }

        if rounded > 0 {
            tb.warnings.append("\(rounded) amount\(rounded == 1 ? "" : "s") had more than two decimals and \(rounded == 1 ? "was" : "were") rounded to the cent.")
        }
        if let d = declared, d.0 != tb.totalDebits || d.1 != tb.totalCredits {
            tb.warnings.append("The file's TOTAL line (\(d.0.grouped) / \(d.1.grouped)) doesn't match the rows brought in (\(tb.totalDebits.grouped) / \(tb.totalCredits.grouped)).")
        }
        if !tb.total.isZero && !tb.rows.isEmpty {
            tb.warnings.append("Out of balance by \(tb.total.formatted): debits \(tb.totalDebits.grouped), credits \(tb.totalCredits.grouped).")
        }
        return ImportPreview(rows: out, tb: tb, problems: m.problems)
    }

    /// Exports from property-management systems show sub-accounts as a path:
    /// "6500 Repairs & Maintenance - 6515.0010 Maintenance - Supplies". When one number carries
    /// several different names in a file, each row takes the first sub-account number in its path
    /// that isn't shared; a sub-account with no number of its own is kept by its full name.
    static func resolveSubaccounts(_ rows: inout [PreviewRow]) {
        func conflicts() -> Set<String> {
            var names: [String: Set<String>] = [:]
            for r in rows where r.included && !r.number.isEmpty { names[r.number, default: []].insert(r.name.lowercased()) }
            return Set(names.filter { $0.value.count > 1 }.keys)
        }
        // A path whose next segment is clearly a sub-account number belongs to that sub-account.
        for i in rows.indices where rows[i].included && !rows[i].number.isEmpty {
            let path = pathSegments("\(rows[i].number) \(rows[i].name)")
            if path.count > 1 {
                rows[i].number = path[1].number
                rows[i].name = path[1].name
            }
        }
        var clash = conflicts()
        guard !clash.isEmpty else { return }
        for level in 1..<5 {
            for i in rows.indices where rows[i].included && clash.contains(rows[i].number) {
                let path = pathSegments("\(rows[i].number) \(rows[i].name)")
                if path.count > 1 {
                    let pick = path[min(level + 1, path.count - 1)]
                    rows[i].number = pick.number
                    rows[i].name = pick.name
                }
            }
            clash = conflicts()
            if clash.isEmpty { return }
        }
        // Still shared: the row whose name is shortest keeps the number; the others go by full label.
        for number in clash {
            let idx = rows.indices.filter { rows[$0].included && rows[$0].number == number }
            guard let keep = idx.min(by: { rows[$0].name.count < rows[$1].name.count }) else { continue }
            let keepName = rows[keep].name.lowercased()
            for i in idx where rows[i].name.lowercased() != keepName {
                rows[i].name = "\(number) \(rows[i].name)"
                rows[i].number = ""
            }
        }
    }

    /// "6500 Repairs - 6515.0010 Supplies - Bulk" → [(6500, "Repairs - 6515.0010 Supplies - Bulk"), (6515.0010, "Supplies - Bulk")]
    static func pathSegments(_ label: String) -> [(number: String, name: String)] {
        var out: [(String, String)] = []
        let first = splitAccount(label)
        guard !first.number.isEmpty else { return [] }
        out.append((first.number, first.name))
        var search = label.startIndex
        while let r = label.range(of: " - ", range: search..<label.endIndex) {
            let rest = String(label[r.upperBound...])
            let s = splitAccount(rest)
            // Same shape as the parent's number (6500 → 6515.0010, 2320.0055 → 2320.0047) and followed by a name,
            // so "Central Bill Account - 7120 - 4" or "Mortgage - 100 Main St" (an address) don't qualify.
            func whole(_ n: String) -> Int { n.prefix { $0.isNumber }.count }
            if !s.number.isEmpty, let lead = s.name.first, lead.isLetter || lead == "*",
               whole(s.number) == whole(first.number), whole(s.number) >= 3,
               !first.number.contains(".") || s.number.contains(".") {
                out.append((s.number, s.name))
            }
            search = r.upperBound
        }
        return out
    }

    static func isTotal(label: String, number: String, row: [String]) -> Bool {
        let starts = ["total", "grand total", "subtotal", "sub-total", "sub total", "net income", "net loss", "net profit",
                      "net ordinary income", "net other income", "gross profit", "totals"]
        if starts.contains(where: { label.hasPrefix($0) }) { return true }
        if number.isEmpty {
            return row.contains { cell in words(cell).contains("total") || words(cell).contains("totals") }
        }
        return false
    }

    // MARK: Helpers

    /// "10001 Operating (1042) - 2" → ("10001", "Operating (1042) - 2"). Text with no leading number is all name.
    public static func splitAccount(_ raw: String) -> (number: String, name: String) {
        let s = raw.trimmed
        guard let first = s.first, first.isASCII, first.isNumber else { return ("", s) }
        guard let space = s.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
            return s.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-" || $0 == ":") }) ? (s, "") : ("", s)
        }
        let token = String(s[..<space])
        guard token.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-" || $0 == ":") }) else { return ("", s) }
        var name = String(s[space...]).trimmed
        // QuickBooks-style separators: "1000 · Cash", "1000 - Cash"
        for sep in ["· ", "- ", "– ", ": "] where name.hasPrefix(sep) {
            name = String(name.dropFirst(sep.count)).trimmed
        }
        return (token.trimmingCharacters(in: CharacterSet(charactersIn: ":-.")), name)
    }

    /// "Summit_TB_West_Clayton_2026-12-31.csv" → "West Clayton"
    public static func suggestedEntityName(fileName: String) -> String {
        var s = (fileName as NSString).deletingPathExtension
        if let r = s.range(of: #"[ _-]*\d{4}[-_.]?\d{2}[-_.]?\d{2}$"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        if let r = s.range(of: #"(^|[ _-])(TB|Trial[ _-]?Balance)([ _-]|$)"#, options: [.regularExpression, .caseInsensitive]) {
            let after = String(s[r.upperBound...])
            let before = String(s[..<r.lowerBound])
            s = after.isEmpty ? before : after
        }
        s = s.replacingOccurrences(of: "_", with: " ").trimmed
        return s.isEmpty ? (fileName as NSString).deletingPathExtension : s
    }

    /// RFC 4180 CSV (or any single-character separator): quoted fields, doubled quotes,
    /// separators and line breaks inside quotes.
    public static func parseCSV(_ raw: String, separator: Character = ",") -> [[String]] {
        var text = raw
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = text.makeIterator()
        var pending: Character? = nil

        func next() -> Character? {
            if let p = pending {
                pending = nil
                return p
            }
            return chars.next()
        }

        while let ch = next() {
            if inQuotes {
                if ch == "\"" {
                    if let after = next() {
                        if after == "\"" { field.append("\"") } else {
                            inQuotes = false
                            pending = after
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else if ch == "\"" && field.isEmpty {
                inQuotes = true
            } else if ch == separator {
                row.append(field)
                field = ""
            } else if ch == "\n" || ch == "\r" || ch == "\r\n" {
                row.append(field)
                field = ""
                rows.append(row)
                row = []
            } else {
                field.append(ch)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
