import Foundation

/// Walks an Obsidian vault and collects every markdown task line.
enum VaultScanner {

    private static let maxFileSize = 8 * 1024 * 1024

    struct ScanResult {
        var tasks: [ObsidianTask] = []
        var filesScanned = 0
        var filesSkipped = 0
        var errors: [String] = []
        var duration: TimeInterval = 0
    }

    static func scan(vaultPath: String) -> ScanResult {
        let started = Date()
        var result = ScanResult()
        let fm = FileManager.default
        let root = URL(fileURLWithPath: vaultPath)
        let ignore = Settings.shared.ignoreFolders
        let filter = Settings.shared.pathFilter

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: vaultPath, isDirectory: &isDir), isDir.boolValue else {
            result.errors.append("Vault not found: \(vaultPath)")
            return result
        }

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, error in
                result.errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
                return true
            }
        ) else {
            result.errors.append("Cannot enumerate vault: \(vaultPath)")
            return result
        }

        // Phase 1 — collect candidate files.
        var files: [(url: URL, relativePath: String)] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])

            if values?.isDirectory == true {
                if ignore.contains(url.lastPathComponent) || url.lastPathComponent.hasPrefix(".") {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true, url.pathExtension.lowercased() == "md" else { continue }

            if let size = values?.fileSize, size > maxFileSize {
                result.filesSkipped += 1
                continue
            }
            let relativePath = relative(url.path, from: root)
            guard filter.allows(relativePath) else {
                result.filesSkipped += 1
                continue
            }
            files.append((url, relativePath))
        }

        // Phase 2 — parse in parallel; each iteration writes its own slot.
        var perFile = [[ObsidianTask]](repeating: [], count: files.count)
        let lock = NSLock()
        var skipped = 0

        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            let file = files[index]
            guard let data = try? Data(contentsOf: file.url),
                  let content = String(data: data, encoding: .utf8) else {
                lock.lock(); skipped += 1; lock.unlock()
                return
            }
            // Cheap pre-check: most notes contain no tasks at all.
            guard content.contains("- [") || content.contains("* [") || content.contains("+ [") else { return }

            var found: [ObsidianTask] = []
            var lineNumber = 0
            for line in TaskParser.lines(of: content) {
                lineNumber += 1
                guard line.contains("[") else { continue }
                if let task = TaskParser.parse(
                    line: String(line),
                    absolutePath: file.url.path,
                    relativePath: file.relativePath,
                    lineNumber: lineNumber
                ) {
                    found.append(task)
                }
            }
            perFile[index] = found
        }

        result.tasks = perFile.flatMap { $0 }
        result.filesScanned = files.count
        result.filesSkipped += skipped
        result.duration = Date().timeIntervalSince(started)
        return result
    }

    private static func relative(_ path: String, from root: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
