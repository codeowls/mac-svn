import Darwin
import Foundation
import Testing
@testable import SVNCore

@Suite("SVN 仓库认证")
struct AuthenticationTests {
    @Test func credentialsStayInsideAuthenticatedRepository() throws {
        var store = SVNAuthenticationStore()
        let writer = try SVNAuthentication(username: "writer", password: "local-test-password")
        let reader = try SVNAuthentication(username: "reader", password: "reader-test-password")
        store.set(writer, for: "svn://localhost:3690/project")
        store.set(reader, for: "svn://localhost:3690/other")
        #expect(store.authentication(for: "svn://localhost:3690/project/trunk")?.username == "writer")
        #expect(store.authentication(for: "svn://localhost:3690/project")?.username == "writer")
        #expect(store.authentication(for: "svn://localhost/project")?.username == "writer")
        #expect(store.authentication(for: "svn://localhost:3690/other")?.username == "reader")
        #expect(store.authentication(for: "svn://localhost:3690/project-two") == nil)
        #expect(store.authentication(for: "svn://another-host:3690/project") == nil)
        #expect(store.authentication(for: "svn://localhost:3691/project") == nil)
        #expect(store.authentication(for: "https://localhost:3690/project") == nil)
        #expect(store.authentication(for: "svn://localhost:3690/project/../other") == nil)
        #expect(store.authentication(for: "svn://localhost:3690/project/%2E%2E/other") == nil)
        store.set(writer, for: "https://example.test/project")
        #expect(store.authentication(for: "https://example.test:443/project/trunk")?.username == "writer")
        #expect(store.authentication(for: "https://example.test:8443/project") == nil)
    }

    @Test func rejectsCredentialsThatCannotUseSingleLineInput() {
        #expect(throws: SVNError.self) { try SVNAuthentication(username: " ", password: "password") }
        #expect(throws: SVNError.self) { try SVNAuthentication(username: "writer", password: "") }
        #expect(throws: SVNError.self) { try SVNAuthentication(username: "writer", password: "one\ntwo") }
    }

    @Test func standardInputDrainsOutputAndSurvivesEarlyExit() async throws {
        let data = Data(repeating: 65, count: 256 * 1024)
        let output = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "dd if=/dev/zero bs=65536 count=4 2>/dev/null; wc -c"],
            standardInput: data
        )
        #expect(output.exitCode == 0)
        #expect(output.stdout.hasSuffix("262144\n"))
        let rejected = try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 7"],
            standardInput: data
        )
        #expect(rejected.exitCode == 7)
    }

    @Test func authenticatedCheckoutCommitAndReadOnlyRejection() async throws {
        let fixture = try await AuthenticatedFixture.create()
        defer {
            fixture.server.terminate()
            fixture.server.waitUntilExit()
        }
        let anonymous = SVNClient(executable: fixture.executable)
        await #expect(throws: SVNError.self) {
            try await anonymous.repositoryLocation(fixture.repository)
        }
        let wrong = SVNClient(
            executable: fixture.executable,
            authentication: try SVNAuthentication(username: "writer", password: "wrong-password")
        )
        await #expect(throws: SVNError.self) {
            try await wrong.repositoryLocation(fixture.repository)
        }
        let writer = SVNClient(
            executable: fixture.executable,
            authentication: try SVNAuthentication(username: "writer", password: "本地 writer password")
        )
        let reader = SVNClient(
            executable: fixture.executable,
            authentication: try SVNAuthentication(username: "reader", password: "reader password")
        )
        let location = try await writer.repositoryLocation(fixture.repository)
        #expect(location.revision == "0")
        #expect(try await writer.listRepository(fixture.repository).isEmpty)
        let workingCopy = fixture.root.appendingPathComponent("writer-copy")
        let output = try await writer.checkout(repository: fixture.repository, destination: workingCopy)
        #expect(!output.contains("password"))
        let file = workingCopy.appendingPathComponent("中文文件.txt")
        try "authenticated content\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await writer.add(paths: ["中文文件.txt"], at: workingCopy)
        let committed = try await writer.commit(paths: ["中文文件.txt"], message: "Verify authenticated commit", at: workingCopy)
        #expect(!committed.contains("password"))
        let readerCopy = fixture.root.appendingPathComponent("reader-copy")
        _ = try await reader.checkout(repository: fixture.repository, destination: readerCopy)
        try "denied change\n".write(to: readerCopy.appendingPathComponent("中文文件.txt"), atomically: true, encoding: .utf8)
        await #expect(throws: SVNError.self) {
            try await reader.commit(paths: ["中文文件.txt"], message: "Reject read-only commit", at: readerCopy)
        }
        // 模拟重启后丢失 App 会话凭据：本地副本能打开，但历史不能匿名读取。
        #expect(try await anonymous.workingCopy(at: workingCopy).repositoryURL == location.url)
        do {
            _ = try await anonymous.history(at: workingCopy)
            Issue.record("未登录账号不应能读取私有仓库历史")
        } catch let error as SVNError {
            #expect(error.requiresAuthentication)
            #expect(!error.message.contains("<?xml"))
            #expect(error.diagnostic.contains("<log>"))
        }
        let writerHistory = try await writer.history(at: workingCopy)
        let readerHistory = try await reader.history(at: readerCopy)
        #expect(writerHistory.count == 1)
        #expect(readerHistory.first?.changedPaths.first?.path == "/中文文件.txt")
        #expect(readerHistory.first?.changedPaths.first?.action == "A")
        _ = try await writer.update(at: workingCopy)
        // 与首次登录相同的独立 realm 不应留下密码缓存；无凭据访问依旧失败。
        await #expect(throws: SVNError.self) {
            try await anonymous.repositoryLocation(fixture.repository)
        }
    }
}

