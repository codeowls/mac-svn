import AppKit
import FinderSync
import SwiftUI
import SVNCore

enum StartupGuide {
    static let windowID = "startup-guide"
    static let preferenceKey = "startupGuidePresentedVersion"
    static let version = 1
}

/// 首次引导使用独立窗口，保留主窗口的业务弹窗、访达请求和提交草稿。
@MainActor
struct StartupGuidePresenter: ViewModifier {
    @AppStorage(StartupGuide.preferenceKey) private var presentedVersion = 0
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            if presentedVersion < StartupGuide.version {
                openWindow(id: StartupGuide.windowID)
            }
        }
    }
}

@MainActor
struct StartupGuideView: View {
    @ObservedObject private var integration = FinderIntegration.shared
    @AppStorage(StartupGuide.preferenceKey) private var presentedVersion = 0
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkspaceHeading(title: L10n.text("首次使用设置"), icon: "folder.badge.gearshape")
            Text(L10n.text("访达集成可显示右键菜单和本地状态角标。请按下面两步完成设置，也可以稍后再设置。"))
                .font(.callout)

            GroupBox(L10n.text("1. 启用访达扩展")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("点击“管理访达扩展”，在系统设置中开启 Mac SVN，然后点击系统设置里的“完成”。"))
                        .font(.callout)
                    Label(
                        integration.extensionEnabled
                            ? L10n.text("访达扩展已启用")
                            : L10n.text("请在系统设置中启用 Mac SVN 访达扩展。"),
                        systemImage: integration.extensionEnabled ? "checkmark.circle.fill" : "circle"
                    )
                    .foregroundStyle(integration.extensionEnabled ? Color.green : Color.secondary)
                    HStack {
                        Button(L10n.text("管理访达扩展")) {
                            FIFinderSyncController.showExtensionManagementInterface()
                        }
                        Button(L10n.text("重新检查")) { integration.checkAndSync() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            GroupBox(L10n.text("2. 添加工作副本")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("在主窗口打开或检出工作副本，再到“设置 → 访达”点击“添加当前工作副本”。每个副本需要单独添加。"))
                        .font(.callout)
                    SettingsLink { Text(L10n.text("打开应用设置")) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("目录访问")).font(.headline)
                Text(L10n.text("访问文稿、桌面等受保护目录时，macOS 可能按需询问文件访问权限。"))
                Text(L10n.text("访达功能无需辅助功能或屏幕录制权限。角标在 Mac SVN 运行期间刷新，绿色仅表示本地无修改。"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()
            Text(L10n.text("访达集成为可选功能；稍后设置不影响主工作区使用。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(L10n.text("稍后设置")) { close() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.text("开始使用")) { close() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!integration.extensionEnabled)
            }
        }
        .padding(24)
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(WorkspaceBackground())
        .onAppear {
            // 记录实际展示，不把“稍后”或关闭窗口当作扩展已启用。
            presentedVersion = StartupGuide.version
        }
        .modifier(FinderExtensionStatusObserver())
    }

    private func close() {
        dismissWindow(id: StartupGuide.windowID)
    }
}
