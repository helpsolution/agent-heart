import Foundation
import CoreServices

/// Следит за деревом транскриптов через FSEvents. В простое не тратит CPU,
/// в отличие от опроса mtime у сотен файлов.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "agent-heart.fsevents")
    private let debounce: TimeInterval
    private var pending: DispatchWorkItem?
    private let onChange: () -> Void

    /// Claude Code дописывает транскрипты часто и мелкими порциями, поэтому
    /// схлопываем всплеск событий в один пересчёт.
    init(paths: [String], debounce: TimeInterval = 0.7, onChange: @escaping () -> Void) {
        self.debounce = debounce
        self.onChange = onChange
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().schedule()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3, flags
        ) else { return }

        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
    }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }

    deinit {
        pending?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
