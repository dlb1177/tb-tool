import AppKit
import SwiftUI

/// Closes the window a view lives in. Every panel the app opens (journal entry, account activity,
/// import, settings…) is a real window: movable, resizable, and free to sit on another display.
struct CloseWindowAction {
    let close: () -> Void
    func callAsFunction() { close() }
}

private struct CloseWindowKey: EnvironmentKey {
    static let defaultValue = CloseWindowAction(close: {})
}

extension EnvironmentValues {
    var closeWindow: CloseWindowAction {
        get { self[CloseWindowKey.self] }
        set { self[CloseWindowKey.self] = newValue }
    }
}

/// Set by a window's content while it holds typing that hasn't been saved, so the close button asks first.
final class CloseGuard {
    var isDirty = false
    var what = "your changes"
}

final class Windows: NSObject, NSWindowDelegate {
    static let shared = Windows()

    private struct Entry {
        let window: NSWindow
        let closeGuard: CloseGuard?
        let onClose: (() -> Void)?
    }

    private var open: [String: Entry] = [:]
    private var lastCascade: NSPoint?

    func isOpen(_ key: String) -> Bool { open[key] != nil }

    /// Shows the window for `key`, or brings it forward if it is already open.
    func show<Content: View>(_ key: String, title: String, size: NSSize, minSize: NSSize, frameName: String? = nil,
                             closeGuard: CloseGuard? = nil, onClose: (() -> Void)? = nil,
                             @ViewBuilder content: () -> Content) {
        if let entry = open[key] {
            entry.window.title = title
            entry.window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(key)
        window.delegate = self
        window.tabbingMode = .disallowed
        let root = content()
            .environmentObject(AppModel.shared)
            .environment(\.closeWindow, CloseWindowAction { [weak self] in self?.close(key) })
        let host = NSHostingView(rootView: AnyView(root))
        host.sizingOptions = [.minSize]
        window.contentView = host
        window.contentMinSize = minSize
        window.setContentSize(size)

        // Each kind of window remembers where it was last put. A second one of the same kind steps aside.
        let name = "TBWindow.\(frameName ?? key)"
        let inUse = open.values.contains { $0.window.frameAutosaveName == name }
        if !inUse, window.setFrameUsingName(name) {
            window.setFrameAutosaveName(name)
        } else if !inUse {
            window.center()
            window.setFrameAutosaveName(name)
        } else {
            let from = open.values.first { $0.window.frameAutosaveName == name }?.window
            if let from { window.setFrame(from.frame, display: false) }
            let top = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            lastCascade = window.cascadeTopLeft(from: window.cascadeTopLeft(from: top))
        }
        open[key] = Entry(window: window, closeGuard: closeGuard, onClose: onClose)
        window.makeKeyAndOrderFront(nil)
    }

    func setTitle(_ key: String, _ title: String) { open[key]?.window.title = title }

    /// Closes without asking (Cancel, Done, or after the work was saved).
    func close(_ key: String) {
        guard let entry = open[key] else { return }
        entry.closeGuard?.isDirty = false
        entry.window.close()
    }

    func closeAll() {
        for key in Array(open.keys) { close(key) }
    }

    func closeAll(prefix: String) {
        for key in open.keys where key.hasPrefix(prefix) { close(key) }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let entry = open.values.first(where: { $0.window === sender }), let g = entry.closeGuard, g.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard \(g.what)?"
        alert.informativeText = "This window has changes that haven't been saved."
        alert.addButton(withTitle: "Keep Editing")
        alert.addButton(withTitle: "Discard")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = open.first(where: { $0.value.window === window })?.key else { return }
        let entry = open.removeValue(forKey: key)
        entry?.onClose?()
        // Let go of the SwiftUI view tree once the close has finished.
        DispatchQueue.main.async { window.contentView = nil }
    }

    /// One undo history for the whole app, so ⌘Z works from any of its windows.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        AppModel.shared.undoManager
    }
}
