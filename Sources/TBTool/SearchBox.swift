import AppKit
import SwiftUI

/// The search box used on every screen. Typing narrows what the screen shows. **Esc**, Return,
/// or a click anywhere else leaves the box — the keyboard goes back to the list — and what was
/// typed stays, so the narrowed list can be worked in. The ✕ clears it.
struct SearchBox: View {
    let prompt: String
    @Binding var text: String
    var icon = "magnifyingglass"
    @FocusState private var focused: Bool
    @State private var frame = CGRect.zero
    @State private var id = UUID()

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
                .onExitCommand { leave() }
                .onSubmit { leave() }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(focused ? 0.7 : 0), lineWidth: 1.5))
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { frame = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { _, new in
                    frame = new
                    if focused { SearchFocus.active = (id, new) }
                }
        })
        .onChange(of: focused) { _, on in
            if on {
                SearchFocus.active = (id, frame)
            } else if SearchFocus.active?.id == id {
                SearchFocus.active = nil
            }
        }
        .onDisappear {
            if SearchFocus.active?.id == id { SearchFocus.active = nil }
        }
    }

    private func leave() {
        focused = false
        // Hand the keyboard back to the window, so keys reach the list again.
        SearchFocus.window(typingIn: frame)?.makeFirstResponder(nil)
    }
}

/// Which search box, if any, is being typed in, and where it is in its window. A click outside
/// it ends the typing there without clearing what was typed.
enum SearchFocus {
    static var active: (id: UUID, frame: CGRect)?
    private static var monitor: Any?

    /// Whether the text being typed in a window is in the box at `frame` (given, as SwiftUI
    /// gives it, from the top left of the window's content).
    private static func isTyping(in window: NSWindow, at frame: CGRect) -> Bool {
        guard let editor = window.firstResponder as? NSTextView, let field = editor.delegate as? NSView, let content = window.contentView else { return false }
        var box = field.convert(field.bounds, to: content)
        if !content.isFlipped { box.origin.y = content.bounds.height - box.maxY }
        return frame.insetBy(dx: -8, dy: -8).contains(NSPoint(x: box.midX, y: box.midY))
    }

    static func window(typingIn frame: CGRect) -> NSWindow? {
        NSApp.windows.first { isTyping(in: $0, at: frame) }
    }

    /// Called once when the app starts.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard let active, let window = event.window, let content = window.contentView, isTyping(in: window, at: active.frame) else { return event }
            var p = content.convert(event.locationInWindow, from: nil)
            if !content.isFlipped { p.y = content.bounds.height - p.y }
            if !active.frame.insetBy(dx: -3, dy: -3).contains(p) { window.makeFirstResponder(nil) }
            return event
        }
    }
}

/// Return presses the control the keyboard is on, as Space does. (macOS on its own sends
/// Return to the window's default button, wherever the keyboard focus is.) Tabbing to a button
/// and pressing Return then does what the button says.
enum ReturnPressesFocusedButton {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 36 || event.keyCode == 76,
                  event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  let window = event.window, let responder = window.firstResponder else { return event }
            if let button = responder as? NSButton, button.isEnabled {
                button.performClick(nil)
                return nil
            }
            // The app's own buttons: while the keyboard is on one, the window's first responder
            // is the stand-in SwiftUI uses for it, and Space is what presses it.
            guard String(describing: type(of: responder)) == "KeyViewProxy" else { return event }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let space = NSEvent.keyEvent(with: type, location: event.locationInWindow, modifierFlags: [], timestamp: event.timestamp, windowNumber: window.windowNumber,
                                                context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) {
                    NSApp.postEvent(space, atStart: type == .keyDown)
                }
            }
            return nil
        }
    }
}
