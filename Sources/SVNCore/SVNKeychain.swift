import Foundation
import Security

/// 每个已验证仓库根地址对应一个本机钥匙串项目；账号和密码一起原子更新。
public struct SVNKeychain: Sendable {
    private let service: String

    public init(service: String = "io.github.codeowls.mac-svn.repository-password") {
        self.service = service
    }

    private struct Credential: Codable {
        let username: String
        let password: String
    }

    /// 只枚举根地址元数据，启动应用不会一次性读取所有仓库密码。
    public func roots() throws -> [String] {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        guard let records = result as? [[String: Any]] else {
            throw SVNError(L10n.text("无法读取已保存账号的仓库信息。"))
        }
        return try records.map { record in
            guard let root = record[kSecAttrAccount as String] as? String else {
                throw SVNError(L10n.text("无法读取已保存账号的仓库信息。"))
            }
            return root
        }.sorted()
    }

    public func authentication(for root: String) throws -> SVNAuthentication {
        var query = itemQuery(root)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        try check(SecItemCopyMatching(query as CFDictionary, &result))
        guard let data = result as? Data else {
            throw SVNError(L10n.text("钥匙串中的仓库凭据格式无效，请重新登录。"))
        }
        let credential: Credential
        do {
            credential = try JSONDecoder().decode(Credential.self, from: data)
        } catch {
            // 不把解码上下文或原始密码数据带入诊断。
            throw SVNError(L10n.text("钥匙串中的仓库凭据格式无效，请重新登录。"))
        }
        return try SVNAuthentication(username: credential.username, password: credential.password)
    }

    public func save(_ authentication: SVNAuthentication, for root: String) throws {
        let data = try JSONEncoder().encode(Credential(username: authentication.username, password: authentication.password))
        let query = itemQuery(root)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrLabel as String] = "Mac SVN · " + root
            try check(SecItemAdd(newItem as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    /// 仅删除本应用指定仓库的项目，不触碰系统 SVN 的认证缓存。
    public func remove(for root: String) throws {
        let status = SecItemDelete(itemQuery(root) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }

    private func itemQuery(_ root: String) -> [String: Any] {
        var query = baseQuery
        query[kSecAttrAccount as String] = root
        return query
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? String(status)
            throw SVNError(L10n.text("钥匙串操作失败（%@）：%@", status, message))
        }
    }
}
