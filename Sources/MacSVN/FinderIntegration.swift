import AppKit
import FinderSync
import SwiftUI
import SVNCore

/// Host preferences are authoritative. Acknowledgments describe directory configuration, not badge status.
@MainActor
final class FinderIntegration: NSObject, ObservableObject {
    static let shared = FinderIntegration()
    @Published private(set) var roots: [String]
    @Published private(set) var synchronized = false
    @Published var error: String?

    private override init() {
        roots = UserDefaults.standard.stringArray(forKey: "finderWorkingCopies") ?? []
        super.init()
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(requested(_:)), name: FinderConfiguration.requested, object: nil)
        center.addObserver(self, selector: #selector(applied(_:)), name: FinderConfiguration.applied, object: nil)
        publish()
    }

    private var configuration: FinderConfiguration {
        FinderConfiguration(roots: roots, language: L10n.language.rawValue)
    }

    @objc private func requested(_ notification: Notification) { publish() }

    @objc private func applied(_ notification: Notification) {
        guard let value = notification.object as? String,
              let received = try? FinderConfiguration.decode(value) else { return }
        synchronized = received == configuration
    }

    func publish() {
        synchronized = false
        FinderBadgeService.shared.configure(
            roots: roots,
            executable: UserDefaults.standard.string(forKey: "svnExecutable") ?? SVNClient.discoverExecutable()?.path ?? "",
            globalIgnores: UserDefaults.standard.string(forKey: "svnGlobalIgnores")
        )
        do {
            let value = try configuration.encoded()
            DistributedNotificationCenter.default().postNotificationName(
                FinderConfiguration.changed, object: value, userInfo: nil, deliverImmediately: true
            )
        } catch {
            self.error = error.localizedDescription
        }
    }

    func add(_ root: URL) {
        let path = root.resolvingSymlinksInPath().standardizedFileURL.path
        if !roots.contains(path) { roots.append(path) }
        save()
    }

    func remove(_ path: String) {
        roots.removeAll { $0 == path }
        save()
    }

    func includes(_ root: URL) -> Bool {
        roots.contains(root.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    private func save() {
        UserDefaults.standard.set(roots, forKey: "finderWorkingCopies")
        publish()
    }
}

struct FinderIntegrationSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var integration = FinderIntegration.shared
    @ObservedObject private var badges = FinderBadgeService.shared
    @ViewState private var enabled = FIFinderSyncController.isExtensionEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("访达集成")).font(.headline)
            Text(enabled ? L10n.text("访达扩展已启用") : L10n.text("请在系统设置中启用 Mac SVN 访达扩展。"))
            HStack {
                Button(L10n.text("管理访达扩展")) { FIFinderSyncController.showExtensionManagementInterface() }
                Button(L10n.text("检查并同步")) {
                    enabled = FIFinderSyncController.isExtensionEnabled
                    integration.publish()
                }
            }
            Text(integration.synchronized ? L10n.text("扩展已接收目录配置") : L10n.text("等待扩展接收配置；启用后可再次同步。"))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(integration.roots, id: \.self) { path in
                        HStack {
                            Text(path).font(.caption).textSelection(.enabled)
                            Spacer()
                            Button(L10n.text("停用")) { integration.remove(path) }
                        }
                    }
                }
            }
            Button(L10n.text("添加当前工作副本")) {
                if let root = model.workingCopy?.root { integration.add(root) }
            }.disabled(model.workingCopy == nil || model.isBusy)
            Text(L10n.text("上述副本显示菜单和本地状态角标；角标在 Mac SVN 运行期间刷新，绿色仅表示本地无修改。停用不会删除文件。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("菜单正常但角标未显示时，请检查其他访达扩展是否监控同一目录。"))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(badges.errors.keys.sorted(), id: \.self) { root in
                Text(L10n.text("角标状态读取失败：%@\n%@", root, badges.errors[root] ?? ""))
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            if let error = integration.error { Text(error).foregroundStyle(.red) }
        }
    }
}