private struct AuthenticatedFixture {
    let root: URL
    let executable: URL
    let repository: String
    let server: Process

    /// 每次建立独立 realm 和仅本机监听的仓库，不使用用户已有仓库或凭据。
    static func create() async throws -> AuthenticatedFixture {
        guard let executable = SVNClient.discoverExecutable() else {
            throw SVNError("认证测试需要安装 SVN 和 svnserve。")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-svn-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = root.appendingPathComponent("repository")
        let admin = executable.deletingLastPathComponent().appendingPathComponent("svnadmin")
        let result = try await ProcessRunner.run(executable: admin, arguments: ["create", repository.path])
        guard result.exitCode == 0 else {
            throw SVNError(result.stderr)
        }
        let conf = repository.appendingPathComponent("conf")
        try """
        [general]
        anon-access = none
        auth-access = write
        password-db = passwd
        authz-db = authz
        realm = Mac SVN Auth Test \(UUID().uuidString)
        """.write(to: conf.appendingPathComponent("svnserve.conf"), atomically: true, encoding: .utf8)
        let passwd = conf.appendingPathComponent("passwd")
        try "[users]\nwriter = 本地 writer password\nreader = reader password\n"
            .write(to: passwd, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: passwd.path)
        try "[/]\nwriter = rw\nreader = r\n* =\n"
            .write(to: conf.appendingPathComponent("authz"), atomically: true, encoding: .utf8)
        let port = try availablePort()
        let server = Process()
        server.executableURL = executable.deletingLastPathComponent().appendingPathComponent("svnserve")
        server.arguments = ["--daemon", "--foreground", "--listen-host", "127.0.0.1", "--listen-port", String(port), "--root", root.path]
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.standardError
        try server.run()
        do {
            for _ in 0..<100 {
                if isListening(port: port) {
                    return AuthenticatedFixture(root: root, executable: executable, repository: "svn://127.0.0.1:\(port)/repository", server: server)
                }
                guard server.isRunning else {
                    throw SVNError("认证测试服务器启动失败。")
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw SVNError("认证测试服务器启动超时。")
        } catch {
            if server.isRunning {
                server.terminate()
                server.waitUntilExit()
            }
            throw error
        }
    }

    private static func availablePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw SVNError("无法建立本地测试 socket。")
        }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard status == 0 else {
            throw SVNError("无法分配本地测试端口。")
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &size)
            }
        }
        guard nameStatus == 0 else {
            throw SVNError("无法读取本地测试端口。")
        }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func isListening(port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            return false
        }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
