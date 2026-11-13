import SwiftUI
import TBCore

/// The second step of an import, shown only when the file names an account differently from the
/// chart: for each one, which name stands (or whether it is a different account), what happens to
/// its grouping, and what the chart will hold afterwards.
struct NameConflictReview: View {
    let engagement: Engagement
    let conflicts: [AccountNameConflict]
    @Binding var resolutions: [String: AccountNameResolution]
    let sourceName: String
    let importLabel: String
    let onBack: () -> Void
    let onCancel: () -> Void
    let onImport: () -> Void

    private enum Kind: Hashable { case chart, file, separate }

    private func resolution(_ c: AccountNameConflict) -> AccountNameResolution { resolutions[c.accountID] ?? AccountNameResolution() }

    private func kind(_ c: AccountNameConflict) -> Kind {
        switch resolution(c).choice {
        case .keepChartName: return .chart
        case .useFileName: return .file
        case .separateAccount: return .separate
        }
    }

    private func setKind(_ kind: Kind, for c: AccountNameConflict) {
        var r = resolution(c)
        switch kind {
        case .chart: r.choice = .keepChartName
        case .file: r.choice = .useFileName
        case .separate:
            if case .separateAccount = r.choice { break }
            r.choice = .separateAccount(number: engagement.suggestedSeparateNumber(for: c.number))
        }
        resolutions[c.accountID] = r
    }

    var body: some View {
        let outcomes = conflicts.map { engagement.outcome(of: resolution($0), for: $0) }
        let problems = outcomes.compactMap(\.problem)
        let n = conflicts.count
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(n) account\(n == 1 ? " is" : "s are") named differently in this file").font(.title3.bold())
                Text("\(sourceName) uses \(n == 1 ? "a number" : "numbers") the chart of accounts already has, under \(n == 1 ? "a different name" : "different names"). For each, choose which name is right — or, if it is really a different account, bring it in under its own number. The last column shows what the chart will hold after the import. Nothing changes until you click Import.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Divider()
            HStack(spacing: 10) {
                Text("For all \(n):").foregroundStyle(.secondary)
                Button("Keep the Chart's Names") { conflicts.forEach { setKind(.chart, for: $0) } }
                Button("Use This File's Names") { conflicts.forEach { setKind(.file, for: $0) } }
                if conflicts.contains(where: { $0.grouping != nil }) {
                    Divider().frame(height: 16)
                    Button("Keep Every Grouping") { setKeepGrouping(true) }
                    Button("Clear Every Grouping") { setKeepGrouping(false) }
                        .help("The accounts go back to ungrouped, so each is looked at again on the Accounts screen")
                }
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            Divider()
            titles
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(conflicts.enumerated()), id: \.element.id) { index, c in
                        row(c, outcome: outcomes[index], shaded: index.isMultiple(of: 2))
                        Divider()
                    }
                }
            }
            Divider()
            HStack(spacing: 14) {
                if let first = problems.first {
                    Label(problems.count == 1 ? first : "\(problems.count) accounts need another number", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Text(summary).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Back to the Layout", action: onBack)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(importLabel, action: onImport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!problems.isEmpty)
            }
            .font(.callout)
            .padding(14)
        }
    }

    private func setKeepGrouping(_ keep: Bool) {
        for c in conflicts where c.grouping != nil {
            var r = resolution(c)
            r.keepGrouping = keep
            resolutions[c.accountID] = r
        }
    }

    private var summary: String {
        let kinds = conflicts.map(kind)
        var parts: [String] = []
        let chart = kinds.filter { $0 == .chart }.count, file = kinds.filter { $0 == .file }.count, separate = kinds.filter { $0 == .separate }.count
        if chart > 0 { parts.append("\(chart) keep\(chart == 1 ? "s" : "") the chart's name") }
        if file > 0 { parts.append("\(file) renamed to this file's name") }
        if separate > 0 { parts.append("\(separate) added as \(separate == 1 ? "a separate account" : "separate accounts")") }
        return parts.joined(separator: " · ")
    }

    // Column widths shared by the titles and the rows.
    private let numberWidth: CGFloat = 76, keepWidth: CGFloat = 250, groupingWidth: CGFloat = 230

    private var titles: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("Account").frame(width: numberWidth, alignment: .leading)
            Text("In the chart now").frame(maxWidth: .infinity, alignment: .leading)
            Text("In this file").frame(maxWidth: .infinity, alignment: .leading)
            Text("Keep").frame(width: keepWidth, alignment: .leading)
            Text("Grouping").frame(width: groupingWidth, alignment: .leading)
            Text("After the import").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func row(_ c: AccountNameConflict, outcome: AccountNameOutcome, shaded: Bool) -> some View {
        let r = resolution(c)
        let k = kind(c)
        let label = engagement.groupingLabel(c.grouping)
        return HStack(alignment: .top, spacing: 12) {
            Text(c.number).monospacedDigit().fontWeight(.medium).frame(width: numberWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.chartName).fontWeight(k == .chart ? .semibold : .regular)
                Text(c.usedBy.isEmpty ? "Not used by any trial balance yet" : "Used by \(c.usedBy.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.fileName).fontWeight(k == .chart ? .regular : .semibold)
                Text(c.amount.formatted).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Picker("", selection: Binding(get: { k }, set: { setKind($0, for: c) })) {
                    Text("The chart's name").tag(Kind.chart)
                    Text("This file's name").tag(Kind.file)
                    Text("Both — it's a different account").tag(Kind.separate)
                }
                .labelsHidden()
                .frame(width: keepWidth - 10)
                if case .separateAccount(let number) = r.choice {
                    HStack(spacing: 6) {
                        Text("as number").font(.caption).foregroundStyle(.secondary)
                        TextField("none — keep by name", text: Binding(get: { number }, set: { new in
                            var x = r
                            x.choice = .separateAccount(number: new)
                            resolutions[c.accountID] = x
                        }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    }
                } else if k == .file && c.usedBy.count > 1 {
                    Text("Renames it for every trial balance").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: keepWidth, alignment: .leading)
            Group {
                if c.grouping != nil {
                    Toggle(isOn: Binding(get: { r.keepGrouping }, set: { new in
                        var x = r
                        x.keepGrouping = new
                        resolutions[c.accountID] = x
                    })) {
                        Text(k == .separate ? "Give it \(label) too" : "Keep \(label)").lineLimit(2)
                    }
                    .toggleStyle(.checkbox)
                    .help(k == .separate ? "Start the new account in the same grouping as \(c.number). Unticked, it starts ungrouped."
                                         : "Unticked, the account goes back to ungrouped so you can group it again.")
                } else {
                    Text("Not grouped yet").foregroundStyle(.secondary)
                }
            }
            .frame(width: groupingWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                if let problem = outcome.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 5) {
                        if outcome.isNew { Text("NEW").font(.caption2.weight(.bold)).foregroundStyle(.green) }
                        Text("\(outcome.number) \(outcome.name)".trimmingCharacters(in: .whitespaces)).fontWeight(.medium)
                    }
                    Text(outcome.grouping == nil ? "Not grouped" : engagement.groupingLabel(outcome.grouping))
                        .font(.caption)
                        .foregroundStyle(outcome.grouping == nil ? Color.orange : Color.secondary)
                    if k == .separate {
                        Text("\(c.number) \(c.chartName) stays as it is").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(shaded ? Color.primary.opacity(0.025) : Color.clear)
    }
}
