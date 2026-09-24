import Foundation
import EventKit

func require(_ condition: Bool, _ message: String) {
    guard condition else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("obsidian-reminders-regression-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

let file = directory.appendingPathComponent("Repeatable_Tasks.md")
let active = "- [ ] Back up photos to [[NAS]] 🔁 every week on Sunday 📅  2026-09-20 "
let history = "- [x] Back up photos to [[NAS]] 🔁 every week on Sunday ⏳ 2026-08-23 ✅ 2026-08-23"
let original = "# 循环任务\r\n\(active)\r\n\(history)\r\n"
try original.write(to: file, atomically: true, encoding: .utf8)

let tasks = TaskParser.lines(of: original).enumerated().compactMap { index, line in
    TaskParser.parse(line: String(line), absolutePath: file.path, relativePath: "Repeatable_Tasks.md", lineNumber: index + 1)
}
require(tasks.count == 2, "fixture contains two parsed tasks")
require(tasks[0].uid == tasks[1].uid, "recurring history shares a UID")
let open = TaskParser.openDatedTasksByUID(tasks)
guard let selected = open[tasks[0].uid] else { fatalError("missing active task") }
require(!selected.isCompleted && selected.rawLine == active, "current open task selected over completed history")
require(try TaskParser.markCompleted(selected), "current task was changed")
let updated = try String(contentsOf: file, encoding: .utf8)
require(updated.contains("- [ ] Back up photos to [[NAS]] 🔁 every week on Sunday 📅  2026-09-27"), "next Sunday generated")
require(updated.contains("- [x] Back up photos to [[NAS]] 🔁 every week on Sunday 📅  2026-09-20"), "old occurrence completed")
require(updated.contains(history), "older history preserved")
require(updated.contains("\r\n"), "CRLF preserved")
require(open[tasks[0].uid] != nil, "original scan retained its task identity")

// A stale scan must not overwrite a line that the user edited in Obsidian.
try "- [ ] changed 📅 2026-09-20\n".write(to: file, atomically: true, encoding: .utf8)
require(try !TaskParser.markCompleted(selected), "stale task did not rewrite a changed file")

// CRLF counts as one line break, so a duplicated line is resolved by its real
// line number and only the selected copy is ticked.
let duplicate = "- [ ] 重复任务 📅 2026-10-01"
try "# 标题\r\n\(duplicate)\r\n\(duplicate)\r\n".write(to: file, atomically: true, encoding: .utf8)
let second = TaskParser.parse(line: duplicate, absolutePath: file.path, relativePath: "dup.md", lineNumber: 3)!
require(try TaskParser.markCompleted(second), "duplicate line resolved by CRLF line number")
require(try String(contentsOf: file, encoding: .utf8) == "# 标题\r\n\(duplicate)\r\n- [x] 重复任务 📅 2026-10-01\r\n",
        "only the second duplicate was completed")

let cases: [(String, String)] = [
    ("every month on the 1st 📅 2026-10-01", "📅 2026-11-01"),
    ("every month on the last 📅 2026-09-30", "📅 2026-10-31"),
    ("every 3 months on the last 📅 2026-11-30", "📅 2027-02-28"),
    ("every year on the last 📅 2026-12-31", "📅 2027-12-31"),
    ("every 2 years on the 1st 📅 2027-01-01", "📅 2029-01-01"),
    ("every May on the 2nd Sunday 📅 2027-05-09", "📅 2028-05-14"),
]
for (rule, expectedDate) in cases {
    let line = "- [ ] fixture 🔁 \(rule)"
    let task = TaskParser.parse(line: line, absolutePath: file.path, relativePath: "test.md", lineNumber: 1)!
    let next = try Recurrence.nextLine(for: task)!
    require(next.contains(expectedDate), "next date for \(rule): \(next)")
}

let nativeCases = [
    "every week on Sunday 📅 2026-09-27",
    "every month on the 1st 📅 2026-10-01",
    "every 3 months on the last 📅 2026-11-30",
    "every 2 years on the 1st 📅 2027-01-01",
    "every May on the 2nd Sunday 📅 2027-05-09",
]
for rule in nativeCases {
    let task = TaskParser.parse(line: "- [ ] fixture 🔁 \(rule)", absolutePath: file.path,
                                relativePath: "native.md", lineNumber: 1)!
    require(NativeRecurrence.rule(for: task) != nil, "native recurrence for \(rule)")
}
let mismatch = TaskParser.parse(line: "- [ ] fixture 🔁 every July on the 1st 📅 2027-09-01",
                                absolutePath: file.path, relativePath: "mismatch.md", lineNumber: 1)!
require(NativeRecurrence.rule(for: mismatch) == nil, "mismatched rule and due date not mapped natively")
let timed = TaskParser.parse(line: "- [ ] timed 🔺 ⏰ 2026-09-23 08:30 📅 2026-09-23 10:00",
                             absolutePath: file.path, relativePath: "timed.md", lineNumber: 1)!
require(timed.title == "timed", "metadata removed from title")
require(timed.dueDate?.hour == 10 && timed.dueDate?.minute == 0, "due time parsed")
require(timed.priority == 1 && timed.alertDate != nil, "priority and explicit alert parsed")
let completeWithDate = TaskParser.parse(line: "- [x] finished 📅 2026-09-20 ✅ 2026-09-23",
                                        absolutePath: file.path, relativePath: "done.md", lineNumber: 1)!
require(completeWithDate.doneDate != nil, "done date parsed")
let recurringTimed = TaskParser.parse(
    line: "- [ ] timed 🔁 every week on Sunday ⏰ 2026-09-20 08:30 📅 2026-09-20 10:00",
    absolutePath: file.path, relativePath: "timed-recurring.md", lineNumber: 1)!
let nextTimed = try Recurrence.nextLine(for: recurringTimed)!
require(nextTimed.contains("⏰ 2026-09-27 08:30") && nextTimed.contains("📅 2026-09-27 10:00"),
        "next recurrence moves alert and due time together")
let priorityAfterRule = TaskParser.parse(
    line: "- [ ] timed 🔁 every week on Sunday 🔺 📅 2026-09-27",
    absolutePath: file.path, relativePath: "priority-after-rule.md", lineNumber: 1)!
require(priorityAfterRule.recurrenceRule == "every week on Sunday" && priorityAfterRule.priority == 1,
        "priority after recurrence parsed independently")
require(NativeRecurrence.rule(for: priorityAfterRule) != nil,
        "priority after recurrence still permits native repeat")
require((try Recurrence.nextLine(for: priorityAfterRule))?.contains("📅 2026-10-04") == true,
        "priority after recurrence does not stop successor generation")

print("completion regression passed")
