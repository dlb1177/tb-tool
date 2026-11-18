import AppKit
import SwiftUI
import TBCore

/// Type any part of an account number or name and a list of every matching account appears
/// underneath, narrowing as you type. ↑ ↓ move, Return or Tab takes the highlighted account, a
/// click takes any other, Esc closes the list.
struct AccountSearchField: NSViewRepresentable {
    /// In chart order.
    var accounts: [Account]
    @Binding var accountID: String?
    var placeholder = "Type an account number or name"
    /// What the list shows on the right of each row. The account's type unless given.
    var detail: ((Account) -> String)? = nil
    /// Keep the matches in the order of `accounts` instead of putting the closest first.
    var keepOrder = false
    /// With this, the field is a picker that adds: choosing calls it and empties the field for the next one.
    var onChoose: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> SearchTextField {
        let field = SearchTextField()
        field.placeholderString = placeholder
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.onClick = { [weak coordinator = context.coordinator] in coordinator?.fieldClicked() }
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: SearchTextField, context: Context) {
        let c = context.coordinator
        c.parent = self
        // Show the chosen account, but never overwrite what is being typed.
        if field.currentEditor() == nil, c.shownID != accountID {
            c.shownID = accountID
            field.stringValue = accounts.first { $0.id == accountID }?.display ?? ""
        }
    }

    static func dismantleNSView(_ field: SearchTextField, coordinator: Coordinator) {
        coordinator.hideList()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
        var parent: AccountSearchField
        weak var field: SearchTextField?
        /// The account the field's text currently stands for.
        var shownID: String?
        private var matches: [Account] = []
        private var terms: [String] = []
        private var panel: NSPanel?
        private var table: NSTableView?
        private var observers: [NSObjectProtocol] = []

        init(_ parent: AccountSearchField) { self.parent = parent }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        private var listIsOpen: Bool { panel?.isVisible ?? false }

        // MARK: Choosing

        private func set(_ id: String?) {
            shownID = id
            if parent.accountID != id { parent.accountID = id }
        }

        private func choose(_ account: Account) {
            if let onChoose = parent.onChoose {
                field?.stringValue = ""
                shownID = nil
                hideList()
                onChoose(account.id)
                return
            }
            field?.stringValue = account.display
            set(account.id)
            hideList()
            // Put the cursor at the end so Tab moves on naturally.
            if let editor = field?.currentEditor() {
                editor.selectedRange = NSRange(location: (field?.stringValue as NSString?)?.length ?? 0, length: 0)
            }
        }

        private var highlighted: Account? {
            guard let table, listIsOpen, table.selectedRow >= 0, table.selectedRow < matches.count else { return nil }
            return matches[table.selectedRow]
        }

        // MARK: The list

        private func refresh(_ text: String) {
            terms = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            if parent.keepOrder {
                matches = Array(parent.accounts.lazy.filter { a in let d = a.display.lowercased(); return self.terms.allSatisfy { d.contains($0) } }.prefix(500))
            } else {
                matches = Engagement.searchAccounts(parent.accounts, text, limit: 300)
            }
            guard !matches.isEmpty else {
                hideList()
                return
            }
            showList()
            table?.reloadData()
            table?.selectRowIndexes([0], byExtendingSelection: false)
            table?.scrollRowToVisible(0)
        }

        func fieldClicked() {
            guard !listIsOpen, let field else { return }
            // Clicking into a field that already holds an account lists everything, with that account in view.
            let text = shownID == nil ? field.stringValue : ""
            refresh(text)
            if let id = shownID, let i = matches.firstIndex(where: { $0.id == id }) {
                table?.selectRowIndexes([i], byExtendingSelection: false)
                table?.scrollRowToVisible(min(i + 4, matches.count - 1))
            }
        }

        private func showList() {
            guard let field, let window = field.window else { return }
            if panel == nil { buildPanel() }
            guard let panel else { return }
            let rows = min(matches.count, 12)
            let height = CGFloat(rows) * 24 + 6
            let onScreen = window.convertToScreen(field.convert(field.bounds, to: nil))
            let width = max(onScreen.width, 460)
            var origin = NSPoint(x: onScreen.minX, y: onScreen.minY - height - 3)
            if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
                if origin.y < visible.minY { origin.y = onScreen.maxY + 3 }  // no room below: open upward
                origin.x = min(origin.x, visible.maxX - width - 4)
            }
            panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
            if panel.parent == nil {
                window.addChildWindow(panel, ordered: .above)
                observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                    self?.hideList()
                })
            }
            panel.orderFront(nil)
        }

        func hideList() {
            guard let panel else { return }
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
        }

        private func buildPanel() {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = true
            panel.hasShadow = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.becomesKeyOnlyIfNeeded = true

            let backdrop = NSVisualEffectView()
            backdrop.material = .menu
            backdrop.state = .active
            backdrop.blendingMode = .behindWindow
            backdrop.wantsLayer = true
            backdrop.layer?.cornerRadius = 7
            backdrop.layer?.masksToBounds = true
            backdrop.layer?.borderWidth = 0.5
            backdrop.layer?.borderColor = NSColor.separatorColor.cgColor

            let table = NSTableView()
            table.headerView = nil
            table.backgroundColor = .clear
            table.rowHeight = 24
            table.intercellSpacing = NSSize(width: 0, height: 0)
            table.style = .plain
            table.selectionHighlightStyle = .regular
            table.allowsEmptySelection = true
            table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("account")))
            table.tableColumns[0].resizingMask = .autoresizingMask
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.dataSource = self
            table.delegate = self
            table.target = self
            table.action = #selector(rowClicked(_:))

            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            scroll.documentView = table
            scroll.translatesAutoresizingMaskIntoConstraints = false
            backdrop.addSubview(scroll)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 3),
                scroll.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -3),
            ])
            panel.contentView = backdrop
            self.panel = panel
            self.table = table
        }

        @objc private func rowClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard row >= 0, row < matches.count else { return }
            choose(matches[row])
        }

        func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SuggestionRowView() }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("suggestion")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? SuggestionCell) ?? SuggestionCell(identifier: id)
            if row < matches.count { cell.configure(matches[row], terms: terms, detail: parent.detail?(matches[row])) }
            return cell
        }

        // MARK: Typing

        func controlTextDidChange(_ notification: Notification) {
            guard let field else { return }
            let text = field.stringValue
            // Until an account is picked, the line has no account — unless the text names one exactly.
            set(parent.accounts.first { $0.display.caseInsensitiveCompare(text.trimmingCharacters(in: .whitespaces)) == .orderedSame }?.id)
            refresh(text)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
                guard listIsOpen, let table else {
                    refresh(shownID == nil ? control.stringValue : "")
                    return true
                }
                let step = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
                let next = max(0, min(matches.count - 1, table.selectedRow + step))
                table.selectRowIndexes([next], byExtendingSelection: false)
                table.scrollRowToVisible(next)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                guard let account = highlighted else { return false }
                choose(account)
                return true
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                if let account = highlighted, !control.stringValue.trimmingCharacters(in: .whitespaces).isEmpty { choose(account) }
                return false
            case #selector(NSResponder.cancelOperation(_:)):
                guard listIsOpen else { return false }
                hideList()
                return true
            default:
                return false
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            hideList()
            guard let field else { return }
            if parent.onChoose != nil {
                field.stringValue = ""
                return
            }
            let text = field.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
            guard !text.isEmpty else {
                set(nil)
                return
            }
            if let id = shownID, let chosen = parent.accounts.first(where: { $0.id == id }), chosen.display.lowercased() == text { return }
            let all = parent.accounts
            let match = all.first { $0.display.lowercased() == text }
                ?? all.first { !$0.number.isEmpty && $0.number.lowercased() == text }
                ?? all.first { $0.name.lowercased() == text }
                ?? { () -> Account? in
                    let hits = Engagement.searchAccounts(all, text, limit: 2)
                    return hits.count == 1 ? hits[0] : nil
                }()
            if let match {
                field.stringValue = match.display
                set(match.id)
            } else {
                set(nil)
            }
        }
    }
}

