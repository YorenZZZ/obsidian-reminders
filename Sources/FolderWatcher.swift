import Foundation
import CoreServices

/// Watches a directory tree with FSEvents and fires a debounced callback
/// whenever a markdown file changes.
final class FolderWatcher {

    private let path: String
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private let streamQueue = DispatchQueue(label: "io.github.yorenzzz.obsidian-reminders.fsevents")
    private let debounceQueue = DispatchQueue(label: "io.github.yorenzzz.obsidian-reminders.debounce")
    private var pending: DispatchWorkItem?
    private let debounceInterval: TimeInterval

    /// Path fragments that never warrant a sync.
    private var ignoredFragments: [String] {
        Settings.shared.ignoreFolders.map { "/\($0)/" } + ["/.obsidian/", "/.git/", "/.trash/"]
    }

    init(path: String, debounce: TimeInterval = 2.0, onChange: @escaping () -> Void) {
        self.path = path
        self.debounceInterval = debounce
        self.onChange = onChange
    }

    var isRunning: Bool { stream != nil }

    func start() {
        guard stream == nil else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            Log.warn("Watcher not started — path does not exist: \(path)")
            return
        }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info = info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            var relevant: [String] = []
            for i in 0..<count {
                relevant.append(String(cString: paths[i]))
            }
            watcher.handle(paths: relevant)
        }

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounceInterval,
            flags
        ) else {
            Log.error("FSEventStreamCreate failed for \(path)")
            return
        }

        FSEventStreamSetDispatchQueue(created, streamQueue)
        guard FSEventStreamStart(created) else {
            Log.error("FSEventStreamStart failed for \(path)")
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
        Log.info("Watching for changes: \(path)")
    }

    func stop() {
        guard let stream = stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        Log.info("Stopped watching \(path)")
    }

    private func handle(paths: [String]) {
        let relevant = paths.contains { candidate in
            guard candidate.lowercased().hasSuffix(".md") else { return false }
            return !ignoredFragments.contains { candidate.contains($0) }
        }
        guard relevant else { return }

        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            Log.info("Vault changed — syncing")
            self.onChange()
        }
        pending = work
        debounceQueue.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}
