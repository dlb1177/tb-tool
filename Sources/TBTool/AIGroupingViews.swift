import AppKit
import Security
import SwiftUI
import TBCore

// A first pass at grouping accounts by Claude Opus 5.5. This is the one thing in TB Tool that
// sends anything off the Mac, and only when asked: the accounts with no grouping, the grouping
// list, the accounts already grouped, and whichever binder workbooks are ticked go to
// Anthropic's API under the user's own API key. Nothing is applied until it has been reviewed.

/// The Anthropic API key, kept in the Mac's Keychain. It is never written to a trial balance
/// file or to the app's preferences.
enum AIKey {
    private static let service = "TB Tool Anthropic API key"
    private static let account = "anthropic"
    /// Pictures for the manual and tests never touch the real Keychain.
    private static var memory: String?
    private static var inMemory: Bool { CommandLine.arguments.contains("--tb-snapshot") }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func load() -> String? {
        if inMemory { return memory }
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? nil : key
    }

    static var isSet: Bool { load() != nil }

    static func save(_ raw: String) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw TBError("Paste the API key first.") }
        if inMemory { memory = key; return }
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrLabel as String] = service
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TBError("The Keychain wouldn't save the key: \(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)").")
        }
    }

    static func delete() {
        if inMemory { memory = nil; return }
        SecItemDelete(query as CFDictionary)
    }
}

/// The call to Anthropic's Messages API.
enum AIClient {
    /// Where requests go. Only the pictures for the manual, which answer from a stand-in on this Mac, change it.
    static var endpoint = AIGrouping.endpoint

