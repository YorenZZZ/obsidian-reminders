import Foundation

/// Minimal file + in-memory logger. Thread-safe.
enum Log {
    private static let store = LogStore()

    static var filePath: String { store.fileURL.path }

    static func info(_ m: String)  { store.write("INFO ", m) }
    static func warn(_ m: String)  { store.write("WARN ", m) }
    static func error(_ m: String) { store.write("ERROR", m) }
    static func snapshot() -> String { store.snapshot() }
    static func clear() { store.clear() }
}

extension Notification.Name {
    static let logDidChange = Notification.Name("ObsidianRemindersLogDidChange")
}

private final class LogStore {
    let fileURL: URL
    private let queue = DispatchQueue(label: "io.github.yorenzzz.obsidian-reminders.log")
    private var recent: [String] = []
    private let maxRecent = 500
    private let formatter: DateFormatter

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/ObsidianReminders", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("app.log")

        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        // Keep the log from growing without bound.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int, size > 400_000,
           let data = try? Data(contentsOf: fileURL) {
            try? data.suffix(200_000).write(to: fileURL)
        }
    }

    func write(_ level: String, _ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(level) \(message)"
        queue.async {
            self.recent.append(line)
            if self.recent.count > self.maxRecent {
                self.recent.removeFirst(self.recent.count - self.maxRecent)
            }
            if let data = (line + "\n").data(using: .utf8),
               let handle = try? FileHandle(forWritingTo: self.fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .logDidChange, object: nil)
            }
        }
    }

    func snapshot() -> String { queue.sync { recent.joined(separator: "\n") } }
    func clear() { queue.async { self.recent.removeAll() } }
}
