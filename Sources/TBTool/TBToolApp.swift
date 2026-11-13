import AppKit
import SwiftUI
import TBCore

@main
struct TBToolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @AppStorage(HideZeroToggle.key) private var hideZero = true

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
                Button("Show JSON File in Finder") {
                    if let url = model.fileURL { model.reveal(url) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.engagement == nil)
            }
            CommandGroup(before: .sidebar) {
                Toggle("Hide Zero Balance Rows", isOn: $hideZero)
                    .keyboardShortcut("0", modifiers: [.command, .shift])
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.startup()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--tb-snapshot"), i + 1 < args.count {
            Snapshotter.run(into: URL(fileURLWithPath: args[i + 1], isDirectory: true))
        }
    }

    // Double-clicking a trial balance file, or dropping it on the app icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { AppModel.shared.open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
