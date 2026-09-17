import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        // Reload the bundled artwork so an in-place rebuild also updates the running Dock tile.
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct MacSVNApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Mac SVN", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .defaultSize(width: 1250, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开工作副本…") { model.chooseWorkingCopy() }
                    .keyboardShortcut("o")
                    .disabled(model.isBusy)
            }
            CommandMenu("SVN") {
                Button("刷新本地状态") { model.refresh() }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy || model.workingCopy == nil)
                Button("更新工作副本") { model.update() }
                    .disabled(model.isBusy || model.workingCopy == nil)
                Button("历史记录") { model.showSavedHistory() }
                    .disabled(model.isBusy || model.workingCopy == nil)
            }
        }
        Settings {
            SettingsView(model: model)
        }
    }
}
