import Foundation

/// Persistent uid ↔ reminder mapping.
///
/// A reminder has no hidden field we can write to — every writable string
/// (title, notes, url, location) is visible in the Reminders UI. So instead of
/// stamping a marker into the reminder, this tool remembers which reminder it
/// created in a local index file. The reminder itself stays clean: just the
/// task text, no markers, no paths, no links.
final class ReminderIndex {

    static let shared = ReminderIndex()

    private var byUID: [String: String] = [:]        // uid -> calendarItemIdentifier
    private var byIdentifier: [String: String] = [:] // calendarItemIdentifier -> uid
    private var syncedCompletion: [String: Bool] = [:]
    private var syncedRecurrence: [String: String] = [:]
    private var syncedPriority: [String: Int] = [:]
    private var syncedAlarm: [String: String] = [:]
    private let queue = DispatchQueue(label: "io.github.yorenzzz.obsidian-reminders.index")
    private let fileURL: URL

    static var indexURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ObsidianReminders", isDirectory: true)
            .appendingPathComponent("reminder-index.json")
    }

    private init() {
        fileURL = ReminderIndex.indexURL
        load()
    }

    // MARK: - Lookup

    func identifier(for uid: String) -> String? {
        queue.sync { byUID[uid] }
    }

    func uid(forIdentifier identifier: String) -> String? {
        queue.sync { byIdentifier[identifier] }
    }

    func lastSyncedCompletion(for uid: String) -> Bool? { queue.sync { syncedCompletion[uid] } }

    func setSyncedCompletion(_ value: Bool, for uid: String) {
        queue.sync { syncedCompletion[uid] = value }
    }

    func lastSyncedRecurrence(for uid: String) -> String? { queue.sync { syncedRecurrence[uid] } }
    func setSyncedRecurrence(_ value: String?, for uid: String) {
        queue.sync { syncedRecurrence[uid] = value }
    }

    func lastSyncedPriority(for uid: String) -> Int? { queue.sync { syncedPriority[uid] } }
    func setSyncedPriority(_ value: Int?, for uid: String) {
        queue.sync { syncedPriority[uid] = value }
    }

    func lastSyncedAlarm(for uid: String) -> String? { queue.sync { syncedAlarm[uid] } }
    func setSyncedAlarm(_ value: String?, for uid: String) {
        queue.sync { syncedAlarm[uid] = value }
    }

    var count: Int { queue.sync { byUID.count } }

    // MARK: - Mutation

    func set(uid: String, identifier: String) {
        queue.sync {
            if let previous = byUID[uid], previous != identifier {
                byIdentifier.removeValue(forKey: previous)
            }
            if let previousUID = byIdentifier[identifier], previousUID != uid {
                byUID.removeValue(forKey: previousUID)
            }
            byUID[uid] = identifier
            byIdentifier[identifier] = uid
        }
    }

    func remove(uid: String) {
        queue.sync {
            if let identifier = byUID.removeValue(forKey: uid) {
                byIdentifier.removeValue(forKey: identifier)
            }
            syncedCompletion.removeValue(forKey: uid)
            syncedRecurrence.removeValue(forKey: uid)
            syncedPriority.removeValue(forKey: uid)
            syncedAlarm.removeValue(forKey: uid)
        }
    }

    /// Drops entries pointing at reminders that no longer exist.
    func retainOnly(identifiers: Set<String>) {
        queue.sync {
            let stale = byUID.filter { !identifiers.contains($0.value) }.map(\.key)
            for uid in stale {
                if let identifier = byUID.removeValue(forKey: uid) {
                    byIdentifier.removeValue(forKey: identifier)
                }
            }
        }
    }

    func removeAll() {
        queue.sync {
            byUID.removeAll()
            byIdentifier.removeAll()
        }
    }

    /// Drops per-task sync metadata for tasks that no longer own a reminder,
    /// so deleted tasks do not accumulate in the index file forever.
    func pruneMetadata() {
        queue.sync {
            let owned = Set(byUID.keys)
            syncedCompletion = syncedCompletion.filter { owned.contains($0.key) }
            syncedRecurrence = syncedRecurrence.filter { owned.contains($0.key) }
            syncedPriority = syncedPriority.filter { owned.contains($0.key) }
            syncedAlarm = syncedAlarm.filter { owned.contains($0.key) }
        }
    }

    // MARK: - Persistence

    func save() {
        let snapshot = queue.sync { (byUID, syncedCompletion, syncedRecurrence, syncedPriority, syncedAlarm) }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(
                withJSONObject: ["identifiers": snapshot.0, "completed": snapshot.1,
                                 "recurrence": snapshot.2, "priority": snapshot.3, "alarm": snapshot.4],
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Log.error("Could not write reminder index: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let identifiers = object["identifiers"] as? [String: String]
            ?? (object as? [String: String]) ?? [:]
        let completion = object["completed"] as? [String: Bool] ?? [:]
        let recurrence = object["recurrence"] as? [String: String] ?? [:]
        let priority = object["priority"] as? [String: Int] ?? [:]
        let alarm = object["alarm"] as? [String: String] ?? [:]
        queue.sync {
            byUID = identifiers
            byIdentifier.removeAll()
            for (uid, identifier) in identifiers { byIdentifier[identifier] = uid }
            syncedCompletion = completion
            syncedRecurrence = recurrence
            syncedPriority = priority
            syncedAlarm = alarm
        }
        Log.info("Reminder index loaded (\(identifiers.count) entries)")
    }
}
