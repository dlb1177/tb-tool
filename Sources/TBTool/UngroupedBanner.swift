import SwiftUI
import TBCore

/// Shown while any account has no grouping: they sit outside every tax line until they are given one.
struct UngroupedBanner: View {
    @EnvironmentObject private var model: AppModel
    /// On the Accounts screen itself the button filters the list in place.
    var show: (() -> Void)? = nil

    var body: some View {
        if let e = model.engagement {
            let ungrouped = e.ungroupedAccounts
            if !ungrouped.isEmpty {
                let n = ungrouped.count
                HStack(spacing: 10) {
                    Label("\(n) account\(n == 1 ? " isn't" : "s aren't") grouped — \(ungrouped.prefix(3).map(\.display).joined(separator: ", "))\(n > 3 ? "…" : "").",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                    Button(show == nil ? "Show Ungrouped Accounts" : "Show Them") {
                        if let show { show() } else { model.showUngroupedAccounts() }
                    }
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
