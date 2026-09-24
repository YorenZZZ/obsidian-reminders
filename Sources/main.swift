import Cocoa

// `--dry-run` scans the vault, applies the sync rules and prints the result
// without touching Reminders. No permission needed.
if CommandLine.arguments.contains("--dry-run") {
    let vault = Settings.shared.vaultPath
    guard !vault.isEmpty else {
        print("No vault configured. Run the app once and pick a vault.")
        exit(2)
    }
    let scan = VaultScanner.scan(vaultPath: vault)
    let partition = SyncEngine.partition(scan.tasks)
    SyncEngine.writeSnapshot(tasks: partition.wanted, stats: SyncStats(), scan: scan)

    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    print("Vault: \(vault)")
    print("Files scanned: \(scan.filesScanned)   tasks found: \(scan.tasks.count)   "
          + "scan time: \(String(format: "%.2f", scan.duration))s")
    print("Qualify for sync (📅/⏳): \(partition.wanted.count)   "
          + "completed & skipped: \(partition.completedUIDs.count)   "
          + "no date: \(scan.tasks.count - partition.wanted.count - partition.completedUIDs.count)")
    print(String(repeating: "-", count: 78))
    for task in partition.wanted.sorted(by: { $0.relativePath == $1.relativePath
        ? $0.lineNumber < $1.lineNumber : $0.relativePath < $1.relativePath }) {
        var dates = "📅\(task.dueDate.flatMap { c in c.date.map { f.string(from: $0) } } ?? "-")"
        dates += "  ⏳\(task.scheduledDate.flatMap { c in c.date.map { f.string(from: $0) } } ?? "-")"
        print("\(dates)  \(task.title)")
        print("        ← \(task.relativePath):\(task.lineNumber)")
    }
    if !scan.errors.isEmpty {
        print(String(repeating: "-", count: 78))
        print("errors:")
        scan.errors.prefix(10).forEach { print("  \($0)") }
    }
    exit(0)
}

// `--dump` prints what the last sync mirrored, then exits.
// It reads live data from Reminders when this binary holds the permission, and
// otherwise falls back to the snapshot the app wrote during its last run.
if CommandLine.arguments.contains("--dump") {
    let engine = SyncEngine()
    var lines: [String] = []
    var finished = false

    if engine.isAuthorized {
        engine.dumpManagedReminders { result in
            lines = result
            finished = true
        }
        let deadline = Date().addingTimeInterval(20)
        while !finished && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    if !finished {
        lines = ["(no live Reminders access from a command-line process — showing last snapshot)", ""]
        if let data = try? Data(contentsOf: SyncEngine.snapshotURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            lines.append("generatedAt: \(object["generatedAt"] ?? "?")")
            lines.append("vault: \(object["vault"] ?? "?")")
            lines.append("list: \(object["list"] ?? "?")")
            lines.append("files: \(object["filesScanned"] ?? "?")  tasks: \(object["tasksFound"] ?? "?")  "
                         + "mirrored: \(object["mirrored"] ?? "?")")
            lines.append(String(repeating: "-", count: 72))
            for item in (object["items"] as? [[String: Any]]) ?? [] {
                let due = item["due"] as? String ?? "-"
                let sched = item["scheduled"] as? String ?? "-"
                let flag = (item["completed"] as? Bool) == true ? "✓" : "·"
                lines.append("\(flag) 📅\(due)  ⏳\(sched)  \(item["title"] ?? "")")
                lines.append("      ← \(item["source"] ?? "")")
            }
        } else {
            lines.append("No snapshot yet at \(SyncEngine.snapshotURL.path)")
        }
    }

    print("List: \(Settings.shared.listName)   vault: \(Settings.shared.vaultPath)")
    print(String(repeating: "-", count: 72))
    lines.forEach { print($0) }
    exit(0)
}

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.regular)

// Minimal main menu so ⌘Q / ⌘W behave as expected.
let mainMenu = NSMenu()

let appMenuItem = NSMenuItem()
let appMenu = NSMenu()
appMenu.addItem(withTitle: L10n.t("About Obsidian Reminders", "关于 Obsidian Reminders"),
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: "")
appMenu.addItem(.separator())

let showItem = NSMenuItem(title: L10n.t("Show Window", "显示主窗口"), action: #selector(AppDelegate.showWindow(_:)), keyEquivalent: "1")
showItem.target = appDelegate
appMenu.addItem(showItem)

let syncItem = NSMenuItem(title: L10n.t("Sync Now", "立即同步"), action: #selector(AppDelegate.syncFromMenu), keyEquivalent: "r")
syncItem.target = appDelegate
appMenu.addItem(syncItem)

appMenu.addItem(.separator())
appMenu.addItem(withTitle: L10n.t("Hide Obsidian Reminders", "隐藏"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
appMenu.addItem(.separator())
appMenu.addItem(withTitle: L10n.t("Quit Obsidian Reminders", "退出"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

appMenuItem.submenu = appMenu
mainMenu.addItem(appMenuItem)

// File menu — ⌘W closes (i.e. hides) the window without quitting the app.
let fileMenuItem = NSMenuItem()
let fileMenu = NSMenu(title: L10n.t("File", "文件"))
fileMenu.addItem(
    withTitle: L10n.t("Close Window", "关闭窗口"),
    action: #selector(NSWindow.performClose(_:)),
    keyEquivalent: "w"
)
fileMenuItem.submenu = fileMenu
mainMenu.addItem(fileMenuItem)

let editMenuItem = NSMenuItem()
let editMenu = NSMenu(title: L10n.t("Edit", "编辑"))
editMenu.addItem(withTitle: L10n.t("Undo", "撤销"), action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: L10n.t("Redo", "重做"), action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(.separator())
editMenu.addItem(withTitle: L10n.t("Cut", "剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: L10n.t("Copy", "拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: L10n.t("Paste", "粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: L10n.t("Select All", "全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editMenuItem.submenu = editMenu
mainMenu.addItem(editMenuItem)

// Window menu — ⌘M minimizes, and macOS keeps the window list here.
let windowMenuItem = NSMenuItem()
let windowMenu = NSMenu(title: L10n.t("Window", "窗口"))
windowMenu.addItem(
    withTitle: L10n.t("Minimize", "最小化"),
    action: #selector(NSWindow.performMiniaturize(_:)),
    keyEquivalent: "m"
)
windowMenu.addItem(
    withTitle: L10n.t("Zoom", "缩放"),
    action: #selector(NSWindow.performZoom(_:)),
    keyEquivalent: ""
)
windowMenu.addItem(.separator())
windowMenu.addItem(
    withTitle: L10n.t("Bring All to Front", "全部置于顶层"),
    action: #selector(NSApplication.arrangeInFront(_:)),
    keyEquivalent: ""
)
windowMenuItem.submenu = windowMenu
mainMenu.addItem(windowMenuItem)

application.mainMenu = mainMenu
application.windowsMenu = windowMenu

// `--dump-menu` prints the menu tree and exits — handy for checking shortcuts
// without clicking through the UI.
if CommandLine.arguments.contains("--dump-menu") {
    func walk(_ menu: NSMenu, _ depth: Int) {
        for item in menu.items {
            let key = item.keyEquivalent.isEmpty
                ? ""
                : "   ⌘\(item.keyEquivalent.uppercased())"
            print(String(repeating: "  ", count: depth) + "- \(item.title)\(key)")
            if let submenu = item.submenu { walk(submenu, depth + 1) }
        }
    }
    walk(mainMenu, 0)
    exit(0)
}

application.run()
