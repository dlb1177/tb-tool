import SwiftUI
import TBCore

/// Change a trial balance's unadjusted balances — or a prior year's closing balances — by typing
/// them. Everything is saved to the JSON file in one step that can be undone.
struct BalanceEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var closeWindow

    let entityID: String
    let priorYear: Int?
    let closeGuard: CloseGuard

    private struct Typed: Equatable {
        var debit = ""
        var credit = ""
    }

    @State private var typed: [String: Typed]
    @State private var listed: Set<String>
    @State private var original: [String: Money]
    @State private var search = ""
    @State private var showAll = false
    @State private var onlyChanged = false
    @State private var addID: String?

    init(entityID: String, priorYear: Int?, engagement: Engagement, closeGuard: CloseGuard) {
        self.entityID = entityID
        self.priorYear = priorYear
        self.closeGuard = closeGuard
        let balances = engagement.editableBalances(entity: entityID, priorYear: priorYear)
        var typed: [String: Typed] = [:]
        var original: [String: Money] = [:]
        for b in balances {
            original[b.account] = b.amount
            typed[b.account] = Typed(debit: b.amount.cents > 0 ? b.amount.grouped : "", credit: b.amount.cents < 0 ? b.amount.grouped : "")
        }
        _typed = State(initialValue: typed)
        _original = State(initialValue: original)
        _listed = State(initialValue: Set(balances.map(\.account)))
        // A trial balance with nothing in it yet starts with the whole chart to key into.
        _showAll = State(initialValue: balances.isEmpty)
    }

    private var engagement: Engagement { model.engagement ?? Engagement(name: "", periodEnd: "") }

    /// The amount typed for an account: debit less credit. Nil when either isn't a number.
    private func amount(_ id: String) -> Money? {
        let t = typed[id] ?? Typed()
        guard let d = Money.parse(t.debit), let c = Money.parse(t.credit) else { return nil }
        return d.value - c.value
    }

    private func isChanged(_ id: String) -> Bool {
        guard let a = amount(id) else { return true }
        return a != (original[id] ?? .zero)
    }

    var body: some View {
        let e = engagement
        let entity = e.entity(entityID)
        let all = e.sortedAccounts
        let terms = search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let rows = all.filter { a in
            guard showAll || listed.contains(a.id) else { return false }
            if onlyChanged && !isChanged(a.id) { return false }
            let hay = a.display.lowercased()
            return terms.allSatisfy { hay.contains($0) }
        }
        let ids = Set(typed.keys).union(listed)
        let bad = ids.filter { amount($0) == nil }
        let amounts = ids.compactMap { amount($0) }
        let debits = amounts.map(\.debit).sum(), credits = amounts.map(\.credit).sum()
        let difference = debits - credits
        let changed = ids.filter { isChanged($0) }.count

        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(entity?.name ?? "") — \(periodTitle(e))").font(.title3.bold())
                Text(priorYear == nil
                     ? "These are the balances before any journal entries. Type a debit or a credit to correct what was imported, or to key in a trial balance by hand. Journal entries are untouched."
                     : "Closing balances for \(String(priorYear!)), shown beside this year's as \(e.priorLabel(priorYear!)). Type a debit or a credit.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            HStack(spacing: 10) {
                SearchBox(prompt: "Find an account", text: $search)
                    .frame(minWidth: 120, idealWidth: 180, maxWidth: 200)
                Toggle("All chart accounts", isOn: $showAll)
                    .fixedSize()
                    .help("List every account in the chart, not only the ones this trial balance has a balance for")
                Toggle("Only changed", isOn: $onlyChanged)
                    .fixedSize()
                Spacer(minLength: 4)
                AccountSearchField(accounts: all.filter { !listed.contains($0.id) }, accountID: $addID, placeholder: "Add an account — number or name")
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 260)
                Button("New Account…") { model.showNewAccount() }
                    .fixedSize()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()
            columnTitles
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, a in
                            row(a, shaded: index.isMultiple(of: 2))
                                .id(a.id)
                        }
                    }
                }
                .onChange(of: addID) { _, new in
                    guard let new else { return }
                    listed.insert(new)
                    search = ""
                    onlyChanged = false
                    addID = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { withAnimation { proxy.scrollTo(new, anchor: .center) } }
                }
            }
            if rows.isEmpty {
                Text(showAll || !listed.isEmpty ? "No accounts match." : "No balances yet. Turn on “All chart accounts” or add an account above.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    if !bad.isEmpty {
                        Label("\(bad.count) amount\(bad.count == 1 ? " isn't a number" : "s aren't numbers")", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                    } else if difference.isZero {
                        CheckBadge(ok: true, text: "In balance")
                    } else {
                        CheckBadge(ok: false, text: "Out of balance by \((difference.cents < 0 ? -difference : difference).grouped)")
                    }
                    Text(changed == 0 ? "Nothing changed yet" : "\(changed) balance\(changed == 1 ? "" : "s") changed")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                total("Debits", debits.grouped)
                total("Credits", credits.grouped)
                total("Difference", (difference.cents < 0 ? -difference : difference).grouped, warn: !difference.isZero)
                Button("Cancel") { closeWindow() }
                    .keyboardShortcut(.cancelAction)
                Button(difference.isZero ? "Save Balances" : "Save Out of Balance") { save(ids) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!bad.isEmpty || changed == 0)
            }
            .padding(14)
        }
        .frame(minWidth: 700, minHeight: 420)
        .onChange(of: typed) { _, _ in closeGuard.isDirty = Set(typed.keys).union(listed).contains { isChanged($0) } }
    }

    private func periodTitle(_ e: Engagement) -> String {
        if let priorYear { return "\(e.priorLabel(priorYear)) closing balances" }
        return "Unadjusted balances" + (e.currentYear.map { " for \($0)" } ?? "")
    }

    private var columnTitles: some View {
        HStack(spacing: 8) {
            Text("Account").frame(width: 90, alignment: .leading)
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Was").frame(width: 120, alignment: .trailing)
            Text("Debit").frame(width: 120, alignment: .trailing)
            Text("Credit").frame(width: 120, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private func row(_ a: Account, shaded: Bool) -> some View {
        let changed = isChanged(a.id)
        let invalid = amount(a.id) == nil
        let was = original[a.id]
        return HStack(spacing: 8) {
            Text(a.number.isEmpty ? "—" : a.number)
                .monospacedDigit()
                .frame(width: 90, alignment: .leading)
            Text(a.name)
                .lineLimit(1)
                .fontWeight(changed ? .semibold : .regular)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(changed ? (was.map { $0.isZero ? "0.00" : $0.formatted } ?? "new") : "")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .trailing)
            field(a.id, \.debit, clears: \.credit)
            field(a.id, \.credit, clears: \.debit)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
        .background(invalid ? Color.orange.opacity(0.15) : (changed ? Color.accentColor.opacity(0.08) : (shaded ? Color.primary.opacity(0.025) : Color.clear)))
    }

    private func field(_ id: String, _ path: WritableKeyPath<Typed, String>, clears other: WritableKeyPath<Typed, String>) -> some View {
        TextField("", text: Binding(get: { (typed[id] ?? Typed())[keyPath: path] }, set: { new in
            var t = typed[id] ?? Typed()
            t[keyPath: path] = new
            if !new.trimmingCharacters(in: .whitespaces).isEmpty { t[keyPath: other] = "" }
            typed[id] = t
            listed.insert(id)
        }))
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .frame(width: 120)
    }

    private func total(_ label: String, _ value: String, warn: Bool = false) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(warn ? Color.orange : Color.primary)
        }
        .frame(minWidth: 90, alignment: .trailing)
    }

    private func save(_ ids: Set<String>) {
        let balances = ids.compactMap { id -> Balance? in
            guard let a = amount(id) else { return nil }
            if a.isZero && original[id] == nil { return nil }
            return Balance(account: id, amount: a)
        }
        let name = engagement.entity(entityID)?.name ?? ""
        let action = priorYear.map { "Edit \(name) \($0) Balances" } ?? "Edit \(name) Balances"
        if model.mutate(action, { try $0.setBalances(balances, for: entityID, priorYear: priorYear) }) {
            model.status = "Saved \(name) balances"
            closeGuard.isDirty = false
            closeWindow()
        }
    }
}
