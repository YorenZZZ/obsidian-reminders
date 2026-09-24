import Foundation
import EventKit

struct SyncStats {
    var created = 0
    var updated = 0
    var adopted = 0
    var completed = 0
    var deleted = 0
    var unchanged = 0
    var skipped = 0
    var candidates = 0
    var scannedFiles = 0
    var errors: [String] = []

    var summary: String {
        var parts: [String] = []
        if created > 0 { parts.append("+\(created)") }
        if updated > 0 { parts.append("~\(updated)") }
        if adopted > 0 { parts.append("↩\(adopted)") }
        if completed > 0 { parts.append("✓\(completed)") }
        if deleted > 0 { parts.append("−\(deleted)") }
        if parts.isEmpty { parts.append(L10n.t("no change", "无变化")) }
        return parts.joined(separator: " ")
    }
}

/// Bidirectional completion sync between Obsidian tasks and Reminders.
///
/// Only tasks carrying a due (📅) or scheduled (⏳) date are mirrored, and the
/// reminder shows nothing but the task text — no notes, no links, no paths.
/// Which reminders belong to this tool is tracked in `ReminderIndex` rather than
/// stamped into the reminder itself.
final class SyncEngine {

    private let store = EKEventStore()
    private let queue = DispatchQueue(label: "io.github.yorenzzz.obsidian-reminders.sync")
    private var syncing = false

    // MARK: - Authorization

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    var isAuthorized: Bool { authorizationStatus == .fullAccess }

    /// Access was refused (or only write access granted). macOS will not ask
    /// again, so the user has to switch it on in System Settings.
    var accessBlocked: Bool {
        switch authorizationStatus {
        case .denied, .restricted, .writeOnly: return true
        default: return false
        }
    }

    /// False when Reminders has no account that can hold a list — neither
    /// iCloud nor "On My Mac" is enabled. Only meaningful once authorized.
    var hasReminderAccount: Bool {
        guard isAuthorized else { return true }
        return store.defaultCalendarForNewReminders() != nil
            || !store.calendars(for: .reminder).isEmpty
    }

    func requestAccess(completion: @escaping (Bool, Error?) -> Void) {
        store.requestFullAccessToReminders { granted, error in
            DispatchQueue.main.async { completion(granted, error) }
        }
    }

    /// Imports completed Reminders back into their originating Obsidian tasks.
    func importCompletedReminders(completion: @escaping (Int) -> Void) {
        guard isAuthorized else { DispatchQueue.main.async { completion(0) }; return }
        let settings = Settings.shared
        guard !settings.vaultPath.isEmpty,
              let list = reminderList(named: settings.listName, createIfMissing: false) else {
            DispatchQueue.main.async { completion(0) }
            return
        }
        queue.async {
            let scan = VaultScanner.scan(vaultPath: settings.vaultPath)
            let index = ReminderIndex.shared
            self.store.fetchReminders(matching: self.store.predicateForReminders(in: [list])) { reminders in
                let result = Self.importCompleted(reminders ?? [], tasks: scan.tasks, index: index)
                DispatchQueue.main.async { completion(result.imported) }
            }
        }
    }

    private struct CompletionImportResult {
        var imported = 0
        /// Tasks whose reminder is checked but whose Markdown line could not be
        /// updated. Their reminders are held as-is until the import succeeds.
        var unresolved: [String: String] = [:] // uid -> title
    }

