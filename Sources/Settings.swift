import Foundation

/// User-facing configuration, persisted in UserDefaults.
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let vaultPath = "vaultPath"
        static let listName = "listName"
        static let ignoreFolders = "ignoreFolders"
        static let deleteOrphans = "deleteOrphans"
        static let syncCompleted = "syncCompleted"
        static let watchEnabled = "watchEnabled"
        static let pollSeconds = "pollSeconds"
        static let lastSync = "lastSync"
        static let didInitialSetup = "didInitialSetup"
        static let wantLaunchAtLogin = "wantLaunchAtLogin"
        static let includePaths = "includePaths"
        static let excludePaths = "excludePaths"
    }

    private init() {
        defaults.register(defaults: [
            Key.listName: "Obsidian",
            Key.ignoreFolders: ".obsidian,.trash,.git,node_modules",
            Key.deleteOrphans: true,
            Key.syncCompleted: false,
            Key.watchEnabled: true,
            Key.pollSeconds: 300,
            Key.wantLaunchAtLogin: true,
        ])

        // Probe only while no vault is known — afterwards the value comes
        // straight from UserDefaults, which keeps launch fast. An empty value is
        // retried so installing Obsidian later is picked up automatically.
        if (defaults.string(forKey: Key.vaultPath) ?? "").isEmpty {
            defaults.set(Settings.detectDefaultVault() ?? "", forKey: Key.vaultPath)
        }
    }

    var vaultPath: String {
        get { defaults.string(forKey: Key.vaultPath) ?? "" }
        set { defaults.set(newValue, forKey: Key.vaultPath) }
    }

    var listName: String {
        get { defaults.string(forKey: Key.listName) ?? "Obsidian" }
        set { defaults.set(newValue, forKey: Key.listName) }
    }

    /// Folder names skipped during the vault scan.
    var ignoreFolders: Set<String> {
        get {
            let raw = defaults.string(forKey: Key.ignoreFolders) ?? ""
            return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        }
        set { defaults.set(newValue.sorted().joined(separator: ","), forKey: Key.ignoreFolders) }
    }

    /// Remove reminders whose Obsidian task disappeared or lost its date.
    var deleteOrphans: Bool {
        get { defaults.bool(forKey: Key.deleteOrphans) }
        set { defaults.set(newValue, forKey: Key.deleteOrphans) }
    }

    /// Also mirror tasks that are already checked off in Obsidian.
    var syncCompleted: Bool {
        get { defaults.bool(forKey: Key.syncCompleted) }
        set { defaults.set(newValue, forKey: Key.syncCompleted) }
    }

    var watchEnabled: Bool {
        get { defaults.bool(forKey: Key.watchEnabled) }
        set { defaults.set(newValue, forKey: Key.watchEnabled) }
    }

    /// Safety-net full sync interval, in seconds.
    var pollSeconds: Int {
        get { defaults.integer(forKey: Key.pollSeconds) }
        set { defaults.set(newValue, forKey: Key.pollSeconds) }
    }

    /// Whitelist: vault-relative folders/files, separated by 、.
    var includePaths: String {
        get { defaults.string(forKey: Key.includePaths) ?? "" }
        set { defaults.set(newValue, forKey: Key.includePaths) }
    }

    /// Blacklist: vault-relative folders/files, separated by 、.
    var excludePaths: String {
        get { defaults.string(forKey: Key.excludePaths) ?? "" }
        set { defaults.set(newValue, forKey: Key.excludePaths) }
    }

    var pathFilter: PathFilter { PathFilter(includeText: includePaths, excludeText: excludePaths) }

    var lastSyncDate: Date? {
        get { defaults.object(forKey: Key.lastSync) as? Date }
        set { defaults.set(newValue, forKey: Key.lastSync) }
    }

    var didInitialSetup: Bool {
        get { defaults.bool(forKey: Key.didInitialSetup) }
        set { defaults.set(newValue, forKey: Key.didInitialSetup) }
    }

    /// The user's intent for "launch at login". Kept separately from the live
    /// SMAppService status so the registration can be re-applied after a rebuild
    /// (a new signature invalidates the previous login-item registration).
    var wantLaunchAtLogin: Bool {
        get { defaults.bool(forKey: Key.wantLaunchAtLogin) }
        set { defaults.set(newValue, forKey: Key.wantLaunchAtLogin) }
    }

    /// Finds the vault the user works in. Obsidian records every vault it has
    /// opened in its own config file; the currently open one (or else the most
    /// recently used one) wins. Falls back to a vault under ~/Documents/Obsidian.
    static func detectDefaultVault() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let config = home.appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        if let data = try? Data(contentsOf: config),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let vaults = object["vaults"] as? [String: [String: Any]] {
            let candidates = vaults.values.compactMap { entry -> (path: String, open: Bool, ts: Double)? in
                guard let path = entry["path"] as? String, isVault(path) else { return nil }
                return (path, entry["open"] as? Bool ?? false, (entry["ts"] as? NSNumber)?.doubleValue ?? 0)
            }
            if let best = candidates.max(by: { ($0.open ? 1 : 0, $0.ts) < ($1.open ? 1 : 0, $1.ts) }) {
                return best.path
            }
        }

        let root = home.appendingPathComponent("Documents/Obsidian", isDirectory: true)
        let entries = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return entries.map(\.path).first(where: isVault)
    }

    private static func isVault(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path + "/.obsidian", isDirectory: &isDir) && isDir.boolValue
    }
}
