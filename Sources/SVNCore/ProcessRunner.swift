import Foundation
import Darwin

public struct CommandOutput: Sendable {
    public let stdoutData: Data
    public var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
    public let stderr: String
    public let exitCode: Int32
}

public struct SVNError: LocalizedError, Sendable {
    public let message: String
    public let diagnostic: String
    public let requiresAuthentication: Bool
    public let isInterruptedTransfer: Bool

    public init(_ message: String) {
        self.message = message
        self.diagnostic = message
        self.requiresAuthentication = false
        self.isInterruptedTransfer = false
    }

    /// 展示可操作的认证提示；XML 半成品仅保留在诊断输出中，不混入用户错误正文。
    public init(output: CommandOutput, xmlOutput: Bool) {
        diagnostic = "SVN 退出码 \(output.exitCode)\n\(output.stderr)\(output.stdout)"
        requiresAuthentication = output.stderr.contains("E170001:") || output.stderr.contains("E215004:")
        // 只依据 SVN 的错误流识别已知的响应截断，不从文件名或普通输出猜测。
        isInterruptedTransfer = !requiresAuthentication && output.stderr
            .components(separatedBy: .newlines)
            .contains { $0.hasPrefix("svn: E120106:") }
        let detail = xmlOutput ? output.stderr : output.stderr + output.stdout
        let reason = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = requiresAuthentication
            ? "仓库需要有效账号，或当前账号没有访问权限。请登录仓库后重试；密码仅保留在当前 App 会话中。"
            : "SVN 退出码 \(output.exitCode)"
        message = reason.isEmpty ? summary : "\(summary)\n\n\(reason)"
    }

    public var errorDescription: String? { message }
}

/// Process and cancellation state share a lock so cancellation cannot race process startup.
private final class ProcessExecution: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        if process.isRunning {
            process.interrupt()
        }
    }

    func execute(
        executable: URL,
        arguments: [String],
        directory: URL?,
        standardInput: Data?,
        onOutput: (@Sendable (String) -> Void)?
    ) throws -> CommandOutput {
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // GUI 启动时可能没有 UTF-8 locale，需与下方的 UTF-8 输出解码保持一致。
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        let input = standardInput == nil ? nil : Pipe()
        process.standardInput = input?.fileHandleForReading ?? FileHandle.nullDevice
        if let input {
            // 取消或启动参数错误时子进程可能提前关闭输入，避免 SIGPIPE 终止 App。
            guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
                throw SVNError("无法配置子进程输入管道。")
            }
        }
        process.standardOutput = stdout
        process.standardError = stderr

        lock.lock()
        if cancelled {
            lock.unlock()
            throw CancellationError()
        }
        do {
            try process.run()
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        input?.fileHandleForReading.closeFile()

        // Drain both pipes concurrently: SVN can fill stderr while stdout is being read.
        let errorData = DataBox()
        let inputError = InputErrorBox()
        let group = DispatchGroup()
        if let input, let standardInput {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer {
                    input.fileHandleForWriting.closeFile()
                    group.leave()
                }
                do {
                    try input.fileHandleForWriting.write(contentsOf: standardInput)
                } catch {
                    inputError.set(error)
                }
            }
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorData.set(Self.readOutput(stderr.fileHandleForReading, onOutput: onOutput))
            group.leave()
        }
        let outputData = Self.readOutput(stdout.fileHandleForReading, onOutput: onOutput)
        process.waitUntilExit()
        group.wait()

        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled {
            throw CancellationError()
        }
        // 子进程失败时保留它的原始错误；成功退出却未传入完整输入则明确报错。
        if process.terminationStatus == 0, let error = inputError.get() {
            throw SVNError("向子进程传递输入失败：\(error.localizedDescription)")
        }
        return CommandOutput(
            stdoutData: outputData,
            stderr: String(decoding: errorData.get(), as: UTF8.self),
            exitCode: process.terminationStatus
        )
    }

    /// 按完整行推送输出，保留跨管道读取边界的 UTF-8 字节，结束时补发末尾无换行的文本。
    private static func readOutput(
        _ handle: FileHandle,
        onOutput: (@Sendable (String) -> Void)?
    ) -> Data {
        guard let onOutput else {
            return handle.readDataToEndOfFile()
        }
        var allData = Data()
        var pending = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                break
            }
            allData.append(chunk)
            pending.append(chunk)
            if let newline = pending.lastIndex(of: 0x0A) {
                onOutput(String(decoding: pending[...newline], as: UTF8.self))
                pending.removeSubrange(...newline)
            }
        }
        if !pending.isEmpty {
            onOutput(String(decoding: pending, as: UTF8.self))
        }
        return allData
    }
}

private final class InputErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func set(_ value: Error) {
        lock.lock()
        defer { lock.unlock() }
        error = value
    }

    func get() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) {
        lock.lock()
        defer { lock.unlock() }
        data = value
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

public enum ProcessRunner {
    /// Arguments are passed directly to the executable, never through a shell.
    public static func run(
        executable: URL,
        arguments: [String],
        directory: URL? = nil,
        standardInput: Data? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandOutput {
        let execution = ProcessExecution()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try execution.execute(
                            executable: executable,
                            arguments: arguments,
                            directory: directory,
                            standardInput: standardInput,
                            onOutput: onOutput
                        ))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            execution.cancel()
        }
    }
}