    /// Import only currently open, dated tasks. Recurring history in the same
    /// file shares the UID, so indexing every task can select an older completed
    /// occurrence and silently ignore the current one.
    private static func importCompleted(_ reminders: [EKReminder],
                                        tasks: [ObsidianTask],
                                        index: ReminderIndex) -> CompletionImportResult {
        let tasksByUID = TaskParser.openDatedTasksByUID(tasks)

        var result = CompletionImportResult()
        for reminder in reminders where reminder.isCompleted {
            // Completing a native recurring reminder does not complete the
            // indexed series item: Reminders advances that item in place and
            // creates a separate completed history item with a new ID. Match
            // that history only to its already-owned series (same title and
            // creation date), never to an arbitrary completed reminder.
            let uid = index.uid(forIdentifier: reminder.calendarItemIdentifier)
                ?? reminders.first(where: { series in
                    guard !series.isCompleted,
                          series.recurrenceRules?.isEmpty == false,
                          series.title == reminder.title,
                          index.uid(forIdentifier: series.calendarItemIdentifier) != nil,
                          let seriesCreated = series.creationDate,
                          let historyCreated = reminder.creationDate,
                          abs(seriesCreated.timeIntervalSince(historyCreated)) < 1 else { return false }
                    return !sameDate(series.dueDateComponents, reminder.dueDateComponents)
                }).flatMap { index.uid(forIdentifier: $0.calendarItemIdentifier) }
            guard let uid,
                  let task = tasksByUID[uid] else { continue }
            guard sameDate(reminder.dueDateComponents, task.effectiveDue) else { continue }
            if let previous = index.lastSyncedCompletion(for: uid) {
                if previous { continue }
            } else if let modified = reminder.lastModifiedDate,
                      let attributes = try? FileManager.default.attributesOfItem(atPath: task.absolutePath),
                      let fileModified = attributes[.modificationDate] as? Date,
                      fileModified > modified {
                continue
            }
            do {
                if try TaskParser.markCompleted(task) {
                    result.imported += 1
                    index.setSyncedCompletion(true, for: uid)
                    index.save()
                    Log.info("Imported completion: \(task.title)")
                } else {
                    result.unresolved[uid] = task.title
                    Log.warn("Could not locate unchanged source line for completed reminder: \(task.title)")
                }
            } catch {
                result.unresolved[uid] = task.title
                Log.error("Could not mark Obsidian task complete for \(task.title): \(error.localizedDescription)")
            }
        }
        return result
    }

    // MARK: - Entry point

    func sync(completion: @escaping (SyncStats) -> Void) {
        var busy = false
        queue.sync { busy = syncing; if !busy { syncing = true } }
        if busy {
            Log.info("Sync already running — skipped duplicate trigger")
            DispatchQueue.main.async { completion(SyncStats()) }
            return
        }

        run { stats in
            self.queue.sync { self.syncing = false }
            DispatchQueue.main.async { completion(stats) }
        }
    }

