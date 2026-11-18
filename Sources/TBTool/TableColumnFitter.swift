import AppKit
import SwiftUI

/// For the screens built on SwiftUI's own table (Accounts, Grouping List, Journal Entries):
/// each column starts at the narrowest width that shows its heading and everything in it, and
/// a column that is resized by hand keeps that width from then on, per screen.
///
/// SwiftUI's table offers neither, so this finds the table view behind it and sets the widths
/// there. Put it behind the table with `.background`.
struct TableColumnFitter: NSViewRepresentable {
    /// Where the hand-set widths are kept.
    let key: String
    /// What each column shows, by its heading: the texts to make room for.
    let contents: [String: [String]]
    /// Extra room a column needs beyond its text (an icon, a menu arrow, an indent).
    var extra: [String: CGFloat] = [:]

    func makeNSView(context: Context) -> FitterView { FitterView() }

    func updateNSView(_ view: FitterView, context: Context) {
        view.key = key
        view.contents = contents
        view.extra = extra
        view.schedule()
    }

    final class FitterView: NSView {
        var key = ""
        var contents: [String: [String]] = [:]
        var extra: [String: CGFloat] = [:]
        private weak var table: NSTableView?
        /// Widths this set itself. A column at another width was resized by hand, or by the table.
        private var auto: [String: CGFloat] = [:]
        private var applying = false
        private var tries = 0
        private var pending = false

        private var saved: [String: Double] {
            get { UserDefaults.standard.dictionary(forKey: "TBTableWidths.\(key)") as? [String: Double] ?? [:] }
            set { UserDefaults.standard.set(newValue, forKey: "TBTableWidths.\(key)") }
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            schedule()
        }

        func schedule() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                self?.pending = false
                self?.fit()
            }
        }

        /// The table nearest this view: the first one found under the closest ancestor that has one.
        private func find() -> NSTableView? {
            func search(_ view: NSView) -> NSTableView? {
                if let t = view as? NSTableView { return t }
                for sub in view.subviews {
                    if let t = search(sub) { return t }
                }
                return nil
            }
            var up = superview
            while let v = up {
                if let t = search(v) { return t }
                up = v.superview
            }
            return nil
        }

        private func fit() {
            guard window != nil else { return }
            guard let tv = table ?? find() else {
                // The table is made a moment after this view is.
                tries += 1
                if tries < 20 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.fit() } }
                return
            }
            if table !== tv {
                table = tv
                // Columns keep their widths when the window is resized, instead of sharing out the room.
                tv.columnAutoresizingStyle = .noColumnAutoresizing
                NotificationCenter.default.removeObserver(self)
                NotificationCenter.default.addObserver(self, selector: #selector(resized(_:)), name: NSTableView.columnDidResizeNotification, object: tv)
            }
            let kept = saved
            applying = true
            defer { applying = false }
            for col in tv.tableColumns {
                let title = col.title
                var want: CGFloat?
                if let w = kept[title] {
                    want = CGFloat(w)
                } else if let texts = contents[title] {
                    // An automatic column follows its content, but only while it is still at the width set here.
                    if let mine = auto[title], abs(col.width - mine) > 0.5, tv.headerView?.resizedColumn ?? -1 >= 0 { continue }
                    let fit = Self.width(title: title, texts: texts) + (extra[title] ?? 0)
                    auto[title] = fit
                    want = fit
                }
                guard let want, abs(col.width - want) > 0.5 else { continue }
                col.minWidth = min(col.minWidth, want)
                col.maxWidth = max(col.maxWidth, want)
                col.width = want
            }
        }

        static func width(title: String, texts: [String]) -> CGFloat {
            let body = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            var widest = ceil((title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width) + 30
            // Length picks the candidates; the few longest are measured for real.
            for s in texts.sorted(by: { $0.count > $1.count }).prefix(5) {
                widest = max(widest, ceil((s as NSString).size(withAttributes: [.font: body]).width) + 22)
            }
            return min(widest, 640)
        }

        /// A width set by dragging a column's edge is kept; anything else that changes a width isn't.
        @objc private func resized(_ notification: Notification) {
            guard !applying, let tv = table, tv.headerView?.resizedColumn ?? -1 >= 0,
                  let col = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
            var kept = saved
            kept[col.title] = Double(col.width)
            saved = kept
            auto[col.title] = nil
        }
    }
}
