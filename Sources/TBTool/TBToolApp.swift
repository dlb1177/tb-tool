import AppKit
import SwiftUI
import TBCore

@main
struct TBToolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @AppStorage(HideZeroToggle.key) private var hideZero = true
    @AppStorage(AppearanceChoice.key) private var appearance = AppearanceChoice.system.rawValue

    var body: some Scene {
        Window("TB Tool", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Trial Balance File…") { model.newFilePanel() }
                    .keyboardShortcut("n")
                Button("New Window") { model.openInNewWindow(nil) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
                Button("Open in New Window…") { model.openPanel(newWindow: true) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Open…") { model.openPanel() }
                    .keyboardShortcut("o")
                Button("Close File") { model.closeFile() }
                    .disabled(model.engagement == nil)
                Divider()
                Button("Trial Balance Settings…") { model.showSettings() }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
                    .disabled(model.engagement == nil)
                Button("Roll Forward to Next Year…") { model.showRollForward() }
                    .disabled(model.engagement == nil)
                Divider()
                Button("Import Trial Balances…") { model.importPanel() }
                    .keyboardShortcut("i")
                    .disabled(model.engagement == nil)
                Button("Paste Trial Balance") { model.pasteTrialBalance() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(model.engagement == nil)
                Button("New Blank Trial Balance…") { model.newBlankEntity() }
                    .disabled(model.engagement == nil)
                Divider()
                Button("Import Chart of Accounts…") { model.importChartPanel() }
                    .disabled(model.engagement == nil)
                Button("Export Chart of Accounts…") { model.exportChartPanel(csv: false) }
                    .disabled(model.engagement == nil)
                Button("Import Grouping List…") { model.importGroupingListPanel() }
                    .disabled(model.engagement == nil)
                Button("Export Grouping List…") { model.exportGroupingListPanel(csv: false) }
                    .disabled(model.engagement == nil)
                Divider()
                Button("Make Binder Folders in a Folder…") { model.makeStandardFolders(elsewhere: true) }
                Divider()
                Button("Show JSON File in Finder") {
                    if let url = model.fileURL { model.reveal(url) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.engagement == nil)
            }
            CommandGroup(before: .sidebar) {
                Toggle("Hide Zero Balance Rows", isOn: $hideZero)
                    .keyboardShortcut("0", modifiers: [.command, .shift])
                Picker("Appearance", selection: Binding(get: { appearance }, set: {
                    appearance = $0
                    AppearanceChoice.apply()
                })) {
                    ForEach(AppearanceChoice.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                }
                Divider()
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.showAppSettings() }
                    .keyboardShortcut(",")
            }
            CommandMenu("Entries") {
                Button("New Adjusting Entry") { model.newEntry(.adjusting) }
                    .keyboardShortcut("j")
                Button("New Reclassifying Entry") { model.newEntry(.reclassifying) }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                Button("New Tax-only Entry") { model.newEntry(.taxOnly) }
                    .keyboardShortcut("j", modifiers: [.command, .option])
                Button("New Eliminating Entry") { model.newEntry(.eliminating) }
                    .keyboardShortcut("j", modifiers: [.command, .control])
                Divider()
                Button("Fix Broken File Links…") { model.showFixLinks() }
                    .disabled(model.engagement == nil)
                Divider()
                Button("Quick Export…") { model.quickExport() }
                    .keyboardShortcut("e")
                Button("Export Workbook…") { model.exportWorkbookPanel() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
        }
    }
}

/// Light, dark, or whatever the Mac is set to.
enum AppearanceChoice: String, CaseIterable {
    case system, light, dark

    static let key = "appearance"

    var label: String {
        switch self {
        case .system: return "Automatic (follows the Mac)"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    static func apply() {
        // Pictures for the manual choose their own.
        guard !CommandLine.arguments.contains("--tb-snapshot") else { return }
        switch AppearanceChoice(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceChoice.apply()
        SearchFocus.install()
        ReturnPressesFocusedButton.install()
        AppModel.shared.startup()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--tb-snapshot"), i + 1 < args.count {
            Snapshotter.run(into: URL(fileURLWithPath: args[i + 1], isDirectory: true))
        }
    }

    // Double-clicking a trial balance file, or dropping it on the app icon.
    // With a trial balance already open, another one opens beside it in a window of its own.
    func application(_ application: NSApplication, open urls: [URL]) {
        let model = AppModel.shared
        for (n, url) in urls.enumerated() {
            if url.standardizedFileURL == model.fileURL?.standardizedFileURL { continue }
            if model.engagement == nil && n == 0 { model.open(url) } else { model.openInNewWindow(url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
