import AppKit
import FinderSync
import OSLog

@objc(MacSVNFinderSync)
final class MacSVNFinderSync: FIFinderSync {
    private let logger = Logger(subsystem: "io.github.codeowls.mac-svn.finder", category: "FinderSync")
    private var selection: [URL] = []
    private var configuration = FinderConfiguration(roots: [], language: "zh-Hans")
    private let actions = ["open", "commit", "update", "diff", "history"]

    override init() {
        super.init()
        if let saved = UserDefaults.standard.string(forKey: "finderConfiguration") {
            do {
                configuration = try FinderConfiguration.decode(saved)
            } catch {
                logger.error("Invalid saved Finder configuration: \(error.localizedDescription)")
            }
        }
        apply()
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(receiveConfiguration(_:)),
            name: FinderConfiguration.changed, object: nil
        )
        DistributedNotificationCenter.default().postNotificationName(
            FinderConfiguration.requested, object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    /// Persist in the extension's own container so menus survive host and Finder restarts.
    @objc private func receiveConfiguration(_ notification: Notification) {
        guard let value = notification.object as? String else { return }
        do {
            configuration = try FinderConfiguration.decode(value)
            UserDefaults.standard.set(value, forKey: "finderConfiguration")
            apply()
            DistributedNotificationCenter.default().postNotificationName(
                FinderConfiguration.applied, object: value, userInfo: nil, deliverImmediately: true
            )
        } catch {
            logger.error("Rejected Finder configuration: \(error.localizedDescription)")
        }
    }

    private func apply() {
        FIFinderSyncController.default().directoryURLs = Set(configuration.roots.map { URL(fileURLWithPath: $0) })
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let controller = FIFinderSyncController.default()
        switch menuKind {
        case .contextualMenuForItems:
            selection = controller.selectedItemURLs() ?? []
        case .contextualMenuForContainer, .contextualMenuForSidebar:
            selection = controller.targetedURL().map { [$0] } ?? []
        default:
            return nil
        }
        guard !selection.isEmpty else { return nil }
        let chinese = ["在 Mac SVN 中打开…", "提交所选项目…", "更新整个工作副本…", "查看差异…", "查看历史…"]
        let english = ["Open in Mac SVN…", "Commit Selected Items…", "Update Entire Working Copy…", "Show Diff…", "Show History…"]
        let titles = configuration.language == "en" ? english : chinese
        let submenu = NSMenu(title: "Mac SVN")
        for index in actions.indices {
            let item = NSMenuItem(title: titles[index], action: #selector(sendSelection(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = index < 3 || selection.count == 1
            submenu.addItem(item)
        }
        let menu = NSMenu(title: "Mac SVN")
        let parent = NSMenuItem(title: "Mac SVN", action: nil, keyEquivalent: "")
        parent.submenu = submenu
        menu.addItem(parent)
        return menu
    }

    /// Only send intent and paths; the host independently resolves and confirms operations.
    @objc private func sendSelection(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag), !selection.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "macsvn"
        components.host = "finder"
        components.queryItems = [URLQueryItem(name: "action", value: actions[sender.tag])]
            + selection.map { URLQueryItem(name: "path", value: $0.path) }
        guard let url = components.url else { return }
        let app = Bundle.main.bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { [logger] _, error in
            if let error {
                logger.error("Finder request failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
