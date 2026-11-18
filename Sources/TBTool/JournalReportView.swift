import SwiftUI
import TBCore

/// The journal as it reads on paper: a heading for each kind of entry, and under it every entry
/// on its own — number, date and description across the top, the workpapers it refers to (click
/// one to open it), then its lines and its total. Exports are written from the same layout.
struct JournalReportView: View {
    @EnvironmentObject private var model: AppModel
    let ledger: Ledger
    /// Nil for every kind.
    let types: Set<JEType>?
    @State private var query = ""

    private enum W {
        static let entity: CGFloat = 150, account: CGFloat = 84, name: CGFloat = 280, money: CGFloat = 118
    }

    var body: some View {
        let e = ledger.engagement
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let entries = Reports(ledger: ledger).sortedEntries().filter { je in
            guard !je.pending, types.map({ $0.contains(je.type) }) ?? true else { return false }
            guard !terms.isEmpty else { return true }
            let text = ([je.number, je.description, je.date, Reports.printedDate(je.date), je.totalDebits.grouped] + je.references.map(\.path)
                        + je.lines.flatMap { l in [e.entity(l.entity)?.name ?? "", e.account(l.account)?.display ?? l.account, l.memo, l.amount.debit.grouped, l.amount.credit.grouped] })
                .joined(separator: " ").lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
        let kinds = JEType.allCases.filter { type in entries.contains { $0.type == type } }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find an entry — number, description, account, amount…", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                .frame(maxWidth: 360)
                Spacer()
                Text("\(entries.count) entr\(entries.count == 1 ? "y" : "ies")").foregroundStyle(.secondary).monospacedDigit()
                Text("Click a reference to open it · double-click an entry to edit it").foregroundStyle(.tertiary).lineLimit(1)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            columnTitles
            Divider()
            if entries.isEmpty {
                EmptyState(title: query.isEmpty ? "No journal entries" : "No entries match", message: query.isEmpty ? "Entries you post show up here, each set out on its own." : "Nothing has every word of “\(query)”.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(kinds, id: \.self) { type in
                            let mine = entries.filter { $0.type == type }
                            Text(Reports.journalTitle(type).title.uppercased())
                                .font(.system(size: 12, weight: .bold))
                                .kerning(0.6)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, 16)
                                .padding(.bottom, 8)
                            ForEach(mine) { je in
                                entry(je, e)
                                    .padding(.horizontal, 12)
                                    .padding(.bottom, 12)
                            }
                            totals("Total \(Reports.journalTitle(type).title.lowercased())", mine.map(\.totalDebits).sum(), mine.map(\.totalCredits).sum(), heavy: true)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 6)
                        }
                        if kinds.count > 1 {
                            totals("Total, all journal entries", entries.map(\.totalDebits).sum(), entries.map(\.totalCredits).sum(), heavy: true)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                        }
                    }
                    .padding(.bottom, 16)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    private var columnTitles: some View {
        HStack(spacing: 0) {
            Text("Trial Balance").frame(width: W.entity, alignment: .leading)
            Text("Account").frame(width: W.account, alignment: .leading)
            Text("Account Name").frame(width: W.name, alignment: .leading)
            Text("Debit").frame(width: W.money, alignment: .trailing)
            Text("Credit").frame(width: W.money, alignment: .trailing)
            Text("Memo").padding(.leading, 18)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 5)
    }

    private func entry(_ je: JournalEntry, _ e: Engagement) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Number, date and description: said once, above the lines.
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(je.number).font(.system(size: 13, weight: .bold)).monospacedDigit()
                    Text(Reports.printedDate(je.date)).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(.secondary)
                    Text(je.description.isEmpty ? "No description" : je.description)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(je.description.isEmpty ? Color.secondary : Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if je.rollForward != .none {
                        Text("Next year: \(je.rollForward.label.lowercased())").font(.caption).foregroundStyle(.secondary)
                            .help("Shown here only. It is left out of every export.")
                    }
                }
                ForEach(Array(je.references.enumerated()), id: \.offset) { _, ref in
                    let found = model.exists(ref)
                    HStack(spacing: 6) {
                        Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary)
                        Button(ref.path + (ref.location.isEmpty ? "" : "  ·  \(ref.location)")) { model.openReference(ref) }
                            .buttonStyle(.link)
                            .help(found ? "Open this workpaper" : "This file can't be found where the reference says")
                        if !ref.note.isEmpty { Text("— \(ref.note)").foregroundStyle(.secondary) }
                        if !found { Text("not found").foregroundStyle(.orange) }
                    }
                    .font(.system(size: 12))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.06))
            ForEach(Array(je.lines.enumerated()), id: \.offset) { n, l in
                let account = e.account(l.account)
                HStack(spacing: 0) {
                    Text(e.entity(l.entity)?.name ?? l.entity).frame(width: W.entity, alignment: .leading).lineLimit(1)
                    Text(account?.number ?? l.account).monospacedDigit().frame(width: W.account, alignment: .leading).lineLimit(1)
                    Text(account?.name ?? "").frame(width: W.name, alignment: .leading).lineLimit(1)
                    Text(l.amount.cents > 0 ? l.amount.debit.grouped : "").monospacedDigit().frame(width: W.money, alignment: .trailing)
                    Text(l.amount.cents < 0 ? l.amount.credit.grouped : "").monospacedDigit().frame(width: W.money, alignment: .trailing)
                    Text(l.memo).foregroundStyle(.secondary).padding(.leading, 18).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12.5))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(n % 2 == 1 ? Color.primary.opacity(0.02) : Color.clear)
            }
            totals("Total \(je.number)", je.totalDebits, je.totalCredits, heavy: false)
        }
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.14)))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if model.engagement?.entry(je.id) != nil { model.editEntry(je.id) } }
        .contextMenu {
            Button("Edit \(je.number)…") { model.editEntry(je.id) }
                .disabled(model.engagement?.entry(je.id) == nil)
        }
    }

    private func totals(_ label: String, _ debits: Money, _ credits: Money, heavy: Bool) -> some View {
        HStack(spacing: 0) {
            Text(label).frame(width: W.entity + W.account + W.name, alignment: .trailing)
            ForEach([debits, credits], id: \.self) { amount in
                Text(amount.grouped).monospacedDigit()
                    .frame(width: W.money - 10, alignment: .trailing)
                    .padding(.top, 3)
                    .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(heavy ? 0.7 : 0.35)).frame(height: heavy ? 1.5 : 1) }
                    .padding(.leading, 10)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5, weight: .semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}
