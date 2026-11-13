import SwiftUI
import TBCore

/// Shown wherever accounts are grouped while any account's type disagrees with its grouping's.
struct TypeConflictBanner: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let e = model.engagement {
            let conflicts = e.typeConflicts
            if !conflicts.isEmpty {
                let n = conflicts.map(\.mismatched.count).reduce(0, +)
                HStack(spacing: 10) {
                    Label("\(n) account\(n == 1 ? " has" : "s have") a type that differs from \(n == 1 ? "its" : "their") grouping's — \(conflicts.prefix(3).map { e.groupingCode($0.groupingID) }.joined(separator: ", "))\(conflicts.count > 3 ? "…" : "").",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Review Account Types…") { model.showTypeReview() }
                    Spacer()
                }
                .font(.system(size: 12))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.orange.opacity(0.08))
                Divider()
            }
        }
    }
}

/// Settles account types that disagree with their grouping, one grouping at a time: choose the
/// type for the grouping and everything in it, or take an account out of the grouping.
struct TypeConflictReview: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.closeWindow) private var closeWindow
    @State private var resolutions: [String: GroupingTypeResolution] = [:]

    private func resolution(_ c: GroupingTypeConflict) -> GroupingTypeResolution {
        resolutions[c.groupingID] ?? GroupingTypeResolution(type: c.groupingType)
    }

    var body: some View {
        let e = model.engagement ?? Engagement(name: "", periodEnd: "")
        let conflicts = e.typeConflicts
        let changing = conflicts.map { c in c.accounts.filter { $0.type != resolution(c).type && !resolution(c).ungroup.contains($0.id) }.count }.reduce(0, +)
        let leaving = conflicts.map { resolution($0).ungroup.count }.reduce(0, +)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(conflicts.isEmpty ? "Every account matches its grouping"
                                       : "\(conflicts.count) grouping\(conflicts.count == 1 ? " holds" : "s hold") accounts of another type")
                    .font(.title3.bold())
                Text("Each grouping says what kind of account belongs in it: L01 · CASH is for assets. For each grouping below, choose the one type it and all of its accounts should have. If an account simply doesn't belong there, take it out of the grouping instead. Account types decide what counts as income, so they are worth getting right.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Divider()
            if conflicts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 34)).foregroundStyle(.green)
                    Text("Nothing to settle.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(conflicts) { c in
                            card(c, e)
                            Divider()
                        }
                    }
                }
            }
            Divider()
            HStack(spacing: 14) {
                if !conflicts.isEmpty {
                    Text("\(changing) account\(changing == 1 ? "" : "s") will change type\(leaving > 0 ? " · \(leaving) will leave \(leaving == 1 ? "its" : "their") grouping" : ""). You can undo this.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(conflicts.isEmpty ? "Done" : "Cancel") { closeWindow() }
                    .keyboardShortcut(.cancelAction)
                if !conflicts.isEmpty {
                    Button("Apply") {
                        var all: [String: GroupingTypeResolution] = [:]
                        for c in conflicts { all[c.groupingID] = resolution(c) }
                        var n = 0
                        if model.mutate("Settle Account Types", { n = $0.resolveTypeConflicts(all) }) {
                            model.status = "\(n) account\(n == 1 ? "" : "s") changed type to match \(n == 1 ? "its" : "their") grouping"
                            closeWindow()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .font(.callout)
            .padding(14)
        }
        .frame(minWidth: 760, minHeight: 420)
    }

    private func card(_ c: GroupingTypeConflict, _ e: Engagement) -> some View {
        let r = resolution(c)
        let tally = Dictionary(grouping: c.accounts, by: \.type).map { ($0.key, $0.value.count) }
            .sorted { AccountType.allCases.firstIndex(of: $0.0)! < AccountType.allCases.firstIndex(of: $1.0)! }
        // What the choice does to each account: the ones that end up changed, or leave.
        let affected = c.accounts.filter { $0.type != r.type || r.ungroup.contains($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.groupingLabel(c.groupingID)).font(.system(size: 13.5, weight: .semibold))
                    Text("Set for \(c.groupingType.label.lowercased()) accounts · holds " + tally.map { "\($0.1) \($0.0.label.lowercased())" }.joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("This grouping and its accounts are")
                Picker("", selection: Binding(get: { r.type }, set: { new in
                    var x = r
                    x.type = new
                    resolutions[c.groupingID] = x
                })) {
                    ForEach(AccountType.allCases, id: \.self) { type in
                        Text(type == c.groupingType ? "\(type.label) (as the grouping is set)" : type.label).tag(type)
                    }
                }
                .labelsHidden()
                .frame(width: 250)
            }
            VStack(spacing: 0) {
                ForEach(Array(affected.enumerated()), id: \.element.id) { index, a in
                    let out = r.ungroup.contains(a.id)
                    if index > 0 { Divider() }
                    HStack(spacing: 10) {
                        Text(a.number.isEmpty ? "—" : a.number).monospacedDigit().frame(width: 70, alignment: .leading)
                        Text(a.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        if let sub = e.grouping(a.grouping), sub.parent != nil {
                            Text("in \(sub.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text(model.ledger?.consolidated(.book, account: a.id).formatted ?? "").monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 120, alignment: .trailing)
                        Group {
                            if out {
                                Text("Stays \(a.type.label.lowercased()), not grouped").foregroundStyle(.orange)
                            } else {
                                Text("\(a.type.label) → \(r.type.label)").fontWeight(.medium)
                            }
                        }
                        .frame(width: 200, alignment: .leading)
                        Toggle("Take out of the grouping", isOn: Binding(get: { out }, set: { on in
                            var x = r
                            if on { x.ungroup.insert(a.id) } else { x.ungroup.remove(a.id) }
                            resolutions[c.groupingID] = x
                        }))
                        .toggleStyle(.checkbox)
                        .fixedSize()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
            }
            .font(.system(size: 12.5))
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035)))
            if r.type != c.groupingType {
                Label("The grouping itself becomes \(r.type.label.lowercased()), along with all \(c.accounts.count) of its accounts.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
