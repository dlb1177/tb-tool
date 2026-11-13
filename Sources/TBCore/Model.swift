import Foundation

public struct TBError: LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum AccountType: String, CaseIterable, Sendable {
    case asset, liability, equity, revenue, expense

    public var label: String { rawValue.capitalized }
    public var isIncomeStatement: Bool { self == .revenue || self == .expense }

    /// First guess from the account number's leading digit, or from the name when there is no
    /// number. Always editable afterwards.
    public static func infer(number: String, name: String) -> AccountType {
        switch number.first {
        case "1": return .asset
        case "2": return .liability
        case "3": return .equity
        case "4": return .revenue
        case "5", "6", "7", "8", "9": return .expense
        default: return infer(name: name)
        }
    }

    /// Reads a type the way exports spell it: "Asset", "Other Current Liability", "Income", "Cost of Goods Sold"…
    public static func parse(_ raw: String) -> AccountType? {
        let t = raw.lowercased().trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.contains("expense") || t.contains("cost") || t == "cogs" { return .expense }
        if t.contains("liabilit") || t.contains("payable") || t.contains("credit card") || t == "loan" { return .liability }
        if t.contains("equity") || t.contains("capital") { return .equity }
        if t.contains("income") || t.contains("revenue") || t == "sales" { return .revenue }
        if t.contains("asset") || t == "bank" || t.contains("receivable") || t == "cash" || t == "inventory" { return .asset }
        return nil
    }

    static func infer(name raw: String) -> AccountType {
        let n = " " + raw.lowercased() + " "
        func any(_ words: [String]) -> Bool { words.contains { n.contains($0) } }
        // A bank account usually shows its last four digits: "Operating (4825)".
        if raw.range(of: #"\(\s*[x*#]*\d{4}\s*\)"#, options: .regularExpression) != nil { return .asset }
        if any(["accumulated depreciation", "accumulated amortization", "accum. depr", "accum depr", "allowance for"]) { return .asset }
        if any(["expense", " cost", "cogs", "depreciation", "amortization", "wages", "salaries", "payroll tax", "charges", "bank fee"]) { return .expense }
        if any(["payable", "accrued", "loan", "mortgage", "note ", "notes ", "liabilit", "line of credit", "credit card",
                "unearned", "deferred revenue", "customer deposit", "due to ", "sales tax collected"]) { return .liability }
        if any(["equity", "capital", "contribution", "distribution", "retained earnings", "draw", "opening balance"]) { return .equity }
        if any(["income", "revenue", "sales", "fees earned", "gain", "rents received", "rental receipts"]) { return .revenue }
        if any(["cash", "checking", "savings", "bank", "receivable", "prepaid", "inventory", "land", "building", "equipment",
                "furniture", "improvement", "vehicle", "deposit", "investment", "due from", "goodwill", "petty", "asset"]) { return .asset }
        return .expense
    }
}

public enum JEType: String, CaseIterable, Sendable {
    case adjusting
    case reclassifying
    case taxOnly = "tax-only"
    case eliminating

    public var prefix: String {
        switch self {
        case .adjusting: return "AJE"
        case .reclassifying: return "RJE"
        case .taxOnly: return "TJE"
        case .eliminating: return "EJE"
        }
    }

    public var label: String {
        switch self {
        case .adjusting: return "Adjusting"
        case .reclassifying: return "Reclassifying"
        case .taxOnly: return "Tax-only"
        case .eliminating: return "Eliminating"
        }
    }
}

/// What happens to a journal entry when the file is rolled forward to the next year.
public enum RollForward: String, CaseIterable, Sendable {
    case none
    case withAmounts = "amounts"
    case withoutAmounts = "blank"
    /// Rolls forward with every debit and credit swapped, undoing this year's entry in the new year.
    case reversal

    public var label: String {
        switch self {
        case .none: return "Don't roll forward"
        case .withAmounts: return "Roll forward with amounts"
        case .withoutAmounts: return "Roll forward without amounts"
        case .reversal: return "Roll forward as reversal"
        }
    }

    public var short: String {
        switch self {
        case .none: return ""
        case .withAmounts: return "With amounts"
        case .withoutAmounts: return "Without amounts"
        case .reversal: return "As reversal"
        }
    }
}

/// Binder (engagement) details. They head every report export and are edited in Trial Balance Settings.
/// The client name itself is `Engagement.name`; the year end is `Engagement.periodEnd`.
public struct Binder: Equatable, Sendable {
    public var clientNumber = ""
    public var engagement = ""
    public var entityType = ""
    public var taxID = ""
    public var firm = ""
    public var preparedBy = ""
    public var reviewedBy = ""

