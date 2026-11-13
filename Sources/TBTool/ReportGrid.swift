import AppKit
import SwiftUI
import TBCore

struct GridSort: Equatable {
    var column: Int
    var ascending: Bool
}

/// One switch for the whole app: every trial balance and report screen hides or shows rows whose
/// amounts are all zero together, and the workbook export follows it.
struct HideZeroToggle: View {
    @AppStorage(HideZeroToggle.key) private var hideZero = true
    static let key = "view.hideZero"

    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    var body: some View {
        Toggle("Hide zero rows", isOn: $hideZero)
            .toggleStyle(.switch)
            .controlSize(.small)
            .fixedSize()
            .help("Hide rows whose amounts are all zero. One switch for every trial balance and report (View ▸ Hide Zero Balance Rows, ⇧⌘0).")
    }
}

/// A report on screen: a filter box and row count over a native table with resizable,
/// reorderable, sortable columns, and the totals pinned under it. Column widths, order and hidden
/// columns are remembered per `key`.
struct GridPanel: View {
    let table: ReportTable
    let key: String
    var onActivate: ((ReportRow) -> Void)? = nil

    @State private var query = ""
    @State private var filters = FilterSet()
    @State private var sort: GridSort?

    private var shown: ReportTable {
        var t = table.filtered(query, filters: filters)
        if let sort, sort.column < t.columns.count { t = t.sorted(by: sort.column, ascending: sort.ascending) }
        return t
    }

    private var filterColumns: [FilterColumn] {
        var out = table.columns.map { FilterColumn(title: $0.title, isAmount: $0.kind == .money) }
        // Any table of accounts can be filtered by account type, shown as a column or not.
        if table.rows.contains(where: { $0.accountType != nil }) && !out.contains(where: { $0.title == FilterCondition.accountTypeColumn }) {
            out.append(.accountType)
        }
        return out
    }

    var body: some View {
        let t = shown
        let total = table.rows.filter { $0.style == .normal }.count
        let visible = t.rows.filter { $0.style == .normal }.count
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                    TextField("Filter rows — account, name, grouping, amount…", text: $query)
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
                .frame(maxWidth: 320)
                FilterButton(filter: $filters, columns: filterColumns, storageKey: key)
                if let sort, sort.column < table.columns.count {
                    Button {
                        self.sort = nil
                    } label: {
                        Label("Sorted by \(table.columns[sort.column].title) \(sort.ascending ? "↑" : "↓")", systemImage: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .help("Back to chart order")
                }
                Spacer()
                Text(query.isEmpty && !filters.isActive ? "\(total) rows" : "\(visible) of \(total) rows")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text("Click a heading to sort · drag to reorder or resize · right-click for columns")
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            DataGrid(table: t, key: key, sort: $sort, onActivate: onActivate)
        }
        .onChange(of: table.columns) { _, new in
            if let s = sort, s.column >= new.count { sort = nil }
        }
    }
}

// MARK: - Remembered column layout

/// What a person did to a grid's columns: the order they dragged them into, the widths they set,
/// and the ones they hid. Kept per grid in the app's preferences, so it is still there after
/// switching screens or quitting. Columns never touched stay automatic (sized to their content).
struct GridLayout: Codable, Equatable {
    var order: [String] = []
    var widths: [String: Double] = [:]
    var hidden: [String] = []

    static func load(_ key: String) -> GridLayout {
        guard let data = UserDefaults.standard.data(forKey: "TBGridLayout.\(key)"),
              let layout = try? JSONDecoder().decode(GridLayout.self, from: data) else { return GridLayout() }
        return layout
    }

    func save(_ key: String) {
        if self == GridLayout() {
            UserDefaults.standard.removeObject(forKey: "TBGridLayout.\(key)")
        } else if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "TBGridLayout.\(key)")
        }
    }

    /// `primary` in its own order, with each item of `secondary` it lacks slotted in after the
    /// item that precedes it in `secondary`. Used both ways: to place columns the saved order has
    /// never seen, and to keep the saved place of columns that aren't on screen right now.
    static func merge(_ primary: [String], _ secondary: [String]) -> [String] {
        var out = primary
        var have = Set(primary)
        for (i, item) in secondary.enumerated() where !have.contains(item) {
            if let before = secondary[..<i].last(where: { have.contains($0) }), let at = out.firstIndex(of: before) {
                out.insert(item, at: at + 1)
            } else {
                out.insert(item, at: 0)
            }
            have.insert(item)
        }
        return out
    }
}

