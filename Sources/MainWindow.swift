import SwiftUI
import AppKit
import Combine

/// Observable bridge between the AppKit delegate and the SwiftUI window.
final class UIState: ObservableObject {
    weak var app: AppDelegate?

    @Published var statusText: String = L10n.t("Starting…", "初始化…")
    @Published var lastSyncText: String = "—"
    @Published var syncing: Bool = false
    @Published var authorized: Bool = false
    @Published var accessBlocked: Bool = false
    @Published var hasReminderAccount: Bool = true
    @Published var obsidianInstalled: Bool = true
    @Published var logText: String = ""
    @Published var lists: [String] = []

    @Published var vaultPath: String = Settings.shared.vaultPath
    @Published var listName: String = Settings.shared.listName
    @Published var watch: Bool = Settings.shared.watchEnabled
    @Published var loginItem: Bool = false
    @Published var syncCompleted: Bool = Settings.shared.syncCompleted
    @Published var deleteOrphans: Bool = Settings.shared.deleteOrphans
    @Published var pollSeconds: Int = Settings.shared.pollSeconds
    @Published var includePaths: String = Settings.shared.includePaths
    @Published var excludePaths: String = Settings.shared.excludePaths

    @Published var banner: String?

    private var filterSyncWork: DispatchWorkItem?
    private var logRefreshPending = false
    private var observers: [NSObjectProtocol] = []

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .syncDidStart, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .syncDidFinish, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .logDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleLogRefresh()
        })
        refresh()
        refreshLog()
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func refresh() {
        guard let app = app else { return }
        syncing = app.syncInProgress
        authorized = app.engine.isAuthorized
        accessBlocked = app.engine.accessBlocked
        hasReminderAccount = app.engine.hasReminderAccount
        obsidianInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "md.obsidian") != nil
        loginItem = app.launchAtLoginEnabled

        if let error = app.lastError {
            statusText = "⚠︎ \(error)"
        } else if !authorized {
            statusText = L10n.t("No access to Reminders", "未获得「提醒事项」访问权限")
        } else if syncing {
            statusText = L10n.t("Syncing…", "正在同步…")
        } else if let stats = app.lastStats {
            statusText = L10n.t("OK · last run \(stats.summary) · \(stats.candidates) dated task(s)",
                                "正常 · 本次 \(stats.summary) · 候选任务 \(stats.candidates) 条")
        } else {
            statusText = L10n.t("Ready", "就绪")
        }

        if let date = Settings.shared.lastSyncDate {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            lastSyncText = f.string(from: date)
        }
    }

    private func scheduleLogRefresh() {
        guard !logRefreshPending else { return }
        logRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.logRefreshPending = false
            self?.refreshLog()
        }
    }

    func refreshLog() {
        let text = Log.snapshot()
        if text != logText { logText = text }
    }

    // MARK: - Actions

    func syncNow() { app?.syncNow(reason: "ui") }

    func requestAccess() {
        if app?.engine.accessBlocked == true { openRemindersPrivacySettings() } else { app?.requestAccessFromUI() }
    }

    func openRemindersPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
            NSWorkspace.shared.open(url)
        }
    }

    func openReminders() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func openObsidianWebsite() {
        if let url = URL(string: "https://obsidian.md/download") { NSWorkspace.shared.open(url) }
    }

    func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.t("Choose Vault", "选择 Vault")
        panel.message = L10n.t("Choose the Obsidian vault folder to sync", "选择要同步的 Obsidian Vault 文件夹")
        if !vaultPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: vaultPath) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vaultPath = url.path
        Settings.shared.vaultPath = url.path
        Settings.shared.didInitialSetup = true
        Log.info("Vault changed to \(url.path)")
        app?.restartWatching()
        app?.syncNow(reason: "vault changed")
    }

    func reloadLists() {
        lists = app?.engine.availableLists() ?? []
        if !lists.contains(listName) { lists.append(listName) }
    }

    func applyListName(_ name: String) {
        listName = name
        Settings.shared.listName = name
        Log.info("Target list changed to \(name)")
        app?.syncNow(reason: "list changed")
    }

    func setWatch(_ value: Bool) {
        watch = value
        Settings.shared.watchEnabled = value
        app?.restartWatching()
    }

    func setLoginItem(_ value: Bool) {
        if let error = app?.setLaunchAtLogin(value) {
            banner = L10n.t("Could not change Open at Login: ", "开机自启动设置失败：") + error
            loginItem = app?.launchAtLoginEnabled ?? false
        } else {
            banner = nil
            loginItem = app?.launchAtLoginEnabled ?? false
        }
    }

    func setSyncCompleted(_ value: Bool) {
        syncCompleted = value
        Settings.shared.syncCompleted = value
        app?.syncNow(reason: "setting changed")
    }

    func setDeleteOrphans(_ value: Bool) {
        deleteOrphans = value
        Settings.shared.deleteOrphans = value
        app?.syncNow(reason: "setting changed")
    }

    func setPollSeconds(_ value: Int) {
        pollSeconds = value
        Settings.shared.pollSeconds = value
        app?.restartWatching()
    }

    /// Saves a list as it is typed; the sync runs once typing pauses so every
    /// keystroke does not delete and recreate reminders.
    func setFilter(include: String? = nil, exclude: String? = nil) {
        if let include { includePaths = include; Settings.shared.includePaths = include }
        if let exclude { excludePaths = exclude; Settings.shared.excludePaths = exclude }
        filterSyncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Log.info("Path filter changed — whitelist: [\(Settings.shared.includePaths)] blacklist: [\(Settings.shared.excludePaths)]")
            self?.app?.syncNow(reason: "path filter changed")
        }
        filterSyncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Lets the user pick folders or notes inside the vault and appends them
    /// to a list as vault-relative paths.
    func addPaths(toWhitelist: Bool) {
        guard !vaultPath.isEmpty else {
            banner = L10n.t("Choose your vault first.", "请先选择 Vault。")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: vaultPath)
        panel.prompt = L10n.t("Add", "添加")
        panel.message = toWhitelist
            ? L10n.t("Only tasks in these folders/notes will be synced", "只同步这些文件夹／笔记中的任务")
            : L10n.t("Tasks in these folders/notes will not be synced", "这些文件夹／笔记中的任务不会被同步")
        guard panel.runModal() == .OK else { return }

        let root = URL(fileURLWithPath: vaultPath).standardizedFileURL.path + "/"
        var added: [String] = []
        var outside = false
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root) else { outside = true; continue }
            added.append(String(path.dropFirst(root.count)))
        }
        banner = outside ? L10n.t("Items outside the vault were ignored.", "Vault 以外的项目已忽略。") : nil
        guard !added.isEmpty else { return }
        let current = PathFilter.split(toWhitelist ? includePaths : excludePaths)
        let merged = PathFilter.join(current + added.filter { !current.contains($0) })
        if toWhitelist { setFilter(include: merged) } else { setFilter(exclude: merged) }
    }

    func openLog() { app?.openLogFile() }

    func clearLog() { Log.clear(); refreshLog() }
}

