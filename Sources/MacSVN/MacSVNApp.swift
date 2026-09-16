import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
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
                Button("历史记录") { model.loadHistory() }
                    .disabled(model.isBusy || model.workingCopy == nil)
            }
        }
        Settings {
            SettingsView(model: model)
        }
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Text("SVN 可执行文件").font(.headline)
            TextField("例如 /opt/homebrew/bin/svn", text: $model.executablePath)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isBusy)
            Text("未安装时，在终端运行：brew install subversion")
                .font(.caption).foregroundStyle(.secondary)
            Text("首版复用本机 SVN 缓存的凭据。请先在终端完成一次仓库认证；App 不保存密码，也不自动信任证书。")
                .font(.callout)
            Button("保存设置") { model.saveSettings() }
                .disabled(model.isBusy)
        }
        .padding(24)
        .frame(width: 540)
    }
}