    private func run(completion: @escaping (SyncStats) -> Void) {
        var stats = SyncStats()
        let settings = Settings.shared
        let vault = settings.vaultPath

        guard !vault.isEmpty else {
            stats.errors.append(L10n.t("No vault selected — choose your Obsidian vault", "尚未选择 Vault，请先选择你的 Obsidian 库"))
            Log.error("Sync aborted: vault path is empty")
            return completion(stats)
        }

        guard isAuthorized else {
            stats.errors.append(L10n.t("No permission to access Reminders", "未获得「提醒事项」访问权限"))
            Log.error("Sync aborted: Reminders permission not granted")
            return completion(stats)
        }

        let scan = VaultScanner.scan(vaultPath: vault)
        stats.scannedFiles = scan.filesScanned
        stats.errors.append(contentsOf: scan.errors.prefix(5))

        // Partition tasks.
        let partition = Self.partition(scan.tasks)
        let wanted = partition.wanted
        let completedTasks = partition.completedUIDs
        var wantedByUID: [String: ObsidianTask] = [:]
        for task in wanted { wantedByUID[task.uid] = task }
        stats.candidates = wanted.count
        stats.skipped = scan.tasks.count - wanted.count

        guard let list = reminderList(named: settings.listName, createIfMissing: true) else {
            stats.errors.append(L10n.t(
                "Cannot open or create the Reminders list \"\(settings.listName)\". Enable an account (iCloud or On My Mac) in the Reminders app.",
                "无法打开或创建提醒列表「\(settings.listName)」。请在「提醒事项」App 中启用一个账户（iCloud 或「在我的 Mac 上」）。"))
            Log.error("Sync aborted: reminder list unavailable")
            return completion(stats)
        }

        let predicate = store.predicateForReminders(in: [list])
        store.fetchReminders(matching: predicate) { reminders in
            let all = reminders ?? []
            let index = ReminderIndex.shared

            // Completion import must run before applying the Obsidian → Reminders
            // direction. This makes a periodic sync safe even when macOS delays or
            // omits EKEventStoreChanged: a checked reminder is never overwritten
            // back to unchecked before its Markdown task is updated.
            //
            // A successful import rewrote Markdown, so this scan is stale: stop
            // here and let the file change trigger a fresh pass. A completion that
            // cannot be imported only holds its own reminder — it must not stall
            // syncing for every other task.
            let importResult = Self.importCompleted(all, tasks: scan.tasks, index: index)
            if importResult.imported > 0 {
                Log.info("Reminder completions imported:\(importResult.imported) unresolved:\(importResult.unresolved.count); deferring normal sync")
                return completion(stats)
            }
            let held = Set(importResult.unresolved.keys)
            for title in importResult.unresolved.values.sorted() {
                stats.errors.append(L10n.t("Completed in Reminders but could not update Obsidian: ", "已在提醒事项完成，但无法回写 Obsidian：") + title)
            }

            Self.writeListState(all)

            // Honour an explicit purge request first — exact identifiers only, so the
            // blast radius is always something a human chose.
            let purged = Self.performPurge(all, store: self.store, stats: &stats)
            let existing = all.filter { !purged.contains($0.calendarItemIdentifier) }

            // 1. Precise match — reminders this tool created, remembered in the index.
            var byUID: [String: EKReminder] = [:]
            for reminder in existing {
                if let uid = index.uid(forIdentifier: reminder.calendarItemIdentifier) {
                    byUID[uid] = reminder
                }
            }

            // 2. Adoption — a reminder that matches a wanted task by title + date but
            //    isn't indexed yet: first run, a rebuilt index, or an entry written by
            //    an older version. Claim it rather than creating a duplicate.
            var unclaimed = existing.filter { index.uid(forIdentifier: $0.calendarItemIdentifier) == nil }
            var waitingForNativeOccurrence: Set<String> = []
            for (uid, task) in wantedByUID {
                guard let previous = byUID[uid],
                      !task.isCompleted,
                      previous.recurrenceRules?.isEmpty == false,
                      !Self.sameDate(previous.dueDateComponents, task.effectiveDue) else { continue }

                if previous.isCompleted {
                    let previousExternal = previous.calendarItemExternalIdentifier
                    let expectedRule = NativeRecurrence.fingerprint(previous.recurrenceRules?.first)
                    if let position = unclaimed.firstIndex(where: { candidate in
                        guard !candidate.isCompleted, candidate.title == task.title else { return false }
                        if let previousExternal, !previousExternal.isEmpty,
                           candidate.calendarItemExternalIdentifier == previousExternal { return true }
                        return Self.sameDate(candidate.dueDateComponents, task.effectiveDue)
                            && NativeRecurrence.fingerprint(candidate.recurrenceRules?.first) == expectedRule
                    }) {
                        let successor = unclaimed.remove(at: position)
                        byUID[uid] = successor
                        stats.adopted += 1
                        Log.info("Adopted native recurring occurrence: \(task.title)")
                    } else {
                        waitingForNativeOccurrence.insert(uid)
                        Log.info("Waiting for Reminders to expose next occurrence: \(task.title)")
                    }
                } else if let finished = scan.tasks.first(where: {
                    $0.uid == uid && $0.isCompleted
                        && Self.sameDate($0.effectiveDue, previous.dueDateComponents)
                }) {
                    // Obsidian Tasks generated its next row first. Complete the
                    // old native occurrence so Reminders generates its own next
                    // row, which the next pass will adopt instead of duplicating.
                    previous.isCompleted = true
                    if let doneDate = finished.doneDate { previous.completionDate = doneDate }
                    do {
                        try self.store.save(previous, commit: false)
                        stats.completed += 1
                        waitingForNativeOccurrence.insert(uid)
                        Log.info("Advanced native recurrence after Obsidian completion: \(task.title)")
                    } catch {
                        stats.errors.append("advance recurring \"\(task.title)\": \(error.localizedDescription)")
                    }
                }
            }
            for (uid, task) in wantedByUID where byUID[uid] == nil {
                guard let position = unclaimed.firstIndex(where: {
                    $0.title == task.title && Self.sameDate($0.dueDateComponents, task.effectiveDue)
                }) else { continue }
                let reminder = unclaimed.remove(at: position)
                byUID[uid] = reminder
                stats.adopted += 1
                Log.info("Adopted existing reminder \"\(task.title)\"")
            }

            // 3. Create / update, recording the final uid → reminder mapping.
            var finalMap: [String: EKReminder] = [:]
            for (uid, task) in wantedByUID {
                if held.contains(uid) {
                    // Leave the checked reminder alone; applying the still-open
                    // task would silently undo the user's completion.
                    if let reminder = byUID[uid] { finalMap[uid] = reminder }
                    byUID.removeValue(forKey: uid)
                    continue
                }
                if waitingForNativeOccurrence.contains(uid), let reminder = byUID[uid] {
                    finalMap[uid] = reminder
                    index.setSyncedCompletion(true, for: uid)
                    byUID.removeValue(forKey: uid)
                    continue
                }
                if let reminder = byUID[uid] {
                    if self.apply(task: task, to: reminder, list: list, index: index) {
                        // Mutating an EKReminder only touches the in-memory object —
                        // without this save the change is silently dropped.
                        do {
                            try self.store.save(reminder, commit: false)
                            Self.recordMetadata(task: task, index: index)
                            stats.updated += 1
                        } catch {
                            stats.errors.append("update \"\(task.title)\": \(error.localizedDescription)")
                            Log.error("save() failed for \"\(task.title)\": \(error)")
                        }
                    } else {
                        Self.recordMetadata(task: task, index: index)
                        stats.unchanged += 1
                    }
                    finalMap[uid] = reminder
                    index.setSyncedCompletion(task.isCompleted, for: uid)
                    byUID.removeValue(forKey: uid)
                } else {
                    let reminder = EKReminder(eventStore: self.store)
                    reminder.calendar = list
                    _ = self.apply(task: task, to: reminder, list: list, index: index, isNew: true)
                    do {
                        try self.store.save(reminder, commit: false)
                        Self.recordMetadata(task: task, index: index)
                        finalMap[uid] = reminder
                        index.setSyncedCompletion(task.isCompleted, for: uid)
                        stats.created += 1
                    } catch {
                        stats.errors.append("create \"\(task.title)\": \(error.localizedDescription)")
                        Log.error("save() failed for \"\(task.title)\": \(error)")
                    }
                }
            }

            // 4. Whatever is left in byUID is a reminder this tool owns but whose task
            //    is gone from the vault, lost its date, or was completed in Obsidian.
            //
            //    Safety valve: if the vault scan produced nothing at all, that almost
            //    certainly means a wrong/unreadable vault path rather than "the user
            //    deleted everything" — never mass-delete in that case.
            let allowCleanup = !wanted.isEmpty || byUID.isEmpty
            if allowCleanup {
                for (uid, reminder) in byUID {
                    if completedTasks.contains(uid) {
                        if !reminder.isCompleted {
                            do {
                                reminder.isCompleted = true
                                if let finished = scan.tasks.first(where: {
                                    $0.uid == uid && $0.isCompleted
                                        && Self.sameDate($0.effectiveDue, reminder.dueDateComponents)
                                }), let doneDate = finished.doneDate {
                                    reminder.completionDate = doneDate
                                }
                                try self.store.save(reminder, commit: false)
                                stats.completed += 1
                            } catch {
                                stats.errors.append("cleanup \"\(reminder.title ?? "")\": \(error.localizedDescription)")
                                Log.error("cleanup failed: \(error)")
                            }
                        }
                        // Keep the ownership link so reopening it cannot duplicate it.
                        finalMap[uid] = reminder
                        index.setSyncedCompletion(true, for: uid)
                        continue
                    }
                    guard !reminder.isCompleted else { continue }
                    do {
                        if settings.deleteOrphans {
                            try self.store.remove(reminder, commit: false)
                            stats.deleted += 1
                        } else {
                            reminder.isCompleted = true
                            try self.store.save(reminder, commit: false)
                            stats.completed += 1
                        }
                    } catch {
                        stats.errors.append("cleanup \"\(reminder.title ?? "")\": \(error.localizedDescription)")
                        Log.error("cleanup failed: \(error)")
                    }
                }
            } else {
                let message = "Vault produced no dated tasks — skipped cleanup of \(byUID.count) reminder(s). Check the vault path."
                stats.errors.append(message)
                Log.warn(message)
            }

            // 5. Persist.
            do {
                try self.store.commit()
            } catch {
                stats.errors.append("Save failed: \(error.localizedDescription)")
                Log.error("commit() failed: \(error)")
            }

            // 6. Rebuild the index from the final state — identifiers are only final
            //    once the changes are committed.
            index.removeAll()
            for (uid, reminder) in finalMap {
                let identifier = reminder.calendarItemIdentifier
                if !identifier.isEmpty { index.set(uid: uid, identifier: identifier) }
            }
            index.pruneMetadata()
            index.save()

            Settings.shared.lastSyncDate = Date()
            Self.writeSnapshot(tasks: wanted, stats: stats, scan: scan)
            Log.info("Sync done — files:\(stats.scannedFiles) tasks:\(scan.tasks.count) "
                     + "candidates:\(stats.candidates) created:\(stats.created) updated:\(stats.updated) "
                     + "adopted:\(stats.adopted) completed:\(stats.completed) deleted:\(stats.deleted) "
                     + "unchanged:\(stats.unchanged) index:\(index.count) "
                     + "in \(String(format: "%.2f", scan.duration))s")
            completion(stats)
        }
    }

