import Foundation

public struct CommandOutput: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

public struct SVNError: LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
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

    func execute(executable: URL, arguments: [String], directory: URL?) throws -> CommandOutput {
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
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

        // Drain both pipes concurrently: SVN can fill stderr while stdout is being read.
        let errorData = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorData.set(stderr.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        group.wait()

        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled {
            throw CancellationError()
        }
        return CommandOutput(
            stdout: String(decoding: outputData, as: UTF8.self),
            stderr: String(decoding: errorData.get(), as: UTF8.self),
            exitCode: process.terminationStatus
        )
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
        directory: URL? = nil
    ) async throws -> CommandOutput {
        let execution = ProcessExecution()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try execution.execute(
                            executable: executable,
                            arguments: arguments,
                            directory: directory
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