    public init() {}

    public static let entityTypes = [
        "Partnership (Form 1065)", "S Corporation (Form 1120-S)", "C Corporation (Form 1120)",
        "Sole Proprietor / Individual (Form 1040)", "Trust or Estate (Form 1041)", "Nonprofit (Form 990)", "Other",
    ]
}

public struct Grouping: Equatable, Identifiable, Sendable {
    public var id: String
    public var code: String
    public var name: String
    public var section: String
    /// Set on a subgroup: the id of the grouping it sits under. Subgroups go one level deep, take
    /// their section from the parent, and may leave the code blank to use the parent's.
    public var parent: String?
    /// The kind of account that belongs here (L01 · CASH holds assets). Accounts given this
    /// grouping take the type, and the data check reports any that differ. Nil means any type
    /// (a memo line). A subgroup has none of its own: it uses its grouping's.
    public var type: AccountType?

    public init(id: String, code: String, name: String, section: String, parent: String? = nil, type: AccountType? = nil) {
        self.id = id
        self.code = code
        self.name = name
        self.section = section
        self.parent = parent
        self.type = type
    }

    public var display: String { code.isEmpty ? name : "\(code) · \(name)" }
}

/// One line of the shared chart of accounts. `id` is the account number, or the name when the
/// source trial balance had no number for it.
public struct Account: Equatable, Identifiable, Sendable {
    public var id: String
    public var number: String
    public var name: String
    public var type: AccountType
    public var grouping: String?

    public init(number: String, name: String, type: AccountType? = nil, grouping: String? = nil) {
        self.id = number.isEmpty ? name : number
        self.number = number
        self.name = name
        self.type = type ?? AccountType.infer(number: number, name: name)
        self.grouping = grouping
    }

    public var display: String { number.isEmpty ? name : "\(number) \(name)" }
}

public struct Balance: Equatable, Sendable {
    public var account: String
    public var amount: Money
    public init(account: String, amount: Money) {
        self.account = account
        self.amount = amount
    }
}

/// One account's closing figures in a prior year: final book, tax basis, and this trial balance's
/// share of the eliminations. Signed like everything else: debit positive.
public struct PriorBalance: Equatable, Sendable {
    public var account: String
    public var book: Money
    public var tax: Money
    public var elim: Money

    public init(account: String, book: Money, tax: Money? = nil, elim: Money = .zero) {
        self.account = account
        self.book = book
        self.tax = tax ?? book
        self.elim = elim
    }

    public var isZero: Bool { book.isZero && tax.isZero && elim.isZero }
}

/// A prior year's closing balances for one trial balance. Stored by calendar year; the app shows
/// them relative to the file's current year (PP1 = one year back, PP2 = two…).
public struct PriorPeriod: Equatable, Sendable {
    public var year: Int
    public var source: String = ""
    public var importedAt: String = ""
    public var balances: [PriorBalance] = []

    public init(year: Int) { self.year = year }
}

/// One trial balance (a property / company). All entities are siblings that consolidate together.
public struct Entity: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var source: String = ""
    public var importedAt: String = ""
    /// Set when the unadjusted balances were last changed by hand in the app.
    public var editedAt: String = ""
    public var balances: [Balance] = []
    public var priorPeriods: [PriorPeriod] = []

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public var unadjustedTotal: Money { balances.map(\.amount).sum() }
}

public struct JELine: Equatable, Sendable {
    public var entity: String
    public var account: String
    public var amount: Money
    public var memo: String

    public init(entity: String, account: String, amount: Money, memo: String = "") {
        self.entity = entity
        self.account = account
        self.amount = amount
        self.memo = memo
    }
}

/// A workpaper linked to a journal entry. `path` is relative to the trial balance file's folder
/// when the workpaper lives inside it (so the folder can move), absolute otherwise.
public struct FileReference: Equatable, Sendable {
    public var path: String
    public var note: String

    public init(path: String, note: String = "") {
        self.path = path
        self.note = note
    }

    public init(file: URL, engagementFolder: URL?) {
        let filePath = file.standardizedFileURL.path
        if let folder = engagementFolder?.standardizedFileURL.path {
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            if filePath.hasPrefix(prefix) {
                self.init(path: String(filePath.dropFirst(prefix.count)))
                return
            }
        }
        self.init(path: filePath)
    }

    public func url(engagementFolder: URL?) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        return (engagementFolder ?? URL(fileURLWithPath: "/")).appendingPathComponent(path)
    }

    public var fileName: String { (path as NSString).lastPathComponent }
}