    // MARK: - Reminder <-> task

    /// Applies task state to a reminder. Returns true when something actually changed.
    ///
    /// Notes and links written by older versions are cleared;
    /// anything the user typed themselves is left alone.
    @discardableResult
    private func apply(task: ObsidianTask, to reminder: EKReminder, list: EKCalendar,
                       index: ReminderIndex, isNew: Bool = false) -> Bool {
        var changed = isNew
        var reasons: [String] = []

        if reminder.title != task.title {
            reasons.append("title[\(reminder.title ?? "<nil>")]→[\(task.title)]")
            reminder.title = task.title
            changed = true
        }

        if reminder.calendar?.calendarIdentifier != list.calendarIdentifier {
            reasons.append("calendar")
            reminder.calendar = list
            changed = true
        }

        let due = task.effectiveDue
        if !Self.sameDate(reminder.dueDateComponents, due) {
            reasons.append("due[\(Self.describe(reminder.dueDateComponents))]→[\(Self.describe(due))]")
            reminder.dueDateComponents = due
            changed = true
        }

        // 🛫 is the true start date. Otherwise ⏳ can occupy Reminder's start
        // slot when 📅 supplies the due date.
        let start: DateComponents? = task.startDate ?? ((task.dueDate != nil) ? task.scheduledDate : nil)
        if !Self.sameDate(reminder.startDateComponents, start) {
            reasons.append("start[\(Self.describe(reminder.startDateComponents))]→[\(Self.describe(start))]")
            reminder.startDateComponents = start
            changed = true
        }

        if reminder.isCompleted != task.isCompleted {
            reasons.append("completed")
            reminder.isCompleted = task.isCompleted
            changed = true
        }
        if task.isCompleted, let doneDate = task.doneDate,
           !Self.sameDay(reminder.completionDate, doneDate) {
            reasons.append("completion date")
            reminder.completionDate = doneDate
            changed = true
        }

        if let priority = task.priority {
            if reminder.priority != priority {
                reasons.append("priority[\(reminder.priority)]→[\(priority)]")
                reminder.priority = priority
                changed = true
            }
        } else if let owned = index.lastSyncedPriority(for: task.uid), reminder.priority == owned {
            reasons.append("priority removed")
            reminder.priority = 0
            changed = true
        }

        let desiredRule = NativeRecurrence.rule(for: task)
        let currentRule = reminder.recurrenceRules?.first
        let desiredSignature = NativeRecurrence.fingerprint(desiredRule)
        let currentSignature = NativeRecurrence.fingerprint(currentRule)
        if let desiredRule, desiredSignature != currentSignature {
            reasons.append("recurrence[\(currentSignature ?? "none")]→[\(desiredSignature ?? "none")]")
            reminder.recurrenceRules = [desiredRule]
            changed = true
        } else if desiredRule == nil,
                  let owned = index.lastSyncedRecurrence(for: task.uid),
                  currentSignature == owned {
            reasons.append("recurrence removed")
            reminder.recurrenceRules = nil
            changed = true
        }

        let oldAlarm = index.lastSyncedAlarm(for: task.uid)
        let desiredAlarm = task.alertDate.map(Self.alarmSignature)
        var alarms = reminder.alarms ?? []
        let oldCount = alarms.count
        if let oldAlarm, oldAlarm != desiredAlarm {
            alarms.removeAll { $0.absoluteDate.map(Self.alarmSignature) == oldAlarm }
        }
        if let date = task.alertDate,
           !alarms.contains(where: { $0.absoluteDate.map(Self.alarmSignature) == desiredAlarm }) {
            alarms.append(EKAlarm(absoluteDate: date))
        }
        if alarms.count != oldCount || oldAlarm != desiredAlarm && oldAlarm != nil {
            reminder.alarms = alarms.isEmpty ? nil : alarms
            reasons.append("alarm")
            changed = true
        }

        // Strip the bookkeeping older versions left behind. Only our own markers are
        // removed — a note the user wrote by hand stays.
        if let notes = reminder.notes, notes.contains("oruid:") || notes.contains("obsidian://") {
            reasons.append("notes[\(notes.prefix(24))]")
            reminder.notes = nil
            changed = true
        }
        if let url = reminder.url, url.absoluteString.hasPrefix("obsidian://") {
            reasons.append("url")
            reminder.url = nil
            changed = true
        }

        if !reasons.isEmpty && !isNew {
            Log.info("Δ \(task.title.prefix(24)) ← \(reasons.joined(separator: " | "))")
        }

        return changed
    }

