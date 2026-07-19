import CoreServices
import Foundation

final class FolderWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "de.r3d.rawviewer.folder-watcher")
    private let onChange: @Sendable ([String]) -> Void
    private var stream: FSEventStreamRef?
    private var pendingWork: DispatchWorkItem?
    private var pendingPaths: Set<String> = []

    init(onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange
    }

    func start(path: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
                watcher.scheduleChange(Array(paths.prefix(count)))
            }
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents |
                kFSEventStreamCreateFlagWatchRoot |
                kFSEventStreamCreateFlagUseCFTypes
            )
            guard let stream = FSEventStreamCreate(
                nil,
                callback,
                &context,
                [path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.3,
                flags
            ) else { return }

            self.stream = stream
            FSEventStreamSetDispatchQueue(stream, self.queue)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    private func scheduleChange(_ paths: [String]) {
        pendingPaths.formUnion(paths)
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let paths = Array(self.pendingPaths)
            self.pendingPaths.removeAll()
            self.onChange(paths)
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func stopOnQueue() {
        pendingWork?.cancel()
        pendingWork = nil
        pendingPaths.removeAll()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
