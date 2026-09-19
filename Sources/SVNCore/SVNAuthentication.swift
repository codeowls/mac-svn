import Foundation

public struct SVNAuthentication: Sendable {
    public let username: String
    public let password: String

    public init(username: String, password: String) throws {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty else {
            throw SVNError(L10n.text("请输入账号和密码。"))
        }
        guard !username.contains("\0"),
              !password.contains("\0"), !password.contains("\n"), !password.contains("\r") else {
            throw SVNError(L10n.text("账号不能包含空字符，密码不能包含空字符或换行。"))
        }
        self.username = username
        self.password = password
    }
}

/// 凭据只在已验证的仓库根路径内复用，不能发送给其他服务器或同服务器的其他仓库。
public struct SVNAuthenticationStore: Sendable {
    private var sessions: [String: SVNAuthentication] = [:]

    public init() {}

    public mutating func set(_ authentication: SVNAuthentication, for rootURL: String) {
        sessions[rootURL] = authentication
    }

    public func authentication(for repository: String) -> SVNAuthentication? {
        guard let target = URLComponents(string: repository) else {
            return nil
        }
        guard !target.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            return nil
        }
        let matchingRoot = sessions.keys.filter { root in
            guard let scope = URLComponents(string: root),
                  scope.scheme?.lowercased() == target.scheme?.lowercased(),
                  scope.host?.lowercased() == target.host?.lowercased(),
                  effectivePort(scope) == effectivePort(target),
                  scope.user == target.user else {
                return false
            }
            let path = scope.path.hasSuffix("/") ? String(scope.path.dropLast()) : scope.path
            return target.path == path || target.path.hasPrefix(path + "/")
        }.max { $0.count < $1.count }
        guard let matchingRoot else {
            return nil
        }
        return sessions[matchingRoot]
    }

    /// SVN 会在返回的规范地址中省略默认端口，显式写出的默认端口仍属于同一服务器。
    private func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port {
            return port
        }
        switch components.scheme?.lowercased() {
        case "svn":
            return 3690
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }
}