    private static func describe(_ c: DateComponents?) -> String {
        guard let c = c else { return "nil" }
        let y = c.year.map(String.init) ?? "-"
        let m = c.month.map(String.init) ?? "-"
        let d = c.day.map(String.init) ?? "-"
        let time = c.hour.map { String(format: " %02d:%02d", $0, c.minute ?? 0) } ?? ""
        return "\(y)-\(m)-\(d)\(time) tz=\(c.timeZone?.identifier ?? "-")"
    }

    private static func alarmSignature(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func sameDay(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return Calendar.current.isDate(a, inSameDayAs: b)
    }

    private static func recordMetadata(task: ObsidianTask, index: ReminderIndex) {
        index.setSyncedRecurrence(NativeRecurrence.fingerprint(NativeRecurrence.rule(for: task)), for: task.uid)
        index.setSyncedPriority(task.priority, for: task.uid)
        index.setSyncedAlarm(task.alertDate.map(alarmSignature), for: task.uid)
    }

    /// EventKit hands back DateComponents that may carry extra fields (era, weekOfYear,
    /// a different calendar identifier…), so a plain `==` would report a change on every
    /// run and rewrite every reminder. Compare the calendar day only.
    private static func sameDate(_ a: DateComponents?, _ b: DateComponents?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (lhs?, rhs?):
            return lhs.year == rhs.year && lhs.month == rhs.month && lhs.day == rhs.day
                && (lhs.hour ?? 0) == (rhs.hour ?? 0) && (lhs.minute ?? 0) == (rhs.minute ?? 0)
        default: return false
        }
    }