public struct JournalEntry: Equatable, Identifiable, Sendable {
    public var id: String
    public var number: String
    public var type: JEType
    public var date: String
    public var description: String
    public var lines: [JELine]
    public var references: [FileReference]
    public var createdAt: String
    public var modifiedAt: String
    /// What the next roll forward does with this entry.
    public var rollForward: RollForward = .none
    /// Rolled forward without amounts and not completed yet: listed, but it posts nothing.
    public var pending = false

    public init(id: String = UUID().uuidString.lowercased(), number: String, type: JEType, date: String,
                description: String = "", lines: [JELine] = [], references: [FileReference] = []) {
        self.id = id
        self.number = number
        self.type = type
        self.date = date
        self.description = description
        self.lines = lines
        self.references = references
        self.createdAt = Timestamp.now()
        self.modifiedAt = self.createdAt
    }

    public var totalDebits: Money { lines.map(\.amount.debit).sum() }
    public var totalCredits: Money { lines.map(\.amount.credit).sum() }
    public var imbalance: Money { lines.map(\.amount).sum() }
    public var entityIDs: [String] {
        var seen = Set<String>()
        return lines.map(\.entity).filter { seen.insert($0).inserted }
    }
}

/// The whole file: a set of sibling trial balances, one shared chart of accounts, the journal
/// entries posted against them, and the grouping list.
public struct Engagement: Equatable, Sendable {
    public var name: String
    public var periodEnd: String
    public var entities: [Entity] = []
    public var journalEntries: [JournalEntry] = []
    public var accounts: [Account] = []
    public var groupings: [Grouping]
    public var binder = Binder()
    /// Name of the grouping list in use ("Standard (Form 1065)", "S Corporation"…). A label only.
    public var groupingListName = ""
    /// The file this one was rolled forward from, if any.
    public var rolledForwardFrom = ""
    /// Top-level fields this app doesn't know about; written back untouched.
    public var extras: [JSONField] = []

    public init(name: String, periodEnd: String, groupings: [Grouping] = DefaultGroupings.list) {
        self.name = name
        self.periodEnd = periodEnd
        self.groupings = groupings
    }

    /// The current year of the file: the year of the period end.
    public var currentYear: Int? {
        guard Timestamp.isValidDay(periodEnd) else { return nil }
        return Int(periodEnd.prefix(4))
    }

    /// Prior years with balances in any trial balance, most recent first. Only years before the
    /// current year count, so changing the current year moves the PP columns with it.
    public var priorYears: [Int] {
        let all = Set(entities.flatMap { $0.priorPeriods.map(\.year) })
        guard let current = currentYear else { return all.sorted(by: >) }
        return all.filter { $0 < current }.sorted(by: >)
    }

    /// "PP1", "PP2"… for a prior year, counted back from the current year.
    public func priorLabel(_ year: Int) -> String {
        guard let current = currentYear, year < current else { return String(year) }
        return "PP\(current - year) \(year)"
    }
}

public enum Timestamp {
    public static func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    public static func isValidDay(_ s: String) -> Bool {
        day(from: s) != nil
    }

    public static func day(from s: String) -> Date? {
        guard s.count == 10 else { return nil }
        return dayFormatter.date(from: s)
    }

    public static func dayString(_ d: Date) -> String {
        dayFormatter.string(from: d)
    }

    /// "December 31, 2026" for a YYYY-MM-DD day.
    public static func longDay(_ s: String) -> String? {
        guard let d = day(from: s) else { return nil }
        return longFormatter.string(from: d)
    }

    /// The same month and day a number of years later (Feb 29 becomes Feb 28).
    public static func day(_ s: String, addingYears years: Int) -> String? {
        guard let d = day(from: s), let moved = calendar.date(byAdding: .year, value: years, to: d) else { return nil }
        return dayString(moved)
    }

    public static func day(_ s: String, addingDays days: Int) -> String? {
        guard let d = day(from: s), let moved = calendar.date(byAdding: .day, value: days, to: d) else { return nil }
        return dayString(moved)
    }

    // All of these work in the local time zone, so a day read here matches what a date picker shows.
    private static let calendar = Calendar(identifier: .gregorian)

    private static let longFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM d, yyyy"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()
}

/// Chart order: numbered accounts numerically, then unnumbered ones by name.
public func accountPrecedes(_ a: Account, _ b: Account) -> Bool {
    if a.number.isEmpty != b.number.isEmpty { return !a.number.isEmpty }
    let ka = a.number.isEmpty ? a.name : a.number
    let kb = b.number.isEmpty ? b.name : b.number
    let c = ka.compare(kb, options: [.numeric, .caseInsensitive])
    if c != .orderedSame { return c == .orderedAscending }
    return a.id < b.id
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