// MARK: - View

struct ContentView: View {
    @ObservedObject var state: UIState

    private let pollOptions: [(String, Int)] = [
        (L10n.t("Every 1 min", "每 1 分钟"), 60), (L10n.t("Every 5 min", "每 5 分钟"), 300),
        (L10n.t("Every 10 min", "每 10 分钟"), 600), (L10n.t("Every 30 min", "每 30 分钟"), 1800),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let banner = state.banner { bannerView(banner) }
            if state.vaultPath.isEmpty && !state.obsidianInstalled {
                bannerView(L10n.t("Obsidian is not installed. This app syncs tasks from Obsidian notes — install Obsidian and create a vault first. If your notes are already somewhere on this Mac, click \"Choose…\" below and pick that folder.",
                                  "未检测到 Obsidian。本工具同步的是 Obsidian 笔记里的任务，请先安装 Obsidian 并创建一个库；如果你的笔记已经在这台 Mac 上，也可以点下方「选择…」直接选中那个文件夹。"),
                           action: (L10n.t("Download Obsidian", "下载 Obsidian"), state.openObsidianWebsite))
            } else if state.vaultPath.isEmpty {
                bannerView(L10n.t("No Obsidian vault found. Click \"Choose…\" below and pick your vault folder (the one that contains a .obsidian folder).",
                                  "没有找到 Obsidian 库。请点击下方「选择…」，选中你的 Vault 文件夹（里面有 .obsidian 文件夹的那个）。"))
            }
            if state.accessBlocked {
                bannerView(L10n.t("Access to Reminders is turned off. Open System Settings → Privacy & Security → Reminders and switch on \"Obsidian Reminders\" (choose Full Access if asked).",
                                  "「提醒事项」访问权限被关闭了。请打开 系统设置 → 隐私与安全性 → 提醒事项，打开「Obsidian Reminders」的开关（如有选项请选「完全访问」）。"),
                           action: (L10n.t("Open System Settings", "打开系统设置"), state.openRemindersPrivacySettings))
            } else if state.authorized && !state.hasReminderAccount {
                bannerView(L10n.t("Reminders has no account to store lists in. Open the Reminders app and enable iCloud or \"On My Mac\" (Reminders → Settings → Accounts), then click Sync Now.",
                                  "「提醒事项」里没有可用的账户，无法创建列表。请打开「提醒事项」App，启用 iCloud 或「在我的 Mac 上」（提醒事项 → 设置 → 账户），然后点「立即同步」。"),
                           action: (L10n.t("Open Reminders", "打开提醒事项"), state.openReminders))
            }
            sourceSection
            filterSection
            optionsSection
            actionsSection
            logSection
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 740)
        .onAppear {
            state.reloadLists()
            state.refreshLog()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Obsidian Reminders")
                .font(.system(size: 20, weight: .semibold))
            HStack(spacing: 6) {
                Circle()
                    .fill(state.authorized ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(state.statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func bannerView(_ text: String, action: (String, () -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let action { Button(action.0, action: action.1) }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var sourceSection: some View {
        GroupBox(label: Text(L10n.t("Source", "来源")).font(.system(size: 12, weight: .semibold))) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Vault").frame(width: 92, alignment: .leading)
                    Text(state.vaultPath.isEmpty ? L10n.t("Not set", "未设置") : state.vaultPath)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(state.vaultPath.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button(L10n.t("Choose…", "选择…")) { state.chooseVault() }
                }
                HStack(spacing: 8) {
                    Text(L10n.t("Reminders list", "提醒列表")).frame(width: 92, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { state.listName },
                        set: { state.applyListName($0) }
                    )) {
                        ForEach(state.lists, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    Button(L10n.t("Refresh", "刷新")) { state.reloadLists() }
                    Spacer()
                }
                if !state.authorized {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill").foregroundStyle(.orange)
                        Text(L10n.t("Syncing needs access to Reminders.", "需要「提醒事项」访问权限才能同步。"))
                            .font(.system(size: 11))
                        Button(state.accessBlocked ? L10n.t("Open System Settings…", "打开系统设置…")
                                                   : L10n.t("Grant Access…", "授权…")) { state.requestAccess() }
                    }
                }
            }
            .padding(6)
        }
    }

    private var filterSection: some View {
        GroupBox(label: Text(L10n.t("Folders & notes", "同步范围")).font(.system(size: 12, weight: .semibold))) {
            VStack(alignment: .leading, spacing: 8) {
                filterRow(title: L10n.t("Whitelist", "白名单"),
                          placeholder: L10n.t("Only sync these, e.g. Projects、Daily/Today.md", "只同步这些，例如：工作、日记/今天.md"),
                          text: state.includePaths, whitelist: true)
                filterRow(title: L10n.t("Blacklist", "黑名单"),
                          placeholder: L10n.t("Never sync these, e.g. Archive、Templates", "不同步这些，例如：归档、模板"),
                          text: state.excludePaths, whitelist: false)
                Text(L10n.t("Vault-relative folders or notes, separated by 、 (commas also work). When the whitelist is not empty only the whitelist counts; an item in both lists is treated as blacklisted.", "填写 Vault 内的文件夹或笔记路径，用顿号「、」分隔。白名单不为空时只按白名单同步；两边都有的项按黑名单处理（不同步）。"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }

    private func filterRow(title: String, placeholder: String, text: String, whitelist: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 92, alignment: .leading)
            TextField(placeholder, text: Binding(
                get: { text },
                set: { whitelist ? state.setFilter(include: $0) : state.setFilter(exclude: $0) }
            ))
            .textFieldStyle(.roundedBorder)
            Button(L10n.t("Add…", "添加…")) { state.addPaths(toWhitelist: whitelist) }
        }
    }

    private var optionsSection: some View {
        GroupBox(label: Text(L10n.t("Options", "选项")).font(.system(size: 12, weight: .semibold))) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(L10n.t("Watch the vault (sync right after a note is saved)", "实时监听 Vault 变化（文件保存后自动同步）"),
                       isOn: Binding(get: { state.watch }, set: { state.setWatch($0) }))
                Toggle(L10n.t("Open at login", "开机自动启动"),
                       isOn: Binding(get: { state.loginItem }, set: { state.setLoginItem($0) }))
                Toggle(L10n.t("Also sync tasks already completed in Obsidian", "同时同步 Obsidian 中已完成的任务"),
                       isOn: Binding(get: { state.syncCompleted }, set: { state.setSyncCompleted($0) }))
                Toggle(L10n.t("Delete the reminder when its task is deleted or loses its date", "任务被删除或去掉日期后，删除对应的提醒"),
                       isOn: Binding(get: { state.deleteOrphans }, set: { state.setDeleteOrphans($0) }))
                HStack(spacing: 8) {
                    Text(L10n.t("Full sync", "兜底轮询"))
                    Picker("", selection: Binding(
                        get: { state.pollSeconds },
                        set: { state.setPollSeconds($0) }
                    )) {
                        ForEach(pollOptions, id: \.1) { Text($0.0).tag($0.1) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Text(L10n.t("(safety net for missed file events)", "（防止漏掉监听事件）"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    private var actionsSection: some View {
        HStack(spacing: 10) {
            Button {
                state.syncNow()
            } label: {
                HStack(spacing: 6) {
                    if state.syncing { ProgressView().controlSize(.small) }
                    Text(state.syncing ? L10n.t("Syncing…", "同步中…") : L10n.t("Sync Now", "立即同步"))
                }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(state.syncing)

            Button(L10n.t("View Full Log", "查看完整日志")) { state.openLog() }
            Spacer()
            Text(L10n.t("Last sync: ", "上次同步：") + state.lastSyncText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.t("Log", "日志")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(L10n.t("Clear", "清空")) { state.clearLog() }
                    .controlSize(.small)
            }
            ScrollView {
                Text(state.logText.isEmpty ? L10n.t("(no log yet)", "（暂无日志）") : state.logText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 80, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        }
    }
}

// MARK: - Window controller

final class MainWindowController: NSWindowController {

    private let state: UIState

    init(app: AppDelegate) {
        let state = UIState()
        state.app = app
        self.state = state

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Obsidian Reminders"
        window.contentView = NSHostingView(rootView: ContentView(state: state))
        window.minSize = NSSize(width: 680, height: 740)
        window.center()
        window.setFrameAutosaveName("MainWindow")

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        state.refresh()
        state.refreshLog()
        state.reloadLists()
    }
}

extension MainWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
