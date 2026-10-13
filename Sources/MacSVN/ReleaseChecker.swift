import Foundation
import Combine
import SVNCore

struct AppVersion: Comparable {
    let components: [Int]

    init(_ value: String) throws {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ part in
            !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
                && (part.count == 1 || !part.hasPrefix("0")) && Int(part) != nil
        }) else { throw SVNError(L10n.text("无法识别版本号：%@", value)) }
        components = parts.map { Int($0)! }
    }

    static func < (left: AppVersion, right: AppVersion) -> Bool {
        left.components.lexicographicallyPrecedes(right.components)
    }
}

struct PublishedRelease: Decodable {
    let tag_name: String
    let html_url: URL
    let body: String?
    let published_at: Date
    let draft: Bool
    let prerelease: Bool
}

struct ReleaseCheckResult {
    let currentVersion: String
    let release: PublishedRelease
    let checkedAt: Date
    let comparison: ComparisonResult

    /// 只接受项目的正式发布页；错误响应不等价于“已是最新版本”。
    static func parse(currentVersion: String, data: Data, response: URLResponse) throws -> ReleaseCheckResult {
        guard let http = response as? HTTPURLResponse else {
            throw SVNError(L10n.text("版本检查未收到有效的服务器响应。"))
        }
        guard http.statusCode == 200 else {
            throw SVNError(L10n.text("版本检查失败（HTTP %@），请稍后重试。", http.statusCode))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(PublishedRelease.self, from: data)
        guard !release.draft, !release.prerelease,
              let url = URLComponents(url: release.html_url, resolvingAgainstBaseURL: false),
              url.scheme == "https", url.host?.lowercased() == "github.com",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.path == "/codeowls/mac-svn/releases/tag/" + release.tag_name else {
            throw SVNError(L10n.text("版本检查返回了无效的正式发布信息。"))
        }
        let current = try AppVersion(currentVersion)
        let tag = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        let latest = try AppVersion(tag)
        let comparison: ComparisonResult = current < latest ? .orderedAscending
            : (current == latest ? .orderedSame : .orderedDescending)
        return ReleaseCheckResult(currentVersion: currentVersion, release: release, checkedAt: Date(), comparison: comparison)
    }
}

@MainActor
final class ReleaseChecker: ObservableObject {
    enum State {
        case idle, checking
        case checked(ReleaseCheckResult)
        case failed(String)
    }

    nonisolated static let endpoint = URL(string: "https://api.github.com/repos/codeowls/mac-svn/releases/latest")!
    @Published private(set) var state = State.idle
    private let currentVersion: String?
    private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private var task: Task<Void, Never>?
    private var requestID = UUID()

    init(
        currentVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        fetch: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession(configuration: .ephemeral).data(for: request)
        }
    ) {
        self.currentVersion = currentVersion
        self.fetch = fetch
    }

    var isChecking: Bool {
        if case .checking = state { return true }
        return false
    }

    /// 仅在用户打开检查窗口或点击重试时请求公开版本元数据。
    func check() {
        guard !isChecking else { return }
        let id = UUID()
        requestID = id
        state = .checking
        task = Task {
            do {
                guard let currentVersion else { throw SVNError(L10n.text("应用缺少版本信息，请使用打包后的 Mac SVN.app。")) }
                _ = try AppVersion(currentVersion)
                var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
                request.setValue("MacSVN/" + currentVersion, forHTTPHeaderField: "User-Agent")
                request.httpShouldHandleCookies = false
                let (data, response) = try await fetch(request)
                try Task.checkCancellation()
                let result = try ReleaseCheckResult.parse(currentVersion: currentVersion, data: data, response: response)
                guard requestID == id else { return }
                state = .checked(result)
            } catch {
                guard requestID == id else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        requestID = UUID()
        task?.cancel()
        task = nil
        state = .idle
    }
}