    /// Sends one request and reads the streamed reply. `progress` is told how many characters of
    /// the answer have arrived. A busy or rate-limited service is tried again twice.
    static func send(_ body: Data, key: String, progress: @escaping @MainActor (Int) -> Void) async throws -> AIGrouping.Stream {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(AIGrouping.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(AIGrouping.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.httpBody = body

        var attempt = 0
        while true {
            let bytes: URLSession.AsyncBytes, response: URLResponse
            do {
                (bytes, response) = try await URLSession.shared.bytes(for: request)
            } catch let error as URLError where error.code != .cancelled {
                throw TBError("Couldn't reach Anthropic: \(error.localizedDescription)")
            }
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            guard status == 200 else {
                var data = Data()
                for try await byte in bytes {
                    data.append(byte)
                    if data.count > 200_000 { break }
                }
                let error = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? [String: Any]
                if [429, 500, 529].contains(status), attempt < 2 {
                    attempt += 1
                    let wait = min(Double(http?.value(forHTTPHeaderField: "retry-after") ?? "") ?? Double(attempt * 5), 30)
                    try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    continue
                }
                throw TBError(AIGrouping.explain(status: status, type: error?["type"] as? String ?? "", message: error?["message"] as? String ?? ""))
            }
            var stream = AIGrouping.Stream()
            var reported = 0
            for try await line in bytes.lines {
                stream.feed(line: line)
                if stream.text.count - reported >= 200 {
                    reported = stream.text.count
                    await progress(reported)
                }
            }
            return stream
        }
    }
}

/// One run of the AI grouping window: what was ticked, how far it has got, what came back.
final class AIGroupingRun: ObservableObject {
    enum Stage: Equatable { case choose, working, review }

    @Published var stage = Stage.choose
    /// Binder paths ticked to be sent for context.
    @Published var picked = Set<String>()
    /// The estimated size of each ticked file, in tokens; nil while it is being read.
    @Published var sizes: [String: Int] = [:]
    @Published var unreadable: [String: String] = [:]
    @Published var hasKey = AIKey.isSet
    @Published var progress = ""
    @Published var failure: String?
    /// Something the reviewer should know about what came back: accounts with no answer, a run that stopped part way.
    @Published var warning: String?
    @Published var proposals: [AIGrouping.Proposal] = []
    @Published var accepted = Set<String>()
    @Published var servedBy = AIGrouping.model
    private var task: Task<Void, Never>?
    private var loaded: [String: AIGrouping.ContextFile] = [:]
    /// The run in the open window, for the pictures in the manual.
    static weak var current: AIGroupingRun?

    init() { AIGroupingRun.current = self }

    /// The spreadsheet files in the binder: what can be sent along for context.
    static func candidates(_ tree: BinderTree?) -> [BinderItem] {
        guard let tree else { return [] }
        let kinds: Set<String> = ["xlsx", "xlsm", "csv", "tsv"]
        return tree.files.filter { kinds.contains(($0.name as NSString).pathExtension.lowercased()) && !$0.name.hasPrefix("~$") && !$0.isPlaceholder }
    }

    func toggle(_ item: BinderItem, in tree: BinderTree) {
        if picked.contains(item.path) {
            picked.remove(item.path)
        } else {
            picked.insert(item.path)
            read(item, in: tree)
        }
    }

    func pick(_ items: [BinderItem], in tree: BinderTree) {
        for item in items where !picked.contains(item.path) {
            picked.insert(item.path)
            read(item, in: tree)
        }
    }

    /// Reads a ticked workbook off the main thread, so its size can be shown before anything is sent.
    private func read(_ item: BinderItem, in tree: BinderTree) {
        guard loaded[item.path] == nil, unreadable[item.path] == nil else { return }
        let url = tree.url(item), path = item.path, name = item.name
        Task.detached(priority: .userInitiated) {
            let result = Result { AIGrouping.ContextFile(name: name, sheets: try SourceReader.read(url: url)) }
            let size = (try? result.get()).map { AIGrouping.estimatedTokens(AIGrouping.lightweight($0)) }
            await MainActor.run {
                switch result {
                case .success(let file):
                    self.loaded[path] = file
                    self.sizes[path] = size ?? 0
                case .failure(let error):
                    self.unreadable[path] = error.localizedDescription
                }
            }
        }
    }

    var stillReading: Bool { picked.contains { sizes[$0] == nil && unreadable[$0] == nil } }

    func context() -> [AIGrouping.ContextFile] { picked.sorted().compactMap { loaded[$0] } }

    /// About how many tokens the request will carry.
    func estimate(_ e: Engagement) -> Int {
        let accounts = e.ungroupedAccounts
        let base = AIGrouping.estimatedTokens(AIGrouping.system + AIGrouping.background(for: e, toGroup: accounts)
            + AIGrouping.question(for: e, accounts: AIGrouping.batches(accounts).first ?? []))
        return base + picked.reduce(0) { $0 + (sizes[$1] ?? 0) }
    }

    func start(_ model: AppModel) {
        guard let e = model.engagement, let key = AIKey.load() else { return }
        let accounts = e.ungroupedAccounts
        guard !accounts.isEmpty else { return }
        if let bad = picked.sorted().first(where: { unreadable[$0] != nil }) {
            failure = "\((bad as NSString).lastPathComponent) can't be read: \(unreadable[bad] ?? ""). Untick it and send again."
            return
        }
        let size = estimate(e)
        guard size <= AIGrouping.inputLimit else {
            failure = "That is about \(size.formatted()) tokens, more than one request can carry (\(AIGrouping.inputLimit.formatted())). Untick some of the larger files and send again. Nothing was sent."
            return
        }
        let files = context()
        let batches = AIGrouping.batches(accounts)
        let background = AIGrouping.background(for: e, toGroup: accounts, context: files)
        failure = nil
        warning = nil
        proposals = []
        stage = .working
        progress = "Sending \(accounts.count) account\(accounts.count == 1 ? "" : "s") to Claude Opus 5.5…"
        model.record("Asked Claude for groupings", [
            "Sent \(accounts.count) ungrouped account\(accounts.count == 1 ? "" : "s"), the grouping list and the grouped accounts to Anthropic (\(AIGrouping.model))",
        ] + (files.isEmpty ? [] : ["Files sent for context: " + files.map(\.name).joined(separator: "; ")]))

        task = Task { @MainActor [weak self] in
            var found: [AIGrouping.Proposal] = []
            var stopped: String?
            var served = AIGrouping.model
            for (n, batch) in batches.enumerated() {
                let label = batches.count > 1 ? "Part \(n + 1) of \(batches.count): " : ""
                self?.progress = label + "Claude is reading the accounts…"
                do {
                    let body = AIGrouping.requestBody(background: background, question: AIGrouping.question(for: e, accounts: batch), reused: batches.count > 1)
                    let reply = try await AIClient.send(body, key: key) { count in
                        self?.progress = label + "Writing suggestions… \(count.formatted()) characters so far"
                    }
                    if let error = reply.error { throw TBError(error) }
                    switch reply.stopReason {
                    case "refusal": throw TBError("Claude declined this request, so there are no suggestions. Try again without the context files.")
                    case "max_tokens": throw TBError("The answer was cut off before it finished.")
                    default: break
                    }
                    if !reply.model.isEmpty { served = reply.model }
                    found += try AIGrouping.proposals(from: reply.text, for: e, asked: batch)
                } catch is CancellationError {
                    return
                } catch let error as URLError where error.code == .cancelled {
                    return
                } catch {
                    stopped = error.localizedDescription
                    break
                }
            }
            guard !Task.isCancelled else { return }
            self?.finish(found, asked: accounts, stopped: stopped, servedBy: served)
        }
    }

    /// Shows what came back. Suggestions Claude was unsure of start unticked.
    func finish(_ found: [AIGrouping.Proposal], asked: [Account], stopped: String? = nil, servedBy: String = AIGrouping.model) {
        self.servedBy = servedBy
        if found.isEmpty {
            failure = stopped ?? "Claude gave no suggestions."
            stage = .choose
            return
        }
        proposals = found
        accepted = Set(found.filter { $0.grouping != nil && $0.confidence != "low" }.map(\.account))
        let missing = asked.count - found.count
        var notes: [String] = []
        if let stopped { notes.append("It stopped part way: \(stopped)") }
        if missing > 0 { notes.append("\(missing) account\(missing == 1 ? " has" : "s have") no suggestion; run it again for the rest.") }
        warning = notes.isEmpty ? nil : notes.joined(separator: " ")
        stage = .review
    }

    func cancel() {
        task?.cancel()
        task = nil
        stage = .choose
        progress = ""
    }

    func setGrouping(_ grouping: String?, for account: String) {
        guard let i = proposals.firstIndex(where: { $0.account == account }) else { return }
        proposals[i].grouping = grouping
        if grouping == nil { accepted.remove(account) } else { accepted.insert(account) }
    }

    /// Applies the ticked suggestions as one change that ⌘Z takes back.
    func apply(_ model: AppModel) -> Bool {
        let chosen = proposals.filter { accepted.contains($0.account) && $0.grouping != nil }
        guard !chosen.isEmpty else { return false }
        var n = 0
        let ok = model.mutate("Group Accounts with AI", notes: ["Applied \(chosen.count) grouping\(chosen.count == 1 ? "" : "s") suggested by Claude (\(servedBy)) after review"]) {
            n = AIGrouping.apply(chosen, to: &$0)
        }
        if ok { model.status = "Grouped \(n) account\(n == 1 ? "" : "s") from Claude's suggestions. ⌘Z undoes it." }
        return ok
    }
}

/// The window: choose what to send, wait, then review what came back.
struct AIGroupingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var closeWindow
    @StateObject var run = AIGroupingRun()
    @State private var query = ""
    @State private var show = "all"

    var body: some View {
        if let e = model.engagement {
            VStack(spacing: 0) {
                switch run.stage {
                case .choose: choose(e)
                case .working: working
                case .review: review(e)
                }
            }
            .frame(minWidth: 760, minHeight: 520)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in run.hasKey = AIKey.isSet }
            .onReceive(NotificationCenter.default.publisher(for: AISettings.keyChanged)) { _ in run.hasKey = AIKey.isSet }
        }
    }

