import Foundation

// A first pass at grouping accounts, made by Claude. The app sends the file's grouping list, the
// accounts that are already grouped (so the model follows how this set of books has been
// grouped so far), the accounts that still need a grouping, and — if chosen — the contents of
// workbooks from the binder for context. What comes back is a suggestion for each account,
// which a person reviews before anything is applied.
//
// This file builds the request and reads the reply. It makes no network call itself.

public enum AIGrouping {

    /// The model asked. Claude Opus 5.5.
    public static let model = "claude-opus-5-5"
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2026-10-21"
    /// Lets the API hand a request it declines to another model, instead of failing.
    public static let betaHeader = "server-side-fallback-2026-07-01"
    /// The most that is sent in one request, in tokens (estimated). The model reads up to a
    /// million; this leaves room for its reasoning and its answer.
    public static let inputLimit = 700_000

    /// One suggestion: an account and the grouping proposed for it.
    public struct Proposal: Equatable, Identifiable, Sendable {
        public var account: String
        /// A grouping id from the file's list, or nil when the model found none that fits.
        public var grouping: String?
        /// "high", "medium" or "low".
        public var confidence: String
        public var reason: String

        public var id: String { account }

        public init(account: String, grouping: String?, confidence: String, reason: String) {
            self.account = account
            self.grouping = grouping
            self.confidence = confidence
            self.reason = reason
        }
    }

    /// A workbook or text file from the binder, sent for context.
    public struct ContextFile: Equatable, Sendable {
        public var name: String
        public var sheets: [RawSheet]

        public init(name: String, sheets: [RawSheet]) {
            self.name = name
            self.sheets = sheets
        }
    }

    // MARK: What is sent

