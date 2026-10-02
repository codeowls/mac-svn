import AppKit
import FinderSync
import OSLog

/// 只缓存主应用返回的可见项目状态，角标请求回调不读取磁盘、不启动 SVN。
@MainActor
final class FinderBadgeController: NSObject {
    private let logger = Logger(subsystem: "io.github.codeowls.mac-svn.finder", category: "Badges")
    private var configuration = FinderConfiguration(roots: [], language: "zh-Hans")
    private var visible = Set<URL>()
    private var observed = Set<URL>()
    private var queued = Set<URL>()
    private var cache: [URL: (badge: FinderBadge?, scannedAt: Date)] = [:]
    private var pending: [UUID: (request: FinderBadgeRequest, sentAt: Date)] = [:]
    private var flushTask: Task<Void, Never>?
    private var timer: Timer?
    private var renewedAt = Date.distantPast

    override init() {
        super.init()
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(receive(_:)), name: FinderBadgeResponse.notification, object: nil)
        center.addObserver(self, selector: #selector(invalidated(_:)), name: FinderBadgeResponse.invalidated, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func configure(_ configuration: FinderConfiguration) {
        let rootsChanged = self.configuration.roots != configuration.roots
        self.configuration = configuration
        logger.info("Configured badge roots: \(configuration.roots.count, privacy: .public)")
        registerImages()
        if rootsChanged {
            for url in visible { FIFinderSyncController.default().setBadgeIdentifier("", for: url) }
            cache.removeAll()
            pending.removeAll()
        }
        for url in visible where location(url) == nil {
            FIFinderSyncController.default().setBadgeIdentifier("", for: url)
            cache.removeValue(forKey: url)
        }
        visible = visible.filter { location($0) != nil }
        observed = observed.filter { location($0) != nil }
        queued = queued.filter { location($0) != nil }
        pending = pending.filter { configuration.roots.contains($0.value.request.root) }
        enqueue(visible)
    }

    func beginObserving(_ url: URL) {
        observed.insert(url.standardizedFileURL)
    }

    func endObserving(_ url: URL) {
        observed.remove(url.standardizedFileURL)
        let removed = visible.filter { item in
            item.path.hasPrefix(url.standardizedFileURL.path + "/")
                && !observed.contains(item.deletingLastPathComponent())
        }
        visible.subtract(removed)
        queued.subtract(removed)
        for item in removed { cache.removeValue(forKey: item) }
    }

    func request(_ url: URL) {
        let url = url.standardizedFileURL
        guard location(url) != nil else { return }
        visible.insert(url)
        if let entry = cache[url], Date().timeIntervalSince(entry.scannedAt) < FinderBadgeResponse.lifetime {
            FIFinderSyncController.default().setBadgeIdentifier(entry.badge?.identifier ?? "", for: url)
        } else {
            FIFinderSyncController.default().setBadgeIdentifier("", for: url)
            enqueue([url])
        }
    }

    private func location(_ url: URL) -> (root: String, path: String)? {
        FinderBadgeRequest.location(for: url.path, roots: configuration.roots)
    }

    private func enqueue(_ urls: Set<URL>) {
        queued.formUnion(urls)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
                self?.flush()
            } catch is CancellationError {
                return
            } catch {
                self?.logger.error("Badge batching failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func flush() {
        flushTask = nil
        var grouped: [String: Set<String>] = [:]
        for url in queued {
            if let location = location(url) { grouped[location.root, default: []].insert(location.path) }
        }
        queued.removeAll()
        for (root, paths) in grouped {
            let paths = paths.sorted()
            for offset in stride(from: 0, to: paths.count, by: FinderBadgeRequest.batchSize) {
                let end = min(offset + FinderBadgeRequest.batchSize, paths.count)
                let request = FinderBadgeRequest(root: root, paths: Array(paths[offset..<end]))
                do {
                    let value = try request.encoded()
                    logger.debug("Requesting \(request.paths.count, privacy: .public) visible badges")
                    pending[request.id] = (request, Date())
                    DistributedNotificationCenter.default().postNotificationName(
                        FinderBadgeRequest.notification, object: value, userInfo: nil, deliverImmediately: true
                    )
                } catch {
                    logger.error("Badge request failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    @objc private func receive(_ notification: Notification) {
        guard let value = notification.object as? String else { return }
        do {
            let response = try FinderBadgeResponse.decode(value)
            guard let entry = pending.removeValue(forKey: response.requestID),
                  response.root == entry.request.root, response.isFresh(at: Date()),
                  Set(response.badges.keys).isSubset(of: Set(entry.request.paths)) else { return }
            let paths = Set(entry.request.paths)
            // 使用访达实际请求的 URL 回写角标，不能用主应用保存的路径别名重建 URL。
            for url in visible {
                guard let location = location(url), location.root == response.root,
                      paths.contains(location.path) else { continue }
                let badge = response.badges[location.path]
                cache[url] = (badge, response.scannedAt)
                FIFinderSyncController.default().setBadgeIdentifier(badge?.identifier ?? "", for: url)
            }
        } catch {
            logger.error("Rejected badge response: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func invalidated(_ notification: Notification) {
        guard let root = notification.object as? String, configuration.roots.contains(root) else { return }
        pending = pending.filter { $0.value.request.root != root }
        let affected = visible.filter { location($0)?.root == root }
        for url in affected {
            cache.removeValue(forKey: url)
            FIFinderSyncController.default().setBadgeIdentifier("", for: url)
        }
        enqueue(affected)
    }

    private func tick() {
        let now = Date()
        for (url, entry) in cache where now.timeIntervalSince(entry.scannedAt) >= FinderBadgeResponse.lifetime {
            cache.removeValue(forKey: url)
            FIFinderSyncController.default().setBadgeIdentifier("", for: url)
        }
        pending = pending.filter { now.timeIntervalSince($0.value.sentAt) < FinderBadgeResponse.lifetime }
        if now.timeIntervalSince(renewedAt) >= 10 {
            renewedAt = now
            enqueue(visible)
        }
    }

    private func registerImages() {
        let descriptions: [(FinderBadge, String, NSColor, String, String)] = [
            (.normal, "checkmark", .systemGreen, "本地无修改", "No local changes"),
            (.modified, "pencil", .systemOrange, "本地有修改或计划删除", "Locally modified or scheduled for deletion"),
            (.added, "plus", .systemBlue, "已安排新增", "Scheduled for addition"),
            (.conflicted, "exclamationmark", .systemRed, "冲突或异常状态", "Conflict or abnormal status"),
            (.unversioned, "questionmark", .systemGray, "未纳入版本控制", "Unversioned")
        ]
        for (badge, symbolName, color, chinese, english) in descriptions {
            let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 36, weight: .bold))?
                .withSymbolConfiguration(.init(paletteColors: [.white]))
            let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
                color.setFill()
                NSBezierPath(ovalIn: rect).fill()
                symbol?.draw(in: rect.insetBy(dx: 16, dy: 16))
                return true
            }
            // 扩展边界传递位图，避免延迟绘制的 NSCustomImageRep 无法被访达序列化。
            guard let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                logger.error("Unable to render badge image: \(badge.rawValue, privacy: .public)")
                continue
            }
            FIFinderSyncController.default().setBadgeImage(
                NSImage(cgImage: bitmap, size: image.size),
                label: configuration.language == "en" ? english : chinese, forBadgeIdentifier: badge.identifier
            )
        }
    }
}
