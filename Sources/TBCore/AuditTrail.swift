import CryptoKit
import Foundation
import IOKit

// Who did what, and when. Every change made to a trial balance file is written to a log inside
// the file, and workpapers can be signed off as prepared, reviewed and second reviewed. Each
// record carries the person, the Mac it was done on, and the time.
//
// The log is tamper-evident, not tamper-proof: each entry carries a hash of itself and the entry
// before it, so an entry that is edited, removed or inserted afterwards breaks the chain and the
// app says so. Someone with the file and the will can still rebuild the whole chain.

/// The person and machine behind a change.
public struct Actor: Equatable, Sendable {
    /// The person's name as the Mac knows it ("Jordan Smith").
    public var name: String
    /// Their login on the Mac ("jsmith").
    public var account: String
    /// The Mac's name ("Jordan's MacBook Pro").
    public var computer: String
    /// The Mac's hardware identifier: the same for every user of that machine, and it survives a rename.
    public var device: String

    public init(name: String, account: String, computer: String, device: String) {
        self.name = name
        self.account = account
        self.computer = computer
        self.device = device
    }

    /// Whoever is logged in on this Mac.
    public static func current() -> Actor {
        Actor(name: NSFullUserName(), account: NSUserName(), computer: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
              device: hardwareUUID())
    }

    private static func hardwareUUID() -> String {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return "" }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? String) ?? ""
    }

    public var display: String { name.isEmpty ? account : name }
}

public enum FileFingerprint {
    /// The SHA-256 of a file's contents, in hex. Nil when the file can't be read.
    public static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data
            do {
                // Nothing more to read comes back as nil.
                chunk = try handle.read(upToCount: 1 << 20) ?? Data()
            } catch {
                return nil
            }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One line of the change log.
public struct AuditEntry: Equatable, Identifiable, Sendable {
    public var at: String
    public var action: String
    public var details: [String]
    public var actor: Actor
    /// Hash of this entry and the one before it.
    public var hash: String

    public var id: String { hash + at }
}

public enum SignOffLevel: String, CaseIterable, Sendable {
    case prepared
    case reviewed
    case secondReviewed = "second-reviewed"

    public var label: String {
        switch self {
        case .prepared: return "Prepared"
        case .reviewed: return "Reviewed"
        case .secondReviewed: return "Second Reviewed"
        }
    }

    public var short: String {
        switch self {
        case .prepared: return "P"
        case .reviewed: return "R"
        case .secondReviewed: return "2R"
        }
    }
}

/// A workpaper marked as prepared, reviewed or second reviewed.
public struct SignOff: Equatable, Sendable {
    /// The file, relative to the binder folder.
    public var path: String
    public var level: SignOffLevel
    public var actor: Actor
    public var at: String
    /// A fingerprint (SHA-256) of the file's contents when it was signed off, so a file changed
    /// afterwards can be told apart from the one that was looked at.
    public var fileHash: String

    public init(path: String, level: SignOffLevel, actor: Actor, at: String = Timestamp.now(), fileHash: String = "") {
        self.path = path
        self.level = level
        self.actor = actor
        self.at = at
        self.fileHash = fileHash
    }
}

extension Engagement {

    // MARK: The change log

