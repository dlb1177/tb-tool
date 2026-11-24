import SwiftUI
import TBCore

/// Every change made to the file, newest first: what was done, what it changed, who did it, on
/// which Mac, and when. Lines are only ever added — undoing a change adds a line of its own.
struct ChangeLogView: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""

    var body: some View {
        if let e = model.engagement {
            let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            let entries = Array(e.auditLog.enumerated()).reversed().filter { _, a in
                guard !terms.isEmpty else { return true }
                let text = ([a.action, a.actor.name, a.actor.account, a.actor.computer, Stamp.local(a.at)] + a.details).joined(separator: " ").lowercased()
                return terms.allSatisfy { text.contains($0) }
            }
            VStack(spacing: 0) {
                PageHeader(title: "Change Log", subtitle: subtitle(e, shown: entries.count)) {
                    SearchBox(prompt: "Search the log", text: $query)
                        .frame(width: 240)
                    Menu {
                        ForEach(AppModel.ExportFormat.allCases, id: \.self) { format in
                            Button("Change Log as \(format.label)…") {
                                if let ledger = model.ledger { model.export(Reports(ledger: ledger).changeLog(), as: format) }
                            }
                        }
                        Divider()
                        ForEach(AppModel.ExportFormat.allCases, id: \.self) { format in
                            Button("Workpaper Sign-offs as \(format.label)…") {
                                if let ledger = model.ledger { model.export(Reports(ledger: ledger).signOffs(), as: format) }
                            }
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .fixedSize()
                    .disabled(e.auditLog.isEmpty)
                }
                Divider()
                integrity(e)
                Divider()
                if e.auditLog.isEmpty {
                    EmptyState(title: "Nothing in the log yet",
                               message: "From here on, every change to this file is written down: what changed, who changed it, on which Mac, and when.")
                } else if entries.isEmpty {
                    EmptyState(title: "No lines match", message: "Nothing in the log has every word of “\(query)”.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(entries, id: \.offset) { n, entry in
                                row(entry, number: n + 1, broken: e.auditLogBreak.map { n >= $0 } ?? false)
                                Divider()
                            }
                        }
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
        }
    }

    private func subtitle(_ e: Engagement, shown: Int) -> String {
        let n = e.auditLog.count
        return "\(n) line\(n == 1 ? "" : "s")" + (shown != n ? " · \(shown) shown" : "") + " · signed in here as \(model.actor.display) on \(model.actor.computer)"
    }

    @ViewBuilder
    private func integrity(_ e: Engagement) -> some View {
        HStack(spacing: 8) {
            if let broken = e.auditLogBreak {
                Label("Line \(broken + 1) doesn't follow from the line before it: the log was edited outside TB Tool, or a line was removed or put in. Lines from there on are marked.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if !e.auditLog.isEmpty {
                Label("The log is unbroken: each line is sealed to the one before it, so a line that is edited, removed or put in afterwards shows.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.secondary)
            } else {
                Text(" ")
            }
            Spacer()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(e.auditLogBreak == nil ? Color.clear : Color.orange.opacity(0.08))
    }

    private func row(_ a: AuditEntry, number: Int, broken: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Stamp.local(a.at)).monospacedDigit()
                Text("#\(number)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(width: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(a.action).fontWeight(.semibold)
                    if broken {
                        Label("can't be relied on", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    }
                }
                ForEach(Array(a.details.enumerated()), id: \.offset) { _, line in
                    Text(line).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                Text(a.actor.display)
                Text(a.actor.computer).font(.caption).foregroundStyle(.secondary)
            }
            .help("Login \(a.actor.account) · \(a.actor.computer) · device \(a.actor.device)")
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}
