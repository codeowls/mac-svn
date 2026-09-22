import Foundation
import Security
import Testing
@testable import SVNCore

struct SVNAuthenticationTests {
    @Test func scopesCredentialsByRepositoryAndPrefersTheClosestRoot() throws {
        var store = SVNAuthenticationStore()
        let parent = try SVNAuthentication(username: "parent", password: "test-only-parent")
        let child = try SVNAuthentication(username: "child", password: "test-only-child")
        store.set(parent, for: "https://example.test/svn/project")
        store.set(child, for: "https://example.test/svn/project/nested")
        #expect(store.authentication(for: "https://EXAMPLE.test:443/svn/project/trunk")?.username == "parent")
        #expect(store.authentication(for: "https://example.test/svn/project/nested/trunk")?.username == "child")
        for url in [
            "https://example.test/svn/project-other",
            "https://other.test/svn/project",
            "http://example.test/svn/project",
            "https://example.test:444/svn/project",
            "https://example.test/svn/project/%2e%2e/other",
            "https://someone@example.test/svn/project"
        ] {
            #expect(store.authentication(for: url) == nil)
        }
        store.remove(for: "https://example.test/svn/project/nested")
        #expect(store.roots == ["https://example.test/svn/project"])
        store.remove(for: "https://example.test/svn/project")
        #expect(store.authentication(for: "https://example.test/svn/project/trunk") == nil)
    }

    /// 使用随机服务名和生成的测试密码；只清理由本用例写入的两个钥匙串项目。
    @Test func keychainPersistsReplacesAndRemovesOnlyTheRequestedRepository() throws {
        let service = "io.github.codeowls.mac-svn.tests.\(UUID().uuidString)"
        let firstRoot = "svn://127.0.0.1:3690/first"
        let secondRoot = "svn://127.0.0.1:3690/second"
        let keychain = SVNKeychain(service: service)
        defer {
            do {
                try keychain.remove(for: firstRoot)
                try keychain.remove(for: secondRoot)
            } catch {
                Issue.record("Test keychain cleanup failed: \(error.localizedDescription)")
            }
        }
        let first = try SVNAuthentication(username: "first", password: "generated-test-\(UUID().uuidString)")
        let second = try SVNAuthentication(username: "second", password: "generated-test-\(UUID().uuidString)")
        #expect(try keychain.roots().isEmpty)
        try keychain.save(first, for: firstRoot)
        try keychain.save(second, for: secondRoot)
        let reopened = SVNKeychain(service: service)
        #expect(try reopened.roots() == [firstRoot, secondRoot])
        #expect(try reopened.authentication(for: firstRoot).password == first.password)
        let replacement = try SVNAuthentication(username: "replacement", password: "generated-new-test-password")
        try reopened.save(replacement, for: firstRoot)
        #expect(try keychain.authentication(for: firstRoot).username == "replacement")
        #expect(try keychain.authentication(for: firstRoot).password == replacement.password)
        try keychain.remove(for: firstRoot)
        #expect(try reopened.roots() == [secondRoot])
        #expect(try reopened.authentication(for: secondRoot).password == second.password)
        #expect(throws: SVNError.self) { try reopened.authentication(for: firstRoot) }
        try keychain.remove(for: firstRoot)
    }

    /// 损坏条目必须显式报错且不泄露内容；重新验证后保存可以修复原条目。
    @Test func rejectsCorruptCredentialsWithoutExposingTheirContentAndAllowsRepair() throws {
        let service = "io.github.codeowls.mac-svn.tests.\(UUID().uuidString)"
        let root = "svn://127.0.0.1:3690/corrupt-test"
        let keychain = SVNKeychain(service: service)
        defer {
            do {
                try keychain.remove(for: root)
            } catch {
                Issue.record("Test keychain cleanup failed: \(error.localizedDescription)")
            }
        }
        let authentication = try SVNAuthentication(username: "test-user", password: "test-only-secret")
        try keychain.save(authentication, for: root)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: root
        ]
        let invalidPayloads = [
            "invalid-json-test-only-secret",
            "{\"username\":\"test-user\",\"password\":42}",
            "{\"username\":\"\",\"password\":\"test-only-secret\"}",
            "{\"username\":\"test-user\",\"password\":\"\"}",
            "{\"username\":\"test-user\",\"password\":\"test-only-secret\\n\"}"
        ]
        for payload in invalidPayloads {
            let status = SecItemUpdate(
                query as CFDictionary,
                [kSecValueData as String: Data(payload.utf8)] as CFDictionary
            )
            try #require(status == errSecSuccess)
            #expect(try keychain.roots() == [root])
            do {
                _ = try keychain.authentication(for: root)
                Issue.record("A corrupt credential was accepted")
            } catch let error as SVNError {
                #expect(!error.localizedDescription.contains("test-only-secret"))
                #expect(!error.localizedDescription.contains(payload))
            }
        }
        try keychain.save(authentication, for: root)
        let restored = try SVNKeychain(service: service).authentication(for: root)
        #expect(restored.username == authentication.username)
        #expect(restored.password == authentication.password)
    }
}