    // MARK: Choosing what to send

    private func choose(_ e: Engagement) -> some View {
        let ungrouped = e.ungroupedAccounts
        let grouped = e.accounts.count - ungrouped.count
        let files = AIGroupingRun.candidates(model.binder)
        let shown = files.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(ungrouped.isEmpty ? "Every account is grouped" : "\(ungrouped.count) account\(ungrouped.count == 1 ? " has" : "s have") no grouping")
                    .font(.title3.weight(.semibold))
                Text(intro(ungrouped: ungrouped.count, grouped: grouped))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Divider()
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Files to send for context").font(.headline)
                    Text("Optional. Tick workbooks from the binder that show how these accounts were treated: last year's grouped trial balance, a prior workpaper. Every tab of each one is sent.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            if files.isEmpty {
                Text(model.binder == nil ? "This trial balance isn't in a binder folder, so there are no files to add. The trial balances already imported are sent on their own."
                                         : "There are no Excel or CSV files in the binder. The trial balances already imported are sent on their own.")
                    .foregroundStyle(.secondary)
                    .padding(16)
                Spacer()
            } else if let tree = model.binder {
                HStack(spacing: 8) {
                    SearchBox(prompt: "Search the binder's workbooks", text: $query)
                        .frame(maxWidth: 280)
                    Button("Tick All \(shown.count)") { run.pick(shown, in: tree) }
                        .disabled(shown.allSatisfy { run.picked.contains($0.path) })
                    Button("Untick All") { run.picked = [] }
                        .disabled(run.picked.isEmpty)
                    Spacer()
                    Text("\(run.picked.count) of \(files.count) ticked").foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.path) { n, item in
                            fileRow(item, tree: tree, shaded: n % 2 == 1)
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
            Divider()
            if let failure = run.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if run.hasKey {
                        Text(sentLine(e, ungrouped.count))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("This goes to Anthropic's API under your API key, and Anthropic bills that account for it. Nothing else in the file or the binder is sent.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Label("No Anthropic API key is saved on this Mac yet.", systemImage: "key")
                        Text("Add one under TB Tool ▸ Settings ▸ AI. It is kept in the Keychain.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                Spacer()
                if !run.hasKey { Button("Add API Key…") { model.showAppSettings(tab: "ai") } }
                Button("Cancel") { closeWindow() }
                    .keyboardShortcut(.cancelAction)
                Button("Send to Claude") { run.start(model) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ungrouped.isEmpty || !run.hasKey || run.stillReading)
            }
            .padding(12)
        }
    }

    private func intro(ungrouped: Int, grouped: Int) -> String {
        guard ungrouped > 0 else {
            return "There is nothing to suggest. Clear an account's grouping on the Accounts screen to have Claude look at it again."
        }
        var text = "Claude Opus 5.5 suggests a grouping for each of them from this file's grouping list"
        if grouped > 0 {
            text += ", following how the \(grouped) account\(grouped == 1 ? "" : "s") already grouped here \(grouped == 1 ? "is" : "are") treated."
        } else {
            text += ". No account is grouped yet, so it has only the list to go on."
        }
        return text + " You review every suggestion before anything changes."
    }

    private func sentLine(_ e: Engagement, _ count: Int) -> String {
        let files = run.picked.count
        var line = "Sending: \(count) account\(count == 1 ? "" : "s") with balances, the grouping list"
        line += files == 0 ? "" : ", and \(files) workbook\(files == 1 ? "" : "s")"
        line += run.stillReading ? " — reading the files…" : " — about \(run.estimate(e).formatted()) tokens"
        if count > AIGrouping.batchSize { line += ", in \(AIGrouping.batches(e.ungroupedAccounts).count) requests" }
        return line + "."
    }

    private func fileRow(_ item: BinderItem, tree: BinderTree, shaded: Bool) -> some View {
        let on = run.picked.contains(item.path)
        return HStack(spacing: 8) {
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .foregroundStyle(on ? Color.accentColor : .secondary)
                .font(.system(size: 14))
            Text(item.index?.text ?? "—")
                .monospacedDigit()
                .foregroundStyle(item.index == nil ? .tertiary : .secondary)
                .frame(width: 72, alignment: .leading)
            Text(item.displayTitle).lineLimit(1)
            if !item.parentPath.isEmpty {
                Text(item.parentPath).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if on {
                if let why = run.unreadable[item.path] {
                    Label("Can't be read", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).help(why)
                } else if let size = run.sizes[item.path] {
                    Text("about \(size.formatted()) tokens").foregroundStyle(.secondary).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .background(shaded ? Color.primary.opacity(0.03) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { run.toggle(item, in: tree) }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(item.displayTitle), \(on ? "ticked" : "not ticked")")
    }

    // MARK: Waiting

    private var working: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(run.progress).font(.headline)
            Text("This can take a minute or two. The trial balance isn't changed while you wait.")
                .foregroundStyle(.secondary)
            Button("Stop") { run.cancel() }
                .keyboardShortcut(.cancelAction)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }

    // MARK: Reviewing

    private func review(_ e: Engagement) -> some View {
        let ledger = model.ledger ?? Ledger(e)
        let rows = run.proposals.filter { p in
            switch show {
            case "high", "medium", "low": return p.confidence == show && p.grouping != nil
            case "none": return p.grouping == nil
            default: return true
            }
        }
        let chosen = run.proposals.filter { run.accepted.contains($0.account) && $0.grouping != nil }.count
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Claude's suggestions for \(run.proposals.count) account\(run.proposals.count == 1 ? "" : "s")")
                    .font(.title3.weight(.semibold))
                Text("Tick the ones to apply. Change any grouping from its menu first. The ones Claude was unsure of start unticked.")
                    .foregroundStyle(.secondary)
                if let warning = run.warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            Divider()
            HStack(spacing: 8) {
                Picker("Show", selection: $show) {
                    Text("All \(run.proposals.count)").tag("all")
                    ForEach(["high", "medium", "low"], id: \.self) { level in
                        Text("\(level.capitalized) \(run.proposals.filter { $0.confidence == level && $0.grouping != nil }.count)").tag(level)
                    }
                    Text("No fit \(run.proposals.filter { $0.grouping == nil }.count)").tag("none")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Tick Shown") { run.accepted.formUnion(rows.filter { $0.grouping != nil }.map(\.account)) }
                Button("Untick Shown") { run.accepted.subtract(rows.map(\.account)) }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            Divider()
            HStack(spacing: 10) {
                Text("").frame(width: 18)
                Text("Account").frame(width: 230, alignment: .leading)
                Text("Balance").frame(width: 96, alignment: .trailing)
                Text("Suggested grouping").frame(width: 260, alignment: .leading)
                Text("Confidence").frame(width: 74, alignment: .leading)
                Text("Why").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.account) { n, p in
                        proposalRow(p, e, ledger, shaded: n % 2 == 1)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            Divider()
            HStack(spacing: 12) {
                Text("Suggestions by \(run.servedBy). Check them as you would a first-year's work.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { closeWindow() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply \(chosen) Grouping\(chosen == 1 ? "" : "s")") {
                    if run.apply(model) { closeWindow() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == 0)
            }
            .padding(12)
        }
        .frame(minWidth: 980)
    }

    private func proposalRow(_ p: AIGrouping.Proposal, _ e: Engagement, _ ledger: Ledger, shaded: Bool) -> some View {
        let account = e.account(p.account)
        let on = run.accepted.contains(p.account) && p.grouping != nil
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                if on { run.accepted.remove(p.account) } else if p.grouping != nil { run.accepted.insert(p.account) }
            } label: {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .foregroundStyle(on ? Color.accentColor : .secondary)
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .disabled(p.grouping == nil)
            .frame(width: 18)
            .accessibilityLabel(on ? "Ticked" : "Not ticked")
            Text(account?.display ?? p.account)
                .lineLimit(2)
                .frame(width: 230, alignment: .leading)
            Text(ledger.consolidated(.book, account: p.account).formatted)
                .monospacedDigit()
                .frame(width: 96, alignment: .trailing)
            Menu {
                ForEach(e.groupingSections, id: \.self) { section in
                    Menu(section) {
                        ForEach(e.groupingOutline.filter { $0.grouping.section == section }, id: \.grouping.id) { item in
                            Button(item.depth == 0 ? item.grouping.display : "      ↳ \(item.grouping.name)") { run.setGrouping(item.grouping.id, for: p.account) }
                        }
                    }
                }
                Divider()
                Button("Leave Ungrouped") { run.setGrouping(nil, for: p.account) }
            } label: {
                Text(p.grouping == nil ? "No fit — choose one" : e.groupingLabel(p.grouping))
                    .lineLimit(1)
                    .foregroundStyle(p.grouping == nil ? .secondary : .primary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 260, alignment: .leading)
            Text(p.grouping == nil ? "—" : p.confidence.capitalized)
                .foregroundStyle(p.confidence == "high" ? Color.green : p.confidence == "medium" ? Color.orange : Color.red)
                .frame(width: 74, alignment: .leading)
            Text(p.reason)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(shaded ? Color.primary.opacity(0.03) : .clear)
    }
}

/// TB Tool ▸ Settings ▸ AI: the API key, and what using it sends.
struct AISettings: View {
    static let keyChanged = Notification.Name("TBToolAIKeyChanged")

    @Environment(\.closeWindow) private var closeWindow
    @State private var typed = ""
    @State private var saved = AIKey.isSet
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Grouping accounts with Claude").font(.headline)
                    Text("On the Accounts screen, Group with AI asks Claude Opus 5.5 for a first pass at the accounts that have no grouping. It is the only thing in TB Tool that sends anything off this Mac, and only when you press Send.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Anthropic API key").font(.headline)
                    HStack(spacing: 8) {
                        SecureField(saved ? "A key is saved. Paste another to replace it." : "sk-ant-…", text: $typed)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 420)
                            .onSubmit(save)
                        Button("Save Key", action: save)
                            .disabled(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Remove Key", role: .destructive) {
                            AIKey.delete()
                            saved = false
                            NotificationCenter.default.post(name: AISettings.keyChanged, object: nil)
                        }
                        .disabled(!saved)
                    }
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    } else {
                        Label(saved ? "A key is saved in this Mac's Keychain." : "No key is saved.", systemImage: saved ? "checkmark.circle.fill" : "key")
                            .foregroundStyle(saved ? .green : .secondary)
                    }
                    Text("Create a key in the Claude Console (platform.claude.com) under API Keys. It is kept in the Keychain, never in a trial balance file. Anthropic bills the key's account for each request.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("What is sent").font(.headline)
                    ForEach([
                        "The client's name, year end and entity type, and the names of its trial balances.",
                        "The file's grouping list, and the number, name and grouping of the accounts already grouped.",
                        "The number, name and balances of the accounts that have no grouping.",
                        "Every tab of each binder workbook you tick in the window. None are ticked to start with.",
                    ], id: \.self) { line in
                        Label(line, systemImage: "circle.fill")
                            .labelStyle(BulletLabel())
                    }
                    Text("Journal entries, sign-offs, the change log and every other file stay on this Mac. Each request is noted in the change log, with the files that went with it. Check your firm's policy and the client's engagement terms before sending client data to an outside service.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                }
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack {
                Spacer()
                Button("Done") { closeWindow() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 860, minHeight: 560)
    }

    private func save() {
        do {
            try AIKey.save(typed)
            typed = ""
            saved = true
            problem = nil
            NotificationCenter.default.post(name: AISettings.keyChanged, object: nil)
        } catch {
            problem = error.localizedDescription
        }
    }
}

private struct BulletLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.font(.system(size: 4)).foregroundStyle(.secondary).offset(y: -3)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}
