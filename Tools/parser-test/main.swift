import Foundation

// Standalone harness for TaskParser. Build with:
//   swiftc -o /tmp/parse-test Sources/TaskParser.swift Sources/Log.swift Sources/Recurrence.swift Tools/parser-test/main.swift

let samples: [(String, String, String?)] = [
    // (input line, expected cleaned title, expected date "yyyy-MM-dd" or nil)
    ("- [ ] [[Pets#Weekly|Groom the cat (weekly)]] 🔁 every week on Sunday 📅  2026-09-20",
     "Groom the cat (weekly)", "2026-09-20"),

    ("- [x] [[Pets#Weekly|Groom the cat (weekly)]] 🔁 every week on Sunday ⏳ 2026-08-23 ✅ 2026-08-24",
     "Groom the cat (weekly)", "2026-08-23"),

    ("- [ ] Meal prep ([[Fitness#Diet]], [[Pets#Food]])🔁 every week on Sunday 📅  2026-09-20",
     "Meal prep (Fitness Diet, Pets Food)", "2026-09-20"),

    ("- [ ] 建立新一年[[yearly_note]] 🔁 every year on the 1st 📅  2027-01-01",
     "建立新一年yearly_note", "2027-01-01"),

    ("- [ ] 更换[[牙刷@2|牙刷]] 🔁 every 3 months on the 7th 📅  2026-11-07",
     "更换牙刷", "2026-11-07"),

    ("- [ ] Call [[Jane Doe|Mom]] for Mother's Day 🔁 every May on the 2nd Sunday 📅  2027-05-09",
     "Call Mom for Mother's Day", "2027-05-09"),

    ("- [ ] Renew [example.com](https://example.com/) domain 📅  2033-12-15",
     "Renew example.com domain", "2033-12-15"),

    ("- [ ] [Stretching routine](https://example.org/s/abc123) 🔁 every week on Sunday 📅  2026-09-20",
     "Stretching routine", "2026-09-20"),

    ("- [ ] Take [[Rex]] for a booster shot every July on the 1st 📅 2027-07-01",
     "Take Rex for a booster shot", "2027-07-01"),

    ("- [ ] Back up photos to [[NAS]] 🔁 every week on Sunday 📅  2026-09-20",
     "Back up photos to NAS", "2026-09-20"),

    ("- [ ] Buy groceries 📅 2026-10-23",
     "Buy groceries", "2026-10-23"),

    ("- [ ] 取回快递（带好取件码），然后把旧手机卖掉 📅 2026-10-04",
     "取回快递（带好取件码），然后把旧手机卖掉", "2026-10-04"),

    ("- [ ] [[清洗滚筒洗衣机]] 🔁 every 3 months on the last 📅 2026-11-30",
     "清洗滚筒洗衣机", "2026-11-30"),

    ("- [ ] **重要** 完成 `代码` 审查 #工作 📅 2026-12-01",
     "重要 完成 代码 审查", "2026-12-01"),

    ("- [ ] 没有日期的任务",
     "没有日期的任务", nil),

    ("  - [ ] 缩进的子任务 ⏳ 2026-11-05",
     "缩进的子任务", "2026-11-05"),
]

var failures = 0
var checked = 0

func check(_ condition: Bool, _ label: String) {
    checked += 1
    if !condition {
        failures += 1
        print("  FAIL: \(label)")
    }
}

func iso(_ c: DateComponents?) -> String? {
    guard let c = c, let y = c.year, let m = c.month, let d = c.day else { return nil }
    return String(format: "%04d-%02d-%02d", y, m, d)
}

print("TaskParser self-test")
print(String(repeating: "=", count: 72))

for (line, expectedTitle, expectedDate) in samples {
    guard let task = TaskParser.parse(
        line: line, absolutePath: "/vault/x.md", relativePath: "Databases/Tasks/x.md", lineNumber: 1
    ) else {
        failures += 1
        print("FAIL (no task parsed): \(line)")
        continue
    }

    let titleOK = task.title == expectedTitle
    let dateOK = iso(task.effectiveDue) == expectedDate
    let mark = (titleOK && dateOK) ? "ok  " : "FAIL"
    if !(titleOK && dateOK) { failures += 1 }
    checked += 2

    print("\(mark) \(task.isCompleted ? "✓" : "·") [\(task.title)] due=\(iso(task.effectiveDue) ?? "-") "
          + "📅=\(iso(task.dueDate) ?? "-") ⏳=\(iso(task.scheduledDate) ?? "-")")
    if !titleOK { print("       expected title: \(expectedTitle)") }
    if !dateOK { print("       expected date : \(expectedDate ?? "-")") }
}

// Filtering rule: only dated tasks qualify.
let undated = TaskParser.parse(line: "- [ ] 没有日期的任务", absolutePath: "/a.md", relativePath: "a.md", lineNumber: 1)!
check(!undated.hasDueOrScheduled, "undated task must not qualify for sync")
let dated = TaskParser.parse(line: "- [ ] 有事 📅 2026-10-01", absolutePath: "/a.md", relativePath: "a.md", lineNumber: 1)!
check(dated.hasDueOrScheduled, "dated task must qualify for sync")

// uid stability: same path+title -> same uid; date change must not alter it.
let u1 = TaskParser.uid(relativePath: "a.md", title: "同一任务")
let u2 = TaskParser.uid(relativePath: "a.md", title: "同一任务")
let u3 = TaskParser.uid(relativePath: "b.md", title: "同一任务")
check(u1 == u2, "uid must be stable for identical input")
check(u1 != u3, "uid must differ across files")
check(u1.count == 24, "uid must be 24 hex chars, got \(u1.count)")

// A task whose date changes keeps the same uid (reminder gets updated, not recreated).
let before = TaskParser.parse(line: "- [ ] 交房租 📅 2026-10-01", absolutePath: "/a.md", relativePath: "a.md", lineNumber: 1)!
let after = TaskParser.parse(line: "- [ ] 交房租 📅 2026-11-01", absolutePath: "/a.md", relativePath: "a.md", lineNumber: 1)!
check(before.uid == after.uid, "uid must survive a date change")

print(String(repeating: "=", count: 72))
print("checks: \(checked)  failures: \(failures)")
exit(failures == 0 ? 0 : 1)