// MARK: - Native table

struct DataGrid: NSViewRepresentable {
    var table: ReportTable
    var key: String
    @Binding var sort: GridSort?
    var onActivate: ((ReportRow) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> GridContainerView {
        let tv = GridTableView()
        tv.style = .fullWidth
        tv.usesAlternatingRowBackgroundColors = true
        tv.allowsMultipleSelection = true
        tv.allowsColumnReordering = true
        tv.allowsColumnResizing = true
        tv.allowsColumnSelection = false
        tv.columnAutoresizingStyle = .noColumnAutoresizing
        tv.autosaveTableColumns = false
        tv.rowHeight = GridMetrics.rowHeight
        tv.intercellSpacing = NSSize(width: 0, height: 0)
        tv.gridStyleMask = [.solidVerticalGridLineMask]
        tv.gridColor = GridMetrics.gridColor
        tv.delegate = context.coordinator
        tv.dataSource = context.coordinator
        tv.target = context.coordinator
        tv.doubleAction = #selector(Coordinator.doubleClicked(_:))
        tv.copyHandler = { [weak coordinator = context.coordinator] in coordinator?.copySelection() }

        let rowMenu = NSMenu()
        rowMenu.addItem(withTitle: "Copy", action: #selector(GridTableView.copy(_:)), keyEquivalent: "c")
        rowMenu.addItem(withTitle: "Select All", action: #selector(NSTableView.selectAll(_:)), keyEquivalent: "a")
        tv.menu = rowMenu

        let headerMenu = NSMenu()
        headerMenu.delegate = context.coordinator
        tv.headerView?.menu = headerMenu

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = tv
        scroll.contentView.postsBoundsChangedNotifications = true

        let footer = GridFooterView()
        footer.tableView = tv
        footer.clipView = scroll.contentView
        footer.onActivate = { [weak coordinator = context.coordinator] row in coordinator?.parent.onActivate?(row) }

        let container = GridContainerView(scroll: scroll, footer: footer)
        context.coordinator.tableView = tv
        context.coordinator.footer = footer
        context.coordinator.container = container
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.scrolled(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        context.coordinator.apply()
        return container
    }

    func updateNSView(_ container: GridContainerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: DataGrid
        weak var tableView: GridTableView?
        weak var footer: GridFooterView?
        weak var container: GridContainerView?
        /// The rows that scroll, and the total lines pinned under them.
        private var rows: [ReportRow] = []
        private var pinned: [ReportRow] = []
        private var columns: [ReportColumn] = []
        private var identifiers: [String] = []
        private var shownTable: ReportTable?
        private var appliedKey = ""
        private var syncingSort = false
        private var layout = GridLayout()
        /// Widths this grid set itself, by column. A column whose width differs was resized by hand.
        private var autoWidths: [String: CGFloat] = [:]
        private var building = false

        init(_ parent: DataGrid) { self.parent = parent }

        deinit { NotificationCenter.default.removeObserver(self) }

        func apply() {
            guard let tv = tableView else { return }
            let t = parent.table
            var changed = shownTable != t
            let old = shownTable.map { GridMetrics.split($0.rows).body } ?? []
            let selectedIDs = Set(tv.selectedRowIndexes.compactMap { $0 < old.count ? old[$0].id : nil })
            if changed { (rows, pinned) = GridMetrics.split(t.rows) }
            if t.columns.map(\.title) != columns.map(\.title) || t.columns.map(\.kind) != columns.map(\.kind) || parent.key != appliedKey {
                rebuildColumns(t.columns)
                changed = true
            } else if changed {
                growAutomaticColumns()
            }
            let desired = parent.sort.flatMap { s in s.column < identifiers.count ? [NSSortDescriptor(key: identifiers[s.column], ascending: s.ascending)] : nil } ?? []
            if tv.sortDescriptors != desired {
                syncingSort = true
                tv.sortDescriptors = desired
                syncingSort = false
            }
            guard changed else { return }
            shownTable = t
            tv.reloadData()
            let reselect = IndexSet(rows.indices.filter { selectedIDs.contains(rows[$0].id) })
            if !reselect.isEmpty { tv.selectRowIndexes(reselect, byExtendingSelection: false) }
            footer?.show(rows: pinned, columns: columns, identifiers: identifiers)
            container?.needsLayout = true
        }

        // MARK: Columns

        private func rebuildColumns(_ cols: [ReportColumn]) {
            guard let tv = tableView else { return }
            building = true
            defer { building = false }
            for c in tv.tableColumns { tv.removeTableColumn(c) }
            columns = cols
            identifiers = []
            appliedKey = parent.key
            layout = GridLayout.load(parent.key)
            autoWidths = [:]
            var used = Set<String>()
            var made: [String: NSTableColumn] = [:]
            for (i, c) in cols.enumerated() {
                var ident = c.title.isEmpty ? "col\(i)" : c.title
                while used.contains(ident) { ident += "·" }
                used.insert(ident)
                identifiers.append(ident)
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(ident))
                col.title = c.title
                col.minWidth = 36
                col.maxWidth = 2400
                col.resizingMask = .userResizingMask
                col.headerCell.alignment = c.kind == .money ? .right : .left
                col.headerToolTip = c.title
                col.sortDescriptorPrototype = NSSortDescriptor(key: ident, ascending: c.kind == .text)
                // A width set by hand wins; otherwise the narrowest width that shows everything in the column.
                if let saved = layout.widths[ident] {
                    col.width = CGFloat(saved)
                } else {
                    let fit = fitWidth(i, title: col)
                    autoWidths[ident] = fit
                    col.width = fit
                }
                col.isHidden = layout.hidden.contains(ident)
                made[ident] = col
            }
            // The order they were last dragged into; columns that order has never seen fall in beside their neighbours.
            let saved = layout.order.filter { used.contains($0) }
            for ident in GridLayout.merge(saved, identifiers) {
                if let col = made[ident] { tv.addTableColumn(col) }
            }
        }

        /// The narrowest width that shows the heading and every value in the column without cutting any off.
        private func fitWidth(_ index: Int, title column: NSTableColumn) -> CGFloat {
            let heading = ceil(column.headerCell.cellSize.width) + 14  // room for the sort arrow
            let content = GridMetrics.contentWidth(column: index, kind: columns[index].kind, rows: rows, pinned: pinned)
            return min(max(heading, content, 44), columns[index].kind == .money ? 400 : 560)
        }

        /// When the figures change (an import, an entry being typed), automatic columns widen to keep
        /// everything visible. They don't shrink again until the grid is rebuilt, so nothing jumps about.
        private func growAutomaticColumns() {
            guard let tv = tableView else { return }
            building = true
            defer { building = false }
            for col in tv.tableColumns {
                let ident = col.identifier.rawValue
                guard let auto = autoWidths[ident], abs(col.width - auto) < 0.5, let i = identifiers.firstIndex(of: ident) else { continue }
                let fit = fitWidth(i, title: col)
                if fit > col.width + 0.5 {
                    autoWidths[ident] = fit
                    col.width = fit
                }
            }
        }

        func tableViewColumnDidResize(_ notification: Notification) {
            footer?.needsDisplay = true
            guard !building, let col = notification.userInfo?["NSTableColumn"] as? NSTableColumn else { return }
            let ident = col.identifier.rawValue
            if let auto = autoWidths[ident], abs(col.width - auto) < 0.5 { return }
            autoWidths[ident] = nil
            layout.widths[ident] = Double(col.width)
            layout.save(parent.key)
        }

        func tableViewColumnDidMove(_ notification: Notification) {
            footer?.needsDisplay = true
            guard !building, let tv = tableView else { return }
            layout.order = GridLayout.merge(tv.tableColumns.map(\.identifier.rawValue), layout.order)
            layout.save(parent.key)
        }

        /// Double-clicking a column's edge fits it to its content.
        func tableView(_ tableView: NSTableView, sizeToFitWidthOfColumn column: Int) -> CGFloat {
            guard column >= 0, column < tableView.tableColumns.count else { return 100 }
            let col = tableView.tableColumns[column]
            guard let i = identifiers.firstIndex(of: col.identifier.rawValue) else { return col.width }
            return fitWidth(i, title: col)
        }

        @objc func scrolled(_ notification: Notification) { footer?.needsDisplay = true }

        // MARK: Data

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let ci = identifiers.firstIndex(of: tableColumn.identifier.rawValue), row < rows.count else { return nil }
            let r = rows[row]
            let isMoney = columns[ci].kind == .money
            let reuse = NSUserInterfaceItemIdentifier(isMoney ? "money" : "text")
            let cell = (tableView.makeView(withIdentifier: reuse, owner: nil) as? GridCell) ?? GridCell(identifier: reuse, money: isMoney)
            let content: ReportCell = ci < r.cells.count ? r.cells[ci] : .empty
            cell.configure(content, emphasized: r.style != .normal)
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let v = GridRowView()
            v.style = row < rows.count ? rows[row].style : .normal
            return v
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !syncingSort else { return }
            var next: GridSort? = nil
            if let d = tableView.sortDescriptors.first, let key = d.key, let i = identifiers.firstIndex(of: key) {
                // A third click on the same heading returns to chart order.
                let first = columns[i].kind == .text
                if let old = oldDescriptors.first, old.key == key, old.ascending != first, d.ascending == first {
                    next = nil
                } else {
                    next = GridSort(column: i, ascending: d.ascending)
                }
            }
            DispatchQueue.main.async { self.parent.sort = next }
        }

        @objc func doubleClicked(_ sender: NSTableView) {
            let r = sender.clickedRow
            guard r >= 0, r < rows.count else { return }
            parent.onActivate?(rows[r])
        }

        /// Selected rows (or every row, totals included) as tab-separated text with the visible column headings.
        func copySelection() {
            guard let tv = tableView else { return }
            let all = tv.selectedRowIndexes.isEmpty
            let picked = all ? rows + pinned : tv.selectedRowIndexes.filter { $0 < rows.count }.map { rows[$0] }
            let order = tv.tableColumns.filter { !$0.isHidden }.compactMap { identifiers.firstIndex(of: $0.identifier.rawValue) }
            var lines = [order.map { columns[$0].title }.joined(separator: "\t")]
            for row in picked {
                lines.append(order.map { c -> String in
                    guard c < row.cells.count else { return "" }
                    switch row.cells[c] {
                    case .empty: return ""
                    case .text(let s): return s.replacingOccurrences(of: "\t", with: " ")
                    case .money(let m): return m.plain
                    }
                }.joined(separator: "\t"))
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n") + "\n", forType: .string)
        }

        // MARK: Column visibility (header right-click)

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tv = tableView else { return }
            for col in tv.tableColumns {
                let item = NSMenuItem(title: col.title.isEmpty ? "(untitled)" : col.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = col
                item.state = col.isHidden ? .off : .on
                menu.addItem(item)
            }
            menu.addItem(.separator())
            for (title, action) in [("Show All Columns", #selector(showAll)), ("Fit Column Widths to Content", #selector(resetWidths)),
                                    ("Reset Column Order", #selector(resetOrder))] {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }

        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let col = sender.representedObject as? NSTableColumn else { return }
            let visible = tableView?.tableColumns.filter { !$0.isHidden }.count ?? 0
            if !col.isHidden && visible <= 1 { return }
            col.isHidden.toggle()
            rememberHidden()
        }

        @objc private func showAll() {
            tableView?.tableColumns.forEach { $0.isHidden = false }
            rememberHidden()
        }

        private func rememberHidden() {
            guard let tv = tableView else { return }
            let here = Set(identifiers)
            // Keep what was hidden on columns that aren't on screen right now.
            layout.hidden = layout.hidden.filter { !here.contains($0) } + tv.tableColumns.filter(\.isHidden).map(\.identifier.rawValue)
            layout.save(parent.key)
            footer?.needsDisplay = true
        }

        /// Forgets hand-set widths, so every column goes back to fitting its content.
        @objc private func resetWidths() {
            for ident in identifiers { layout.widths[ident] = nil }
            layout.save(parent.key)
            refresh()
        }

        @objc private func resetOrder() {
            layout.order = []
            layout.save(parent.key)
            refresh()
        }

        private func refresh() {
            columns = []
            shownTable = nil
            apply()
        }
    }
}

enum GridMetrics {
    static let rowHeight: CGFloat = 22
    static var gridColor: NSColor { NSColor.separatorColor.withAlphaComponent(0.35) }
    /// Space left of the text, right of text, and right of a debit (so it lines up with a credit's closing bracket).
    static let leading: CGFloat = 8, trailing: CGFloat = 8, debitTrailing: CGFloat = 12.5

    static func font(money: Bool, emphasized: Bool) -> NSFont {
        money ? .monospacedDigitSystemFont(ofSize: 12, weight: emphasized ? .semibold : .regular)
              : .systemFont(ofSize: 12, weight: emphasized ? .semibold : .regular)
    }

    /// The total lines that end a table — a total row and any subtotals after it (net income, tax
    /// basis). They are pinned under the grid so they stay in view while the rows scroll.
    static func split(_ rows: [ReportRow]) -> (body: [ReportRow], pinned: [ReportRow]) {
        var start = rows.count
        while start > 0, rows.count - start < 4, rows[start - 1].style == .total || rows[start - 1].style == .subtotal { start -= 1 }
        guard let first = rows[start...].firstIndex(where: { $0.style == .total }) else { return (rows, []) }
        return (Array(rows[..<first]), Array(rows[first...]))
    }

    /// Width needed to show every value of a column in full, padding included.
    static func contentWidth(column: Int, kind: ReportColumn.Kind, rows: [ReportRow], pinned: [ReportRow]) -> CGFloat {
        var widest: CGFloat = 0
        func measure(_ s: String, emphasized: Bool, padding: CGFloat) {
            let w = (s as NSString).size(withAttributes: [.font: font(money: kind == .money, emphasized: emphasized)]).width
            widest = max(widest, ceil(w) + padding)
        }
        for emphasized in [false, true] {
            let group = (rows + pinned).filter { ($0.style != .normal) == emphasized }
            if kind == .money {
                // The widest figures are the largest debit and the largest credit.
                var debit: Money?, credit: Money?
                var text: [String] = []
                for r in group where column < r.cells.count {
                    switch r.cells[column] {
                    case .money(let m):
                        if m.cents >= 0 { if debit.map({ m.cents > $0.cents }) ?? true { debit = m } } else if credit.map({ m.cents < $0.cents }) ?? true { credit = m }
                    case .text(let s): text.append(s)
                    case .empty: break
                    }
                }
                if let debit { measure(debit.isZero ? "–" : debit.formatted, emphasized: emphasized, padding: leading + debitTrailing + 3) }
                if let credit { measure(credit.formatted, emphasized: emphasized, padding: leading + trailing + 3) }
                for s in text.sorted(by: { $0.count > $1.count }).prefix(3) { measure(s, emphasized: emphasized, padding: leading + trailing + 3) }
            } else {
                var longest: [String] = []
                for r in group where column < r.cells.count {
                    if case .text(let s) = r.cells[column], !s.isEmpty { longest.append(s) }
                }
                // Character count is close enough to pick the candidates; the few longest are measured for real.
                for s in longest.sorted(by: { $0.count > $1.count }).prefix(4) { measure(s, emphasized: emphasized, padding: leading + trailing + 3) }
            }
        }
        return widest
    }
}

/// The scrolling table with its total lines fixed underneath.
final class GridContainerView: NSView {
    let scroll: NSScrollView
    let footer: GridFooterView

    init(scroll: NSScrollView, footer: GridFooterView) {
        self.scroll = scroll
        self.footer = footer
        super.init(frame: .zero)
        addSubview(scroll)
        addSubview(footer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = min(footer.height, max(0, bounds.height - 60))
        footer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        scroll.frame = NSRect(x: 0, y: h, width: bounds.width, height: bounds.height - h)
        footer.needsDisplay = true
    }
}

/// Draws the pinned total lines in step with the table above: same column positions, widths,
/// order and horizontal scroll, so each total sits under its column.
final class GridFooterView: NSView {
    weak var tableView: NSTableView?
    weak var clipView: NSClipView?
    var onActivate: ((ReportRow) -> Void)?
    private var rows: [ReportRow] = []
    private var columns: [ReportColumn] = []
    private var identifiers: [String] = []

    override var isFlipped: Bool { true }

    var height: CGFloat { rows.isEmpty ? 0 : CGFloat(rows.count) * GridMetrics.rowHeight + 1 }

    func show(rows: [ReportRow], columns: [ReportColumn], identifiers: [String]) {
        self.rows = rows
        self.columns = columns
        self.identifiers = identifiers
        isHidden = rows.isEmpty
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let tv = tableView, !rows.isEmpty else { return }
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        bounds.fill()
        let shift = clipView?.bounds.minX ?? 0
        for (n, row) in rows.enumerated() {
            let y = 1 + CGFloat(n) * GridMetrics.rowHeight
            NSColor.labelColor.withAlphaComponent(n == 0 ? 0.45 : 0.2).setFill()
            NSRect(x: 0, y: y - 1, width: bounds.width, height: 1).fill()
            for (ci, col) in tv.tableColumns.enumerated() where !col.isHidden {
                guard let i = identifiers.firstIndex(of: col.identifier.rawValue), i < columns.count else { continue }
                var cell = tv.rect(ofColumn: ci)
                cell.origin.x -= shift
                cell.origin.y = y
                cell.size.height = GridMetrics.rowHeight
                guard cell.maxX > 0, cell.minX < bounds.width else { continue }
                GridMetrics.gridColor.setFill()
                NSRect(x: cell.maxX - 1, y: y, width: 1, height: GridMetrics.rowHeight).fill()
                draw(i < row.cells.count ? row.cells[i] : .empty, money: columns[i].kind == .money, in: cell)
            }
        }
    }

    private func draw(_ content: ReportCell, money: Bool, in cell: NSRect) {
        var text = "", color = NSColor.labelColor, trailing = GridMetrics.trailing
        switch content {
        case .empty: return
        case .text(let s): text = s
        case .money(let m):
            text = m.isZero ? "–" : m.formatted
            if m.isZero { color = .secondaryLabelColor }
            if m.cents >= 0 { trailing = GridMetrics.debitTrailing }
        }
        let style = NSMutableParagraphStyle()
        style.alignment = money ? .right : .left
        style.lineBreakMode = .byTruncatingTail
        let font = GridMetrics.font(money: money, emphasized: true)
        let line = ceil(font.ascender - font.descender + font.leading)
        let rect = NSRect(x: cell.minX + GridMetrics.leading, y: cell.minY + (cell.height - line) / 2 - 0.5,
                          width: max(0, cell.width - GridMetrics.leading - trailing), height: line)
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return super.mouseDown(with: event) }
        let y = convert(event.locationInWindow, from: nil).y
        let n = Int((y - 1) / GridMetrics.rowHeight)
        if n >= 0, n < rows.count { onActivate?(rows[n]) }
    }
}

final class GridTableView: NSTableView {
    var copyHandler: (() -> Void)?

    @objc func copy(_ sender: Any?) { copyHandler?() }
}

final class GridRowView: NSTableRowView {
    var style: ReportRow.Style = .normal

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard style == .total || style == .subtotal else { return }
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        bounds.fill()
        NSColor.labelColor.withAlphaComponent(style == .total ? 0.45 : 0.2).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

final class GridCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var trailing: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier, money: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.alignment = money ? .right : .left
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        textField = label
        trailing = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            trailing,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ content: ReportCell, emphasized: Bool) {
        switch content {
        case .empty:
            label.stringValue = ""
            label.toolTip = nil
        case .text(let s):
            label.stringValue = s
            label.font = .systemFont(ofSize: 12, weight: emphasized ? .semibold : .regular)
            label.textColor = .labelColor
            label.toolTip = s.count > 24 ? s : nil
            trailing.constant = -8
        case .money(let m):
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: emphasized ? .semibold : .regular)
            label.toolTip = nil
            if m.isZero {
                label.stringValue = "–"
                label.textColor = emphasized ? .secondaryLabelColor : .tertiaryLabelColor
                trailing.constant = -12.5
            } else {
                label.stringValue = m.formatted
                label.textColor = .labelColor
                // Keep the last digit of debits and credits in one column.
                trailing.constant = m.cents < 0 ? -8 : -12.5
            }
        }
    }
}

/// A small green / orange pill used for "in balance" style checks.
struct CheckBadge: View {
    let ok: Bool
    let text: String

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(ok ? Color.green : Color.orange)
            .labelStyle(.titleAndIcon)
    }
}