final class SearchTextField: NSTextField {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onClick?()
    }
}

/// Draws the highlighted suggestion as selected even though its panel never becomes the key window.
private final class SuggestionRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { true }
        set {}
    }

    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: 4, yRadius: 4).fill()
    }

    override var isSelected: Bool {
        didSet { subviews.compactMap { $0 as? SuggestionCell }.forEach { $0.setSelected(isSelected) } }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? SuggestionCell)?.setSelected(isSelected)
    }
}

private final class SuggestionCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let kind = NSTextField(labelWithString: "")
    private var account: Account?
    private var terms: [String] = []
    private var detail: String?
    private var selected = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        for v in [label, kind] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.lineBreakMode = .byTruncatingTail
            addSubview(v)
        }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        kind.setContentCompressionResistancePriority(.required, for: .horizontal)
        kind.font = .systemFont(ofSize: 11)
        kind.alignment = .right
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            kind.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 10),
            kind.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            kind.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ account: Account, terms: [String], detail: String? = nil) {
        self.account = account
        self.terms = terms
        self.detail = detail
        render()
    }

    func setSelected(_ on: Bool) {
        selected = on
        render()
    }

    /// Number in tabular digits, then the name, with the typed fragments in bold.
    private func render() {
        guard let account else { return }
        let primary: NSColor = selected ? .alternateSelectedControlTextColor : .labelColor
        let secondary: NSColor = selected ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        let text = NSMutableAttributedString()
        let plain: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular), .foregroundColor: primary]
        if !account.number.isEmpty {
            text.append(NSAttributedString(string: account.number + "  ", attributes: plain))
        }
        text.append(NSAttributedString(string: account.name, attributes: plain))
        let whole = text.string.lowercased() as NSString
        for term in terms where !term.isEmpty {
            var search = NSRange(location: 0, length: whole.length)
            while search.length > 0 {
                let hit = whole.range(of: term, options: [], range: search)
                guard hit.location != NSNotFound, hit.location + hit.length <= text.length else { break }
                text.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold), range: hit)
                let next = hit.location + hit.length
                search = NSRange(location: next, length: whole.length - next)
            }
        }
        label.attributedStringValue = text
        kind.stringValue = detail ?? account.type.label
        kind.textColor = secondary
    }
}