    static func chainHash(previous: String, at: String, action: String, details: [String], actor: Actor) -> String {
        let text = ([previous, at, action] + details + [actor.name, actor.account, actor.computer, actor.device]).joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Adds a line to the change log.
    public mutating func log(_ action: String, details: [String] = [], by actor: Actor, at: String = Timestamp.now()) {
        let previous = auditLog.last?.hash ?? ""
        auditLog.append(AuditEntry(at: at, action: action, details: details, actor: actor,
                                   hash: Engagement.chainHash(previous: previous, at: at, action: action, details: details, actor: actor)))
    }

    /// The first entry whose hash doesn't follow from the one before it — the log was edited,
    /// or an entry was removed or inserted, outside the app. Nil when the log is intact.
    public var auditLogBreak: Int? {
        var previous = ""
        for (i, e) in auditLog.enumerated() {
            if e.hash != Engagement.chainHash(previous: previous, at: e.at, action: e.action, details: e.details, actor: e.actor) { return i }
            previous = e.hash
        }
        return nil
    }

    // MARK: Sign-offs

    public func signOffs(for path: String) -> [SignOff] { signOffs.filter { $0.path == path } }

    public func signOff(_ level: SignOffLevel, for path: String) -> SignOff? { signOffs.first { $0.path == path && $0.level == level } }

    /// Marks a workpaper. Signing the same level again replaces the earlier mark.
    public mutating func setSignOff(_ level: SignOffLevel, for path: String, by actor: Actor, fileHash: String, at: String = Timestamp.now()) {
        signOffs.removeAll { $0.path == path && $0.level == level }
        signOffs.append(SignOff(path: path, level: level, actor: actor, at: at, fileHash: fileHash))
        sortSignOffs()
    }

    public mutating func clearSignOff(_ level: SignOffLevel, for path: String) {
        signOffs.removeAll { $0.path == path && $0.level == level }
    }

    private mutating func sortSignOffs() {
        let order = Dictionary(uniqueKeysWithValues: SignOffLevel.allCases.enumerated().map { ($1, $0) })
        signOffs.sort { a, b in
            let c = a.path.compare(b.path, options: [.numeric, .caseInsensitive])
            return c == .orderedSame ? order[a.level]! < order[b.level]! : c == .orderedAscending
        }
    }

    // MARK: What a change did

    /// What differs between an earlier state of the file and this one, in plain lines. This is
    /// what the change log records under each action.
    public func changes(since old: Engagement) -> [String] {
        var out: [String] = []
        func few(_ items: [String], _ limit: Int = 6) -> String {
            items.prefix(limit).joined(separator: ", ") + (items.count > limit ? ", and \(items.count - limit) more" : "")
        }
        if name != old.name { out.append("Client name: “\(old.name)” → “\(name)”") }
        if periodEnd != old.periodEnd { out.append("Year end: \(old.periodEnd) → \(periodEnd)") }
        if binder != old.binder { out.append("Binder details changed") }
        if groupingListName != old.groupingListName { out.append("Grouping list: “\(old.groupingListName)” → “\(groupingListName)”") }

        // Trial balances
        let oldEntities = Dictionary(old.entities.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newEntityIDs = Set(entities.map(\.id))
        for ent in entities {
            guard let was = oldEntities[ent.id] else {
                out.append("Added trial balance “\(ent.name)”" + (ent.balances.isEmpty ? "" : " with \(ent.balances.count) balances, debits \(ent.balances.map(\.amount.debit).sum().grouped)"))
                continue
            }
            if was.name != ent.name { out.append("Renamed trial balance “\(was.name)” to “\(ent.name)”") }
            if was.activityNumber != ent.activityNumber {
                out.append("\(ent.name): activity number \(was.activityNumber.isEmpty ? "(none)" : was.activityNumber) → \(ent.activityNumber.isEmpty ? "(none)" : ent.activityNumber)")
            }
            if was.balances != ent.balances {
                let before = Dictionary(was.balances.map { ($0.account, $0.amount) }, uniquingKeysWith: { a, _ in a })
                let after = Dictionary(ent.balances.map { ($0.account, $0.amount) }, uniquingKeysWith: { a, _ in a })
                let touched = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
                let how = was.source != ent.source || was.importedAt != ent.importedAt ? "imported from \(ent.source)" : "changed by hand"
                out.append("\(ent.name): unadjusted balances \(how) — \(touched.count) account\(touched.count == 1 ? "" : "s") differ"
                           + (touched.count <= 4 ? " (" + touched.map { "\($0): \((before[$0] ?? .zero).formatted) → \((after[$0] ?? .zero).formatted)" }.joined(separator: "; ") + ")" : "")
                           + "; debits \(was.balances.map(\.amount.debit).sum().grouped) → \(ent.balances.map(\.amount.debit).sum().grouped)")
            }
            let years = Set(was.priorPeriods.map(\.year)).union(ent.priorPeriods.map(\.year)).sorted(by: >)
            for y in years {
                let a = was.priorPeriods.first { $0.year == y }, b = ent.priorPeriods.first { $0.year == y }
                if a == nil { out.append("\(ent.name): \(y) balances added (\(b!.balances.count) accounts)") }
                else if b == nil { out.append("\(ent.name): \(y) balances removed") }
                else if a!.balances != b!.balances { out.append("\(ent.name): \(y) balances changed") }
            }
        }
        for was in old.entities where !newEntityIDs.contains(was.id) { out.append("Deleted trial balance “\(was.name)”") }

        // Journal entries
        let oldEntries = Dictionary(old.journalEntries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newEntryIDs = Set(journalEntries.map(\.id))
        func names(_ je: JournalEntry) -> String { je.entityIDs.map { entity($0)?.name ?? old.entity($0)?.name ?? $0 }.joined(separator: ", ") }
        for je in journalEntries {
            guard let was = oldEntries[je.id] else {
                out.append("Posted \(je.number) (\(je.type.label.lowercased()), \(names(je))): \(je.description.isEmpty ? "no description" : je.description) — debits \(je.totalDebits.grouped)")
                continue
            }
            var what: [String] = []
            if was.number != je.number { what.append("number \(was.number) → \(je.number)") }
            if was.type != je.type { what.append("type \(was.type.label.lowercased()) → \(je.type.label.lowercased())") }
            if was.date != je.date { what.append("date \(was.date) → \(je.date)") }
            if was.description != je.description { what.append("description") }
            if was.lines != je.lines { what.append("lines (debits \(was.totalDebits.grouped) → \(je.totalDebits.grouped))") }
            if was.references != je.references { what.append("linked files (\(was.references.count) → \(je.references.count))") }
            if was.rollForward != je.rollForward { what.append("next year: \(je.rollForward.label.lowercased())") }
            if was.pending != je.pending { what.append(je.pending ? "now waiting for amounts" : "amounts filled in") }
            if !what.isEmpty { out.append("Changed \(je.number): " + what.joined(separator: "; ")) }
        }
        for was in old.journalEntries where !newEntryIDs.contains(was.id) {
            out.append("Deleted \(was.number) (\(was.type.label.lowercased())): \(was.description.isEmpty ? "no description" : was.description) — debits \(was.totalDebits.grouped)")
        }

        // Accounts
        let oldAccounts = Dictionary(old.accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newAccountIDs = Set(accounts.map(\.id))
        let added = accounts.filter { oldAccounts[$0.id] == nil }.map(\.display)
        let removed = old.accounts.filter { !newAccountIDs.contains($0.id) }.map(\.display)
        if !added.isEmpty { out.append("Added \(added.count) account\(added.count == 1 ? "" : "s"): \(few(added))") }
        if !removed.isEmpty { out.append("Deleted \(removed.count) account\(removed.count == 1 ? "" : "s"): \(few(removed))") }
        var renamed: [String] = [], regrouped: [String] = [], retyped: [String] = []
        for a in accounts {
            guard let was = oldAccounts[a.id] else { continue }
            if was.name != a.name { renamed.append("\(a.id): “\(was.name)” → “\(a.name)”") }
            if was.grouping != a.grouping {
                regrouped.append("\(a.id): \(old.groupingCode(was.grouping).isEmpty ? "ungrouped" : old.groupingLabel(was.grouping)) → \(groupingCode(a.grouping).isEmpty ? "ungrouped" : groupingLabel(a.grouping))")
            }
            if was.type != a.type { retyped.append("\(a.id): \(was.type.label.lowercased()) → \(a.type.label.lowercased())") }
        }
        if !renamed.isEmpty { out.append("Renamed \(renamed.count) account\(renamed.count == 1 ? "" : "s"): \(few(renamed, 4))") }
        if !regrouped.isEmpty { out.append("Grouping changed on \(regrouped.count) account\(regrouped.count == 1 ? "" : "s"): \(few(regrouped, 4))") }
        if !retyped.isEmpty { out.append("Account type changed on \(retyped.count) account\(retyped.count == 1 ? "" : "s"): \(few(retyped, 4))") }

        // Groupings
        if groupings != old.groupings {
            let was = Dictionary(old.groupings.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let now = Set(groupings.map(\.id))
            let plus = groupings.filter { was[$0.id] == nil }.map { groupingLabel($0.id) }
            let minus = old.groupings.filter { !now.contains($0.id) }.map { old.groupingLabel($0.id) }
            let changed = groupings.filter { g in was[g.id].map { $0 != g } ?? false }.map { groupingLabel($0.id) }
            if !plus.isEmpty { out.append("Added \(plus.count) grouping\(plus.count == 1 ? "" : "s"): \(few(plus))") }
            if !minus.isEmpty { out.append("Deleted \(minus.count) grouping\(minus.count == 1 ? "" : "s"): \(few(minus))") }
            if !changed.isEmpty { out.append("Changed \(changed.count) grouping\(changed.count == 1 ? "" : "s"): \(few(changed))") }
            if plus.isEmpty && minus.isEmpty && changed.isEmpty { out.append("Grouping list reordered") }
        }

        // Sign-offs
        for s in signOffs where !old.signOffs.contains(s) {
            out.append("Marked “\(s.path)” as \(s.level.label.lowercased())")
        }
        for s in old.signOffs where !signOffs.contains(where: { $0.path == s.path && $0.level == s.level }) {
            // A sign-off that moved with its file isn't a removal.
            if !signOffs.contains(where: { $0.level == s.level && $0.at == s.at && $0.fileHash == s.fileHash && $0.actor == s.actor }) {
                out.append("Removed the \(s.level.label.lowercased()) mark from “\(s.path)” (it was \(s.actor.display), \(s.at))")
            }
        }
        return out
    }
}
