import AppKit
import SwiftUI
import TBCore
import UniformTypeIdentifiers

/// The journal as it reads on paper: a heading for each kind of entry, and under it every entry
/// on its own — number, date and description across the top, the workpapers it refers to (click
/// one to open it), then its lines and its total. The Journal Entries screen and the Journal
/// Entries report are both this; the screen adds selecting, and dragging to reorder.
struct JournalCards: View {
    @EnvironmentObject private var model: AppModel
    let e: Engagement
    /// Already filtered, in the order to show.
    let entries: [JournalEntry]
    var emptyTitle = "No journal entries"
    var emptyMessage = "Entries you post show up here, each set out on its own."
    /// With a selection, entries can be selected: a click, ⌘-click, ⇧-click.
    var selection: Binding<Set<String>>? = nil
    /// With this, entries can be dragged to a new place among those of their kind: the ids
    /// being moved, the entry they were let go on, and whether below it.
    var reorder: ((Set<String>, String, Bool) -> Void)? = nil
    /// What a right-click on an entry (or on the selection it is part of) offers.
    var menu: ((Set<String>) -> AnyView)? = nil

    @State private var anchor: String?
    @State private var hover: CardHover?
    @State private var heights: [String: CGFloat] = [:]

    private enum W {
        static let entity: CGFloat = 150, account: CGFloat = 84, name: CGFloat = 280, money: CGFloat = 118
    }

