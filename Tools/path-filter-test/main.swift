import Foundation

// Build with:
//   swiftc -o /tmp/path-filter-test Sources/PathFilter.swift Tools/path-filter-test/main.swift

var failures = 0
func check(_ condition: Bool, _ label: String) {
    if !condition { failures += 1; print("FAIL: \(label)") }
}

// Separators and normalisation.
check(PathFilter.split("工作、 /生活/ ，Inbox/todo.md;a\nb") == ["工作", "生活", "Inbox/todo.md", "a", "b"],
      "split on 、 , ， ; and newlines, trimming slashes and spaces")

// Empty lists sync everything.
let none = PathFilter(includeText: "", excludeText: "")
check(none.isEmpty && none.allows("any/note.md"), "no lists: everything allowed")

// Blacklist only.
let black = PathFilter(includeText: "", excludeText: "Archive、Inbox/todo")
check(!black.allows("Archive/2025/old.md"), "blacklisted folder excluded recursively")
check(!black.allows("Inbox/todo.md"), "blacklisted file matched without .md")
check(black.allows("Inbox/other.md"), "sibling file still allowed")
check(black.allows("Archive2/x.md"), "prefix of a name is not a folder match")

// Whitelist only.
let white = PathFilter(includeText: "Projects、Daily/2026-09-25.md", excludeText: "")
check(white.allows("Projects/a/b.md"), "whitelisted folder included recursively")
check(white.allows("Daily/2026-09-25.md"), "whitelisted file included")
check(!white.allows("Daily/2026-09-24.md"), "non-whitelisted file excluded")

// Both filled: whitelist wins, blacklist otherwise ignored…
let both = PathFilter(includeText: "Projects、Work", excludeText: "Work、Personal")
check(both.allows("Projects/x.md"), "whitelist wins when not blacklisted")
check(!both.allows("Personal/x.md"), "outside whitelist excluded")
// …except an entry in both lists, which is blacklisted.
check(!both.allows("Work/x.md"), "entry in both lists is blacklisted")
let sameEntry = PathFilter(includeText: "Work/", excludeText: "./Work")
check(!sameEntry.allows("Work/x.md"), "same entry written differently is still blacklisted")
check(!sameEntry.allows("Other/x.md"), "whitelist stays active even if all its entries are blacklisted")

check(!PathFilter(includeText: "", excludeText: "archive").allows("Archive/x.md"), "matching ignores case")

print(failures == 0 ? "path filter passed" : "path filter: \(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
