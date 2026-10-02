import Foundation

/// 角标表示本地状态；normal 不表示与服务器 HEAD 一致。
public enum FinderBadge: String, Codable, CaseIterable, Sendable {
    case normal, unversioned, added, modified, conflicted

    public var identifier: String { "macsvn." + rawValue }

    public var priority: Int {
        switch self {
        case .normal: 0
        case .unversioned: 1
        case .added: 2
        case .modified: 3
        case .conflicted: 4
        }
    }
}

/// 每次请求只包含一小批可见项目；通知不传递凭据、文件内容或写操作授权。
public struct FinderBadgeRequest: Codable, Sendable {
    public static let notification = Notification.Name("io.github.codeowls.mac-svn.finder.request-badges")
    public static let batchSize = 128
    public let id: UUID
    public let root: String
    public let paths: [String]

    public init(root: String, paths: [String]) {
        id = UUID()
        self.root = root
        self.paths = paths
    }

    public func encoded() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    public static func decode(_ value: String) throws -> Self {
        let request = try JSONDecoder().decode(Self.self, from: Data(value.utf8))
        guard request.root.hasPrefix("/"), !request.root.contains("\0"),
              !request.paths.isEmpty, request.paths.count <= batchSize,
              request.paths.allSatisfy(validPath) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return request
    }

    public static func validPath(_ path: String) -> Bool {
        if path == "." { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/") && !path.contains("\0")
            && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." || $0.lowercased() == ".svn" }
    }

    /// Foundation 保存短路径，而访达可能回传 /private 别名；匹配过程不访问磁盘。
    public static func location(for path: String, roots: [String]) -> (root: String, path: String)? {
        func comparable(_ path: String) -> String {
            for directory in ["tmp", "var", "etc"] {
                let prefix = "/private/" + directory
                if path == prefix || path.hasPrefix(prefix + "/") {
                    return String(path.dropFirst("/private".count))
                }
            }
            return path
        }
        let path = comparable(path)
        guard let root = roots.filter({ path == comparable($0) || path.hasPrefix(comparable($0) + "/") })
            .max(by: { comparable($0).count < comparable($1).count }) else { return nil }
        let base = comparable(root)
        let relative = path == base ? "." : String(path.dropFirst(base.count + 1))
        return validPath(relative) ? (root, relative) : nil
    }

    /// 目录观察使用系统链接的物理路径，与访达产生的项目 URL 保持一致。
    public static func monitoringPath(for root: String) -> String {
        for directory in ["tmp", "var", "etc"] {
            let prefix = "/" + directory
            if root == prefix || root.hasPrefix(prefix + "/") { return "/private" + root }
        }
        return root
    }
}

public struct FinderBadgeResponse: Codable, Sendable {
    public static let notification = Notification.Name("io.github.codeowls.mac-svn.finder.badges")
    public static let invalidated = Notification.Name("io.github.codeowls.mac-svn.finder.invalidate-badges")
    public static let lifetime: TimeInterval = 20
    public let requestID: UUID
    public let root: String
    public let scannedAt: Date
    public let badges: [String: FinderBadge]

    public init(request: FinderBadgeRequest, scannedAt: Date, badges: [String: FinderBadge]) {
        requestID = request.id
        root = request.root
        self.scannedAt = scannedAt
        self.badges = badges
    }

    public func encoded() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    public static func decode(_ value: String) throws -> Self {
        let response = try JSONDecoder().decode(Self.self, from: Data(value.utf8))
        guard response.root.hasPrefix("/"), response.badges.count <= FinderBadgeRequest.batchSize,
              response.badges.keys.allSatisfy(FinderBadgeRequest.validPath) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return response
    }

    public func isFresh(at date: Date) -> Bool {
        let age = date.timeIntervalSince(scannedAt)
        return age >= 0 && age < Self.lifetime
    }
}
