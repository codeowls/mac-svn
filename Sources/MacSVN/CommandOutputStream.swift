import Foundation

/// 合并高频命令输出，每 100 毫秒交给界面一次；结束时先排空缓存，再结束流，不丢失尾部日志。
final class CommandOutputStream: @unchecked Sendable {
    let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private let timer: DispatchSourceTimer
    private var pending = ""

    init() {
        (stream, continuation) = AsyncStream<String>.makeStream()
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.flush() }
        timer.resume()
    }

    func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        pending += text
    }

    func finish() {
        lock.lock()
        defer { lock.unlock() }
        timer.cancel()
        flushLocked()
        continuation.finish()
    }

    private func flush() {
        lock.lock()
        defer { lock.unlock() }
        flushLocked()
    }

    private func flushLocked() {
        guard !pending.isEmpty else { return }
        continuation.yield(pending)
        pending = ""
    }

    deinit { timer.cancel() }
}
