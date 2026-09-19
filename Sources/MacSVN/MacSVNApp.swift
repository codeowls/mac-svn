import SVNCore
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
    @AppStorage("workspaceAppearance") private var appearance = "system"

    init() {
        L10n.language.save()
    }

    private var preferredColorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    var body: some Scene {
        Window("Mac SVN", id: "main") {
            ContentView(model: model)
                .environment(\.locale, L10n.language.locale)
                .frame(minWidth: 1000, minHeight: 680)
                .preferredColorScheme(preferredColorScheme)
        }
        .defaultSize(width: 1250, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.text("打开工作副本…")) { model.chooseWorkingCopy() }
                    .keyboardShortcut("o")
                    .disabled(model.isBusy)
            }
            CommandGroup(after: .sidebar) {
                Picker(L10n.text("外观"), selection: $appearance) {
                    Text(L10n.text("跟随系统")).tag("system")
                    Text(L10n.text("浅色")).tag("light")
                    Text(L10n.text("深色")).tag("dark")
                }
            }
            CommandMenu("SVN") {
                Button(L10n.text("刷新本地状态")) { model.refresh() }
                    .keyboardShortcut("r")
                    .disabled(model.isBusy || model.workingCopy == nil)
                Button(L10n.text("更新工作副本")) { model.update() }
                    .disabled(model.isBusy || model.workingCopy == nil)
                Button(L10n.text("历史记录")) { model.showSavedHistory() }
                    .disabled(model.isBusy || model.workingCopy == nil)
            }
        }
        Settings {
            SettingsView(model: model)
                .environment(\.locale, L10n.language.locale)
                .preferredColorScheme(preferredColorScheme)
        }
    }
}