    /// A sheet as plain tab-separated lines: every tab's cells, with empty rows and the empty
    /// cells at the end of each row left out. Nothing that holds a value is dropped.
    public static func lightweight(_ sheet: RawSheet) -> String {
        var lines: [String] = []
        for row in sheet.rows {
            var cells = row.map { $0.trimmed.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            while let last = cells.last, last.isEmpty { cells.removeLast() }
            if !cells.isEmpty { lines.append(cells.joined(separator: "\t")) }
        }
        return lines.joined(separator: "\n")
    }

    public static func lightweight(_ file: ContextFile) -> String {
        file.sheets.map { sheet in
            let body = lightweight(sheet)
            return "<sheet name=\"\(sheet.name)\">\n\(body.isEmpty ? "(empty)" : body)\n</sheet>"
        }.joined(separator: "\n")
    }

    /// A rough count of the tokens a text will use: about one for every three characters
    /// (figures take more than words). Good enough to say whether a request is small, large, or too large.
    public static func estimatedTokens(_ text: String) -> Int { Int((Double(text.utf8.count) / 3.0).rounded(.up)) }

    public static let system = """
    You are helping a CPA prepare tax workpapers. The trial balances of one client have been \
    imported into a workpaper tool, and each account has to be assigned to a grouping: a line of \
    the tax return or a lead schedule. Your job is a first pass at the accounts that have no \
    grouping yet. A person will review every suggestion before it is applied.

    How to decide:
    - Use only groupings from the grouping list you are given, by their id. Never invent one.
    - This client's books come first. Where accounts are already grouped, follow the same \
    treatment for accounts of the same kind: that shows how this preparer groups this client.
    - Then use the account's name, its number and where it falls in the chart, its balance and \
    sign in each trial balance, and anything the context workbooks show about it.
    - A grouping with a parent is a subgroup. Prefer the subgroup when one fits; otherwise use \
    the grouping itself.
    - Give one suggestion for every account in the list to group, and no others.
    - If nothing in the list fits, give an empty grouping and say why. Do not force a fit.
    - Confidence is high when the account's nature is plain, medium when it is likely, low when \
    you are choosing between plausible lines or guessing from little.
    - Keep each reason to one short sentence a reviewer can check at a glance.
    """

    /// How many accounts are asked about in one request. A larger chart is sent in several
    /// requests, one after another, each with the same background.
    public static let batchSize = 200

    public static func batches(_ accounts: [Account]) -> [[Account]] {
        stride(from: 0, to: accounts.count, by: batchSize).map { Array(accounts[$0..<min($0 + batchSize, accounts.count)]) }
    }

    private static func clean(_ s: String) -> String { s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }

    /// The background every request carries: the client, the grouping list, the accounts already
    /// grouped (leaving out `toGroup`, the ones being asked about), and any context files.
    public static func background(for e: Engagement, toGroup: [Account], context: [ContextFile] = []) -> String {
        var out = "Client: \(clean(e.name))\nYear end: \(e.periodEnd)\n"
        if !e.binder.entityType.isEmpty { out += "Entity type: \(clean(e.binder.entityType))\n" }
        out += "Trial balances: \(e.entities.map { clean($0.name) }.joined(separator: ", "))\n\n"

        for file in context {
            out += "<context_file name=\"\(clean(file.name))\">\n\(lightweight(file))\n</context_file>\n\n"
        }

        out += "<grouping_list>\nid\tcode\tname\tsection\taccount type\tsubgroup of (id)\n"
        for item in e.groupingOutline {
            let g = item.grouping
            out += [g.id, e.groupingCode(g.id), g.name, g.section, e.groupingType(g.id)?.label ?? "", g.parent ?? ""].map(clean).joined(separator: "\t") + "\n"
        }
        out += "</grouping_list>\n\n"

        let asked = Set(toGroup.map(\.id))
        let grouped = e.sortedAccounts.filter { $0.grouping != nil && e.grouping($0.grouping) != nil && !asked.contains($0.id) }
        out += "<accounts_already_grouped>\n"
        out += grouped.isEmpty ? "(none yet)\n" : "account number\taccount name\tgrouping id\n"
        for a in grouped { out += [a.number, a.name, a.grouping ?? ""].map(clean).joined(separator: "\t") + "\n" }
        out += "</accounts_already_grouped>\n"
        return out
    }

    /// The question itself: the accounts to group, with each one's final balance in every trial
    /// balance (and last year's, where the file has it).
    public static func question(for e: Engagement, accounts: [Account]) -> String {
        let ledger = Ledger(e)
        let last = ledger.priorYears.first
        var out = "<accounts_to_group>\naccount id\taccount number\taccount name\t" + e.entities.map { "balance in " + clean($0.name) }.joined(separator: "\t")
        if let last { out += "\tprior year (\(last)) balance, all trial balances" }
        out += "\n"
        for a in accounts {
            var cells = [a.id, a.number, a.name].map(clean)
            cells += e.entities.map { ledger.value(.book, entity: $0.id, account: a.id).plain }
            if let last { cells.append(ledger.priorConsolidated(.book, year: last, account: a.id).plain) }
            out += cells.joined(separator: "\t") + "\n"
        }
        out += "</accounts_to_group>\n"
        out += "Balances are debits positive, credits negative.\n\n"
        out += "Suggest a grouping for each of the \(accounts.count) accounts in accounts_to_group, using the account id exactly as given."
        return out
    }

    /// Everything one request sends, as text: what the size estimate is taken from.
    public static func message(for e: Engagement, accounts: [Account], context: [ContextFile] = []) -> String {
        background(for: e, toGroup: accounts, context: context) + "\n" + question(for: e, accounts: accounts)
    }

    /// The shape the answer has to take.
    static var schema: JSONValue {
        func string(_ extra: [JSONField] = []) -> JSONValue { .object([JSONField("type", .string("string"))] + extra) }
        let item = JSONValue.object([
            JSONField("type", .string("object")),
            JSONField("properties", .object([
                JSONField("account", string([JSONField("description", .string("The account id, exactly as given."))])),
                JSONField("grouping", string([JSONField("description", .string("A grouping id from the grouping list, or an empty string if none fits."))])),
                JSONField("confidence", string([JSONField("enum", .array([.string("high"), .string("medium"), .string("low")]))])),
                JSONField("reason", string()),
            ])),
            JSONField("required", .array(["account", "grouping", "confidence", "reason"].map { .string($0) })),
            JSONField("additionalProperties", .bool(false)),
        ])
        return .object([
            JSONField("type", .string("object")),
            JSONField("properties", .object([JSONField("assignments", .object([JSONField("type", .string("array")), JSONField("items", item)]))])),
            JSONField("required", .array([.string("assignments")])),
            JSONField("additionalProperties", .bool(false)),
        ])
    }

    /// The body of a request to the Messages API: streamed, with the answer held to the schema.
    /// `reused` marks the background as something later requests repeat, so a chart sent in
    /// several requests is only charged in full for it once.
    public static func requestBody(background: String, question: String, reused: Bool = false) -> Data {
        var first = [JSONField("type", .string("text")), JSONField("text", .string(background))]
        if reused { first.append(JSONField("cache_control", .object([JSONField("type", .string("ephemeral"))]))) }
        let content = JSONValue.array([.object(first), .object([JSONField("type", .string("text")), JSONField("text", .string(question))])])
        let body = JSONValue.object([
            JSONField("model", .string(model)),
            JSONField("max_tokens", .int(64_000)),
            JSONField("stream", .bool(true)),
            JSONField("thinking", .object([JSONField("type", .string("adaptive"))])),
            JSONField("output_config", .object([
                JSONField("effort", .string("high")),
                JSONField("format", .object([JSONField("type", .string("json_schema")), JSONField("schema", schema)])),
            ])),
            JSONField("fallbacks", .string("default")),
            JSONField("system", .string(system)),
            JSONField("messages", .array([.object([JSONField("role", .string("user")), JSONField("content", content)])])),
        ])
        return Data(body.render().utf8)
    }

    // MARK: What comes back

    /// Puts a streamed reply together, one line of the stream at a time.
    public struct Stream: Sendable {
        public private(set) var text = ""
        public private(set) var stopReason = ""
        public private(set) var model = ""
        public private(set) var inputTokens = 0
        public private(set) var outputTokens = 0
        /// Set when the stream carries an error from the API.
        public private(set) var error: String?

        public init() {}

        public mutating func feed(line: String) {
            guard line.hasPrefix("data:") else { return }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any], let type = object["type"] as? String else { return }
            switch type {
            case "message_start":
                let message = object["message"] as? [String: Any]
                model = message?["model"] as? String ?? model
                inputTokens = ((message?["usage"] as? [String: Any])?["input_tokens"] as? Int) ?? inputTokens
            case "content_block_delta":
                let delta = object["delta"] as? [String: Any]
                if delta?["type"] as? String == "text_delta", let piece = delta?["text"] as? String { text += piece }
            case "message_delta":
                stopReason = ((object["delta"] as? [String: Any])?["stop_reason"] as? String) ?? stopReason
                outputTokens = ((object["usage"] as? [String: Any])?["output_tokens"] as? Int) ?? outputTokens
            case "error":
                let e = object["error"] as? [String: Any]
                error = AIGrouping.explain(type: e?["type"] as? String ?? "", message: e?["message"] as? String ?? "The API reported an error.")
            default: break
            }
        }
    }

