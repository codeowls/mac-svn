import CoreServices
import Foundation

/// 一个注册副本对应一个事件流；包括 .svn 元数据变化，回调只负责使缓存失效。
@MainActor
final class FinderBadgeWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void

    init(root: String, onChange: @escaping @MainActor () -> Void) throws {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagFileEvents)
        guard let stream = FSEventStreamCreate(
            nil, { _, context, _, _, _, _ in
                guard let context else { return }
                MainActor.assumeIsolated {
                    Unmanaged<FinderBadgeWatcher>.fromOpaque(context).takeUnretainedValue().onChange()
                }
            }, &context, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags
        ) else {
            throw CocoaError(.fileReadUnknown)
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            stop()
            throw CocoaError(.fileReadNoPermission)
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
