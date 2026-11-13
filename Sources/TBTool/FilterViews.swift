import SwiftUI
import TBCore

struct FilterColumn: Hashable {
    let title: String
    let isAmount: Bool
    /// Set for a column with a fixed list of values (the account type): the rule picks from the list.
    var choices: [String] = []

    static let accountType = FilterColumn(title: FilterCondition.accountTypeColumn, isAmount: false, choices: AccountType.allCases.map(\.label))
}

/// Filters saved by name, per screen, in the app's preferences.
enum FilterStore {
    static func load(_ key: String) -> [SavedFilter] {
        guard let data = UserDefaults.standard.data(forKey: "TBFilters.\(key)"),
              let list = try? JSONDecoder().decode([SavedFilter].self, from: data) else { return [] }
        return list
    }

    static func save(_ filters: [SavedFilter], key: String) {
        if let data = try? JSONEncoder().encode(filters) { UserDefaults.standard.set(data, forKey: "TBFilters.\(key)") }
    }
}

/// The "Filters" button on every grid: build rules per column (text or amount tests), join them
/// with all/any, and save the ones you use again.
struct FilterButton: View {
    @Binding var filter: FilterSet
    let columns: [FilterColumn]
    let storageKey: String
    @State private var show = false

    var body: some View {
        HStack(spacing: 2) {
            Button {
                show = true
            } label: {
                Label(filter.isActive ? "Filters (\(filter.active.count))" : "Filters", systemImage: "slider.horizontal.3")
            }
            .help(filter.isActive ? filter.summary : "Filter by column: text, amounts over or under a size, debits or credits, blanks. Filters can be saved.")
            .popover(isPresented: $show, arrowEdge: .bottom) {
                FilterEditor(filter: $filter, columns: columns, storageKey: storageKey)
            }
            if filter.isActive {
                Button {
                    filter = FilterSet()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the filters")
            }
        }
    }
}

struct FilterEditor: View {
    @Binding var filter: FilterSet
    let columns: [FilterColumn]
    let storageKey: String
    @State private var saved: [SavedFilter] = []
    @State private var saveName = ""

    private func isAmount(_ title: String) -> Bool { columns.first { $0.title == title }?.isAmount ?? false }
    private func choices(_ title: String) -> [String] { columns.first { $0.title == title }?.choices ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Show rows that match")
                Picker("", selection: $filter.matchAll) {
                    Text("all").tag(true)
                    Text("any").tag(false)
                }
                .labelsHidden()
                .fixedSize()
                Text("of these rules:")
                Spacer()
                if !saved.isEmpty {
                    Menu("Saved Filters") {
                        ForEach(saved) { s in
                            Button(s.name) {
                                filter = s.filter
                                saveName = s.name
                            }
                        }
                        Divider()
                        Menu("Delete") {
                            ForEach(saved) { s in
                                Button(s.name) {
                                    saved.removeAll { $0.name == s.name }
                                    FilterStore.save(saved, key: storageKey)
                                }
                            }
                        }
                    }
                    .fixedSize()
                }
            }
            VStack(spacing: 6) {
                ForEach($filter.conditions) { $rule in
                    HStack(spacing: 6) {
                        Picker("", selection: $rule.column) {
                            Text("Any column").tag("")
                            Divider()
                            ForEach(columns, id: \.self) { Text($0.title).tag($0.title) }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                        .onChange(of: rule.column) { _, new in
                            // Keep the test in step with the kind of column.
                            let amount = isAmount(new), list = choices(new)
                            if amount && !rule.op.isAmountTest { rule.op = .atLeast }
                            if !amount && rule.op.isAmountTest { rule.op = .contains }
                            if !list.isEmpty {
                                if !FilterCondition.Op.choiceOps.contains(rule.op) { rule.op = .equals }
                                if !list.contains(rule.value) { rule.value = list[0] }
                            }
                        }
                        Picker("", selection: $rule.op) {
                            ForEach(!choices(rule.column).isEmpty ? FilterCondition.Op.choiceOps
                                    : (isAmount(rule.column) ? FilterCondition.Op.amountOps : FilterCondition.Op.textOps), id: \.self) {
                                Text(!choices(rule.column).isEmpty && $0 == .equals ? "is" : $0.label).tag($0)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        if !choices(rule.column).isEmpty {
                            Picker("", selection: $rule.value) {
                                ForEach(choices(rule.column), id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 200)
                        } else if rule.op.needsValue {
                            TextField(rule.op.isAmountTest ? "amount" : "text", text: $rule.value)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: rule.op == .between ? 90 : 200)
                            if rule.op == .between {
                                Text("and").foregroundStyle(.secondary)
                                TextField("amount", text: $rule.value2)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 90)
                            }
                        }
                        Spacer(minLength: 0)
                        Button {
                            filter.conditions.removeAll { $0.id == rule.id }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            HStack(spacing: 10) {
                Button {
                    filter.conditions.append(FilterCondition(column: columns.first?.title ?? ""))
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
                Button("Clear") { filter = FilterSet() }
                    .disabled(filter.conditions.isEmpty)
                Spacer()
                TextField("Name to save as", text: $saveName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                Button("Save Filter") {
                    let name = saveName.trimmingCharacters(in: .whitespaces)
                    saved.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                    saved.append(SavedFilter(name: name, filter: FilterSet(matchAll: filter.matchAll, conditions: filter.active)))
                    saved.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                    FilterStore.save(saved, key: storageKey)
                }
                .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty || !filter.isActive)
            }
            Text("Amount tests look at the size of the number, so “is at least 10,000” finds debits and credits of 10,000 or more. Use “is a debit” or “is a credit” for the sign.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 640)
        .onAppear {
            saved = FilterStore.load(storageKey)
            if filter.conditions.isEmpty { filter.conditions.append(FilterCondition(column: columns.first?.title ?? "")) }
        }
    }
}