    /// An API error in words a person can act on.
    public static func explain(status: Int = 0, type: String, message: String) -> String {
        switch (status, type) {
        case (401, _), (_, "authentication_error"): return "The API key wasn't accepted. Check it in TB Tool ▸ Settings ▸ AI."
        case (402, _), (_, "billing_error"): return "Anthropic reports a billing problem on this account: \(message)"
        case (403, _), (_, "permission_error"): return "This API key isn't allowed to do that: \(message)"
        case (404, _), (_, "not_found_error"): return "The model \(model) isn't available to this API key."
        case (413, _), (_, "request_too_large"): return "The request was too large. Choose fewer context files."
        case (429, _), (_, "rate_limit_error"): return "The account's rate limit was reached. Wait a minute and try again. (\(message))"
        case (529, _), (_, "overloaded_error"): return "Anthropic's service is busy just now. Try again in a minute."
        case (500..., _), (_, "api_error"): return "Anthropic's service had a problem. Try again in a minute."
        default: return message.isEmpty ? "The request failed (\(status))." : message
        }
    }

    /// Reads the model's answer into suggestions. Only accounts that were asked about are kept,
    /// and only groupings that are in the file's list: an id that isn't is tried as a code or a
    /// name, and failing that the suggestion is kept with no grouping.
    public static func proposals(from text: String, for e: Engagement, asked: [Account]) throws -> [Proposal] {
        guard let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any], let list = root["assignments"] as? [[String: Any]] else {
            throw TBError("The reply couldn't be read. Nothing was changed.")
        }
        let wanted = Set(asked.map(\.id))
        var seen = Set<String>()
        var out: [Proposal] = []
        for item in list {
            guard let account = item["account"] as? String, wanted.contains(account), seen.insert(account).inserted else { continue }
            let raw = (item["grouping"] as? String ?? "").trimmed
            let grouping = raw.isEmpty ? nil : (e.grouping(raw)?.id ?? e.resolveGrouping(raw)?.id)
            let confidence = ["high", "medium", "low"].contains(item["confidence"] as? String ?? "") ? item["confidence"] as! String : "low"
            var reason = (item["reason"] as? String ?? "").trimmed
            if grouping == nil && !raw.isEmpty { reason = "Suggested “\(raw)”, which isn't in the grouping list. " + reason }
            out.append(Proposal(account: account, grouping: grouping, confidence: grouping == nil ? "low" : confidence, reason: reason))
        }
        // In chart order, as the accounts were asked about.
        let order = Dictionary(uniqueKeysWithValues: asked.enumerated().map { ($1.id, $0) })
        return out.sorted { (order[$0.account] ?? 0) < (order[$1.account] ?? 0) }
    }

    /// Applies the suggestions that were accepted. Returns how many accounts were grouped.
    @discardableResult
    public static func apply(_ proposals: [Proposal], to e: inout Engagement) -> Int {
        var n = 0
        for p in proposals {
            guard let g = p.grouping, e.grouping(g) != nil, e.account(p.account) != nil else { continue }
            e.setGrouping(g, forAccounts: [p.account])
            n += 1
        }
        return n
    }
}