    var body: some View {
        let kinds = JEType.allCases.filter { type in entries.contains { $0.type == type } }
        VStack(spacing: 0) {
            columnTitles
            Divider()
            if entries.isEmpty {
                EmptyState(title: emptyTitle, message: emptyMessage)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(kinds, id: \.self) { type in
                            let mine = entries.filter { $0.type == type }
                            let posted = mine.filter { !$0.pending }
                            Text(Reports.journalTitle(type).title.uppercased())
                                .font(.system(size: 12, weight: .bold))
                                .kerning(0.6)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, 16)
                                .padding(.bottom, 8)
                            ForEach(mine) { je in
                                card(je)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .overlay(alignment: .top) { dropLine(hover == CardHover(id: je.id, after: false)) }
                                    .overlay(alignment: .bottom) { dropLine(hover == CardHover(id: je.id, after: true)) }
                            }
                            totals("Total \(Reports.journalTitle(type).title.lowercased())", posted.map(\.totalDebits).sum(), posted.map(\.totalCredits).sum(), heavy: true)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                        if kinds.count > 1 {
                            let posted = entries.filter { !$0.pending }
                            totals("Total, all journal entries", posted.map(\.totalDebits).sum(), posted.map(\.totalCredits).sum(), heavy: true)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                        }
                    }
                    .padding(.bottom, 16)
                    .onPreferenceChange(CardHeights.self) { heights = $0 }
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }

    private func dropLine(_ on: Bool) -> some View {
        Rectangle().fill(Color.accentColor).frame(height: 3).padding(.horizontal, 12).opacity(on ? 1 : 0)
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

    /// A click selects; ⌘-click adds or removes one; ⇧-click takes everything from the last click to this one.
    private func clicked(_ je: JournalEntry) {
        guard let selection else { return }
        let flags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.wrappedValue.contains(je.id) { selection.wrappedValue.remove(je.id) } else { selection.wrappedValue.insert(je.id) }
            anchor = je.id
        } else if flags.contains(.shift), let from = anchor, let a = entries.firstIndex(where: { $0.id == from }), let b = entries.firstIndex(where: { $0.id == je.id }) {
            selection.wrappedValue = Set(entries[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection.wrappedValue = [je.id]
            anchor = je.id
        }
    }

    @ViewBuilder
    private func card(_ je: JournalEntry) -> some View {
        let selected = selection?.wrappedValue.contains(je.id) ?? false
        let body = VStack(alignment: .leading, spacing: 0) {
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
                    if je.pending {
                        Label("Waiting for amounts", systemImage: "hourglass").font(.caption).foregroundStyle(.orange)
                            .help("Rolled forward without amounts. Open it and fill them in; until then it posts nothing.")
                    }
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
            .background(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
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
            if !je.pending { totals("Total \(je.number)", je.totalDebits, je.totalCredits, heavy: false) }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.14), lineWidth: selected ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .background(GeometryReader { geo in Color.clear.preference(key: CardHeights.self, value: [je.id: geo.size.height]) })
        .gesture(TapGesture().onEnded { clicked(je) })
        .simultaneousGesture(TapGesture(count: 2).onEnded { if model.engagement?.entry(je.id) != nil { model.editEntry(je.id) } })
        .contextMenu {
            if let menu {
                let ids = selection?.wrappedValue ?? []
                menu(ids.contains(je.id) && ids.count > 1 ? ids : [je.id])
            } else {
                Button("Edit \(je.number)…") { model.editEntry(je.id) }
                    .disabled(model.engagement?.entry(je.id) == nil)
            }
        }
        if let reorder {
            body
                .onDrag {
                    if let selection, !selection.wrappedValue.contains(je.id) { selection.wrappedValue = [je.id] }
                    return NSItemProvider(object: je.id as NSString)
                }
                .onDrop(of: [.plainText], delegate: CardDrop(id: je.id, height: heights[je.id] ?? 80, hover: $hover) { dragged, after in
                    // Dragging one of several selected entries moves them all.
                    let picked = selection?.wrappedValue ?? []
                    reorder(picked.contains(dragged) ? picked : [dragged], je.id, after)
                })
        } else {
            body
        }
    }

    private func totals(_ label: String, _ debits: Money, _ credits: Money, heavy: Bool) -> some View {
        HStack(spacing: 0) {
            Text(label).frame(width: W.entity + W.account + W.name, alignment: .trailing)
            ForEach(Array([debits, credits].enumerated()), id: \.offset) { _, amount in
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

/// Where a dragged entry is hovering: over which entry, and in its top or bottom half.
struct CardHover: Equatable {
    var id: String
    var after: Bool
}

struct CardHeights: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// An entry let go on the top half of another goes above it; on the bottom half, below.
private struct CardDrop: DropDelegate {
    let id: String
    let height: CGFloat
    @Binding var hover: CardHover?
    let perform: (String, Bool) -> Void

    private func place(_ info: DropInfo) -> CardHover { CardHover(id: id, after: info.location.y > height / 2) }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }

    func dropEntered(info: DropInfo) { hover = place(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let p = place(info)
        if hover != p { hover = p }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if hover?.id == id { hover = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let after = place(info).after
        hover = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { text, _ in
            guard let dragged = text as? String else { return }
            DispatchQueue.main.async { perform(dragged, after) }
        }
        return true
    }
}

/// The Journal Entries report: the journal set out entry by entry, with a search box. Entries
/// still waiting for amounts post nothing and are left out, as they are from the exports.
struct JournalReportView: View {
    let ledger: Ledger
    /// Nil for every kind.
    let types: Set<JEType>?
    @State private var query = ""

    /// Whether an entry has every word typed, anywhere in it.
    static func matches(_ je: JournalEntry, _ terms: [String], in e: Engagement) -> Bool {
        guard !terms.isEmpty else { return true }
        let text = ([je.number, je.type.label, je.description, je.date, Reports.printedDate(je.date), je.totalDebits.grouped, je.pending ? "waiting needs amounts" : "posted"]
                    + je.references.map(\.path)
                    + je.lines.flatMap { l in [e.entity(l.entity)?.name ?? "", e.account(l.account)?.display ?? l.account, l.memo, l.amount.debit.grouped, l.amount.credit.grouped] })
            .joined(separator: " ").lowercased()
        return terms.allSatisfy { text.contains($0) }
    }

    var body: some View {
        let e = ledger.engagement
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let entries = Reports(ledger: ledger).sortedEntries().filter { je in
            !je.pending && (types.map { $0.contains(je.type) } ?? true) && JournalReportView.matches(je, terms, in: e)
        }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SearchBox(prompt: "Find an entry — number, description, account, amount…", text: $query)
                    .frame(maxWidth: 360)
                Spacer()
                Text("\(entries.count) entr\(entries.count == 1 ? "y" : "ies")").foregroundStyle(.secondary).monospacedDigit()
                Text("Click a reference to open it · double-click an entry to edit it").foregroundStyle(.tertiary).lineLimit(1)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            JournalCards(e: e, entries: entries, emptyTitle: query.isEmpty ? "No journal entries" : "No entries match",
                         emptyMessage: query.isEmpty ? "Entries you post show up here, each set out on its own." : "Nothing has every word of “\(query)”.")
        }
    }
}