    // MARK: - Task selection

    struct Partition {
        var wanted: [ObsidianTask]
        var completedUIDs: Set<String>
    }

    /// Decides which vault tasks get mirrored.
    ///
    /// Only tasks carrying a due (📅) or scheduled (⏳) date qualify. Tasks already
    /// checked off in Obsidian are skipped by default — but their uid is reported so
    /// an existing reminder can be closed out instead of lingering.
    static func partition(_ tasks: [ObsidianTask]) -> Partition {
        var wanted: [ObsidianTask] = []
        var completed: Set<String> = []
        let includeCompleted = Settings.shared.syncCompleted
        let openUIDs = Set(tasks.filter { $0.hasDueOrScheduled && !$0.isCompleted }.map(\.uid))

        for task in tasks where task.hasDueOrScheduled {
            if task.isCompleted {
                if openUIDs.contains(task.uid) { continue }
                if includeCompleted { wanted.append(task) } else { completed.insert(task.uid) }
            } else {
                wanted.append(task)
            }
        }
        return Partition(wanted: wanted, completedUIDs: completed)
    }

    // MARK: - Snapshot

    /// Writes a human-readable record of what this run mirrored, so the result can
    /// be inspected without opening the Reminders app.
    static var snapshotURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ObsidianReminders", isDirectory: true)
            .appendingPathComponent("last-sync.json")
    }

    /// Full contents of the target list, written on every sync so the list can be
    /// inspected without opening Reminders (a command-line process has no TCC access).
    static var listStateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ObsidianReminders", isDirectory: true)
            .appendingPathComponent("list-state.json")
    }

    /// Drop a JSON array of reminder identifiers here and the next sync removes
    /// exactly those reminders — nothing else. The file is renamed to `.done`
    /// afterwards so the purge runs once.
    static var purgeRequestURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ObsidianReminders", isDirectory: true)
            .appendingPathComponent("purge-request.json")
    }

    /// Removes exactly the reminders named in `purge-request.json`, then archives the
    /// request as `.done`. Returns the identifiers that were actually removed.
    private static func performPurge(_ reminders: [EKReminder],
                                     store: EKEventStore,
                                     stats: inout SyncStats) -> Set<String> {
        guard let data = try? Data(contentsOf: purgeRequestURL),
              let ids = try? JSONSerialization.jsonObject(with: data) as? [String],
              !ids.isEmpty else { return [] }

        let targets = Set(ids)
        var removed: Set<String> = []
        for reminder in reminders where targets.contains(reminder.calendarItemIdentifier) {
            do {
                try store.remove(reminder, commit: false)
                removed.insert(reminder.calendarItemIdentifier)
                Log.info("Purged: \(reminder.title ?? "<untitled>")")
            } catch {
                stats.errors.append("purge \"\(reminder.title ?? "")\": \(error.localizedDescription)")
                Log.error("purge failed for \"\(reminder.title ?? "")\": \(error)")
            }
        }
        do {
            try store.commit()
        } catch {
            stats.errors.append("purge commit: \(error.localizedDescription)")
        }
        stats.deleted += removed.count
        try? FileManager.default.moveItem(at: purgeRequestURL, to: purgeRequestURL.appendingPathExtension("done"))
        Log.info("Purge request processed — removed \(removed.count) of \(targets.count) requested reminder(s)")
        return removed
    }

    private static func writeListState(_ reminders: [EKReminder]) {
        let iso = ISO8601DateFormatter()
        let index = ReminderIndex.shared

        let items: [[String: Any]] = reminders.map { reminder in
            var item: [String: Any] = [
                "identifier": reminder.calendarItemIdentifier,
                "title": reminder.title ?? "",
                "completed": reminder.isCompleted,
                "managed": index.uid(forIdentifier: reminder.calendarItemIdentifier) != nil,
            ]
            if let due = dateString(reminder.dueDateComponents) { item["due"] = due }
            if let start = dateString(reminder.startDateComponents) { item["start"] = start }
            if reminder.priority != 0 { item["priority"] = reminder.priority }
            if let recurrence = NativeRecurrence.fingerprint(reminder.recurrenceRules?.first) {
                item["recurrence"] = recurrence
            }
            let alarmDates = (reminder.alarms ?? []).compactMap { $0.absoluteDate.map(iso.string) }
            if !alarmDates.isEmpty { item["alarms"] = alarmDates }
            if let notes = reminder.notes, !notes.isEmpty { item["notes"] = notes }
            if let url = reminder.url?.absoluteString { item["url"] = url }
            if let created = reminder.creationDate { item["createdAt"] = iso.string(from: created) }
            if let modified = reminder.lastModifiedDate { item["modifiedAt"] = iso.string(from: modified) }
            return item
        }.sorted { ($0["title"] as? String ?? "") < ($1["title"] as? String ?? "") }

        let payload: [String: Any] = [
            "generatedAt": iso.string(from: Date()),
            "list": Settings.shared.listName,
            "total": items.count,
            "managed": items.filter { ($0["managed"] as? Bool) == true }.count,
            "items": items,
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        try? data.write(to: listStateURL)
    }

    private static func dateString(_ c: DateComponents?) -> String? {
        guard let c = c, let y = c.year, let m = c.month, let d = c.day else { return nil }
        let date = String(format: "%04d-%02d-%02d", y, m, d)
        if let hour = c.hour, let minute = c.minute, hour != 0 || minute != 0 {
            return date + String(format: " %02d:%02d", hour, minute)
        }
        return date
    }

    static func writeSnapshot(tasks: [ObsidianTask], stats: SyncStats, scan: VaultScanner.ScanResult) {
        let dir = snapshotURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let iso = ISO8601DateFormatter()
        let items: [[String: Any]] = tasks
            .sorted { $0.relativePath == $1.relativePath ? $0.lineNumber < $1.lineNumber : $0.relativePath < $1.relativePath }
            .map { task in
                var item: [String: Any] = [
                    "title": task.title,
                    "completed": task.isCompleted,
                    "source": task.relativePath,
                    "line": task.lineNumber,
                    "uid": task.uid,
                ]
                if let due = dateString(task.dueDate) { item["due"] = due }
                if let scheduled = dateString(task.scheduledDate) { item["scheduled"] = scheduled }
                if let start = dateString(task.startDate) { item["start"] = start }
                if let rule = task.recurrenceRule { item["recurrence"] = rule }
                if let priority = task.priority { item["priority"] = priority }
                if let alert = task.alertDate { item["alert"] = iso.string(from: alert) }
                if let done = task.doneDate { item["done"] = iso.string(from: done) }
                return item
            }

        let payload: [String: Any] = [
            "generatedAt": iso.string(from: Date()),
            "vault": Settings.shared.vaultPath,
            "list": Settings.shared.listName,
            "filesScanned": scan.filesScanned,
            "tasksFound": scan.tasks.count,
            "mirrored": items.count,
            "created": stats.created,
            "updated": stats.updated,
            "adopted": stats.adopted,
            "completedInReminders": stats.completed,
            "deleted": stats.deleted,
            "errors": stats.errors,
            "items": items,
        ]

        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        try? data.write(to: snapshotURL)
    }

    // MARK: - List management

    func reminderList(named name: String, createIfMissing: Bool) -> EKCalendar? {
        let calendars = store.calendars(for: .reminder)
        if let match = calendars.first(where: { $0.title == name }) { return match }
        guard createIfMissing else { return nil }

        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = name
        calendar.source = preferredSource() ?? store.defaultCalendarForNewReminders()?.source
        guard calendar.source != nil else {
            Log.error("No writable source available for reminders")
            return nil
        }
        do {
            try store.saveCalendar(calendar, commit: true)
            Log.info("Created reminder list \"\(name)\"")
            return calendar
        } catch {
            Log.error("Could not create list \"\(name)\": \(error)")
            return nil
        }
    }

    private func preferredSource() -> EKSource? {
        let sources = store.sources.filter { $0.sourceType != .birthdays }
        // Prefer the account that new reminders would default to (usually iCloud).
        if let defaultSource = store.defaultCalendarForNewReminders()?.source { return defaultSource }
        if let calDAV = sources.first(where: { $0.sourceType == .calDAV }) { return calDAV }
        if let local = sources.first(where: { $0.sourceType == .local }) { return local }
        return sources.first
    }

    /// Existing reminder lists, for the settings popup.
    func availableLists() -> [String] {
        store.calendars(for: .reminder).map { $0.title }.sorted()
    }

    /// Diagnostic helper: prints what this tool has written into the target list.
    func dumpManagedReminders(completion: @escaping ([String]) -> Void) {
        guard isAuthorized else { return completion(["<no Reminders permission>"]) }
        guard let list = reminderList(named: Settings.shared.listName, createIfMissing: false) else {
            return completion(["<list \"\(Settings.shared.listName)\" does not exist>"])
        }
        let index = ReminderIndex.shared
        store.fetchReminders(matching: store.predicateForReminders(in: [list])) { reminders in
            let all = reminders ?? []
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"

            let managed = all.compactMap { reminder -> String? in
                guard let uid = index.uid(forIdentifier: reminder.calendarItemIdentifier) else { return nil }
                var due = "-"
                if let c = reminder.dueDateComponents, let d = c.date { due = f.string(from: d) }
                let flag = reminder.isCompleted ? "✓" : "·"
                let notes = reminder.notes.map { "  notes=\($0.prefix(20))" } ?? ""
                return "\(flag) \(due)  uid=\(uid.prefix(8))  \(reminder.title ?? "")\(notes)"
            }.sorted()

            let unmanaged = all.filter { index.uid(forIdentifier: $0.calendarItemIdentifier) == nil }.count
            completion(managed + ["", "managed: \(managed.count)   not-managed (left alone): \(unmanaged)"])
        }
    }
}
