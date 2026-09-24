import Cocoa

extension Notification.Name {
    static let syncDidFinish = Notification.Name("ObsidianRemindersSyncDidFinish")
    static let syncDidStart  = Notification.Name("ObsidianRemindersSyncDidStart")
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    let engine = SyncEngine()
    private var watcher: FolderWatcher?
    private var pollTimer: Timer?
    private var remindersChangeWorkItem: DispatchWorkItem?
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var windowController: MainWindowController?

    private(set) var syncInProgress = false
    private(set) var lastStats: SyncStats?
    private(set) var lastError: String?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let started = Date()
        Log.info("=== Obsidian Reminders launched (pid \(ProcessInfo.processInfo.processIdentifier)) ===")
        Log.info("Vault: \(Settings.shared.vaultPath.isEmpty ? "<unset>" : Settings.shared.vaultPath)")
        Log.info("Target list: \(Settings.shared.listName)")

        setupStatusItem()
        reconcileLaunchAtLogin()

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleExternalChange),
            name: .EKEventStoreChanged, object: nil
        )

        // Kick the sync off before the window is built so the first run starts
        // working immediately; window construction happens on the next tick.
        ensureAccess { granted in
            if granted {
                self.startWatching()
                self.startPolling()
                self.syncNow(reason: "launch")
            } else {
                Log.error("Reminders access denied — open System Settings → Privacy & Security → Reminders")
                self.refreshStatusItem()
            }
        }

        DispatchQueue.main.async {
            self.showWindow(nil)
            Log.info("Window shown \(String(format: "%.2f", Date().timeIntervalSince(started)))s after launch")
        }
    }

    /// Coming back from System Settings: if access was just granted, start
    /// syncing without requiring a relaunch, and refresh the prompts either way.
    func applicationDidBecomeActive(_ notification: Notification) {
        if engine.isAuthorized && pollTimer == nil {
            Log.info("Reminders access is now granted — starting sync")
            startWatching()
            startPolling()
            syncNow(reason: "permission granted")
        }
        refreshStatusItem()
        NotificationCenter.default.post(name: .syncDidFinish, object: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Clicking the Dock icon should bring the window back whether it was closed
        // with ⌘W (ordered out) or tucked away with ⌘M (miniaturized).
        if let window = windowController?.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            if !window.isVisible { window.makeKeyAndOrderFront(nil) }
            NSApp.activate(ignoringOtherApps: true)
        } else if !flag {
            showWindow(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        watcher?.stop()
        pollTimer?.invalidate()
    }

    // MARK: - Permission

    private func ensureAccess(completion: @escaping (Bool) -> Void) {
        if engine.isAuthorized {
            Log.info("Reminders access already granted")
            completion(true)
            return
        }
        Log.info("Requesting Reminders access (status \(engine.authorizationStatus.rawValue))")
        engine.requestAccess { granted, error in
            if let error = error { Log.error("Access request error: \(error.localizedDescription)") }
            Log.info("Access request result: \(granted ? "granted" : "denied")")
            completion(granted)
        }
    }

    func requestAccessFromUI() {
        ensureAccess { granted in
            if granted {
                self.startWatching()
                self.startPolling()
                self.syncNow(reason: "permission granted")
            }
            self.refreshStatusItem()
        }
    }

    // MARK: - Watching & polling

    private func startWatching() {
        watcher?.stop()
        watcher = nil
        guard Settings.shared.watchEnabled else {
            Log.info("Real-time watching disabled in settings")
            return
        }
        let path = Settings.shared.vaultPath
        guard !path.isEmpty else { return }
        let watcher = FolderWatcher(path: path) { [weak self] in
            self?.syncNow(reason: "file change")
        }
        watcher.start()
        self.watcher = watcher
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let interval = TimeInterval(max(60, Settings.shared.pollSeconds))
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.syncNow(reason: "scheduled poll")
        }
        Log.info("Safety-net poll every \(Int(interval))s")
    }

    func restartWatching() {
        startWatching()
        startPolling()
    }

    // MARK: - Sync

    func syncNow(reason: String) {
        guard !syncInProgress else {
            Log.info("Sync requested (\(reason)) but one is already running")
            return
        }
        guard engine.isAuthorized else {
            Log.warn("Sync requested (\(reason)) without Reminders permission")
            lastError = L10n.t("Reminders permission not granted", "未获得「提醒事项」访问权限")
            NotificationCenter.default.post(name: .syncDidFinish, object: nil)
            refreshStatusItem()
            return
        }

        syncInProgress = true
        lastError = nil
        NotificationCenter.default.post(name: .syncDidStart, object: nil)
        refreshStatusItem()

        engine.sync { [weak self] stats in
            guard let self = self else { return }
            self.syncInProgress = false
            self.lastStats = stats
            self.lastError = stats.errors.first
            if !stats.errors.isEmpty {
                Log.warn("Sync finished with \(stats.errors.count) issue(s): \(stats.errors.joined(separator: " | "))")
            }
            self.refreshStatusItem()
            NotificationCenter.default.post(name: .syncDidFinish, object: nil)
        }
    }

    @objc private func handleExternalChange() {
        remindersChangeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.engine.importCompletedReminders { imported in
                if imported > 0 {
                    Log.info("Imported \(imported) reminder completion(s) into Obsidian")
                }
                // A native recurring reminder may expose its next occurrence
                // after the previous one is completed, even if there was no
                // Markdown completion to import. Reconcile that new instance.
                self.syncNow(reason: imported > 0 ? "reminder completion imported" : "reminder changed")
                NotificationCenter.default.post(name: .syncDidFinish, object: nil)
            }
        }
        remindersChangeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Obsidian Reminders")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        let status = NSMenuItem(title: L10n.t("Idle", "空闲"), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status

        menu.addItem(.separator())

        let sync = NSMenuItem(title: L10n.t("Sync Now", "立即同步"), action: #selector(syncFromMenu), keyEquivalent: "s")
        sync.target = self
        menu.addItem(sync)

        let open = NSMenuItem(title: L10n.t("Open Window…", "打开窗口…"), action: #selector(showWindow(_:)), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let log = NSMenuItem(title: L10n.t("View Full Log", "查看完整日志"), action: #selector(openLogFile), keyEquivalent: "l")
        log.target = self
        menu.addItem(log)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: L10n.t("Quit", "退出"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        refreshStatusItem()
    }

    @objc func syncFromMenu() { syncNow(reason: "menu") }

    func refreshStatusItem() {
        guard let status = statusMenuItem else { return }
        if syncInProgress {
            status.title = L10n.t("Syncing…", "正在同步…")
        } else if let error = lastError {
            status.title = "⚠︎ \(error)"
        } else if let stats = lastStats {
            status.title = L10n.t("Synced ", "已同步 ") + "\(Self.timeFormatter.string(from: Settings.shared.lastSyncDate ?? Date())) · \(stats.summary)"
        } else if !engine.isAuthorized {
            status.title = L10n.t("Reminders access needed", "需要授权访问提醒事项")
        } else {
            status.title = L10n.t("Waiting to sync", "待同步")
        }
        if let button = statusItem?.button {
            button.toolTip = status.title
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Window

    @objc func showWindow(_ sender: Any?) {
        if windowController == nil {
            windowController = MainWindowController(app: self)
        }
        windowController?.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openLogFile() {
        NSWorkspace.shared.open(URL(fileURLWithPath: Log.filePath))
    }

    // MARK: - Launch at login

    var launchAtLoginEnabled: Bool { LoginItem.isEnabled }

    /// Re-applies the login item if the user wants it but the registration is gone
    /// (which happens after every rebuild, since a new signature is a new bundle).
    private func reconcileLaunchAtLogin() {
        guard Settings.shared.wantLaunchAtLogin, !LoginItem.isEnabled else { return }
        Log.info("Re-registering launch at login (status \(LoginItem.statusDescription))")
        if let error = setLaunchAtLogin(true) {
            Log.warn("Could not re-register launch at login: \(error)")
        }
    }

    @discardableResult
    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        Settings.shared.wantLaunchAtLogin = enabled
        do {
            try LoginItem.setEnabled(enabled)
            Log.info("Launch at login \(enabled ? "enabled" : "disabled")")
            return nil
        } catch {
            let message = "\(error.localizedDescription)"
            Log.error("Launch at login \(enabled ? "enable" : "disable") failed: \(message)")
            return message
        }
    }
}
