import Foundation
import CryptoKit

/// A task parsed out of an Obsidian markdown file.
struct ObsidianTask {
    var absolutePath: String
    var relativePath: String
    var lineNumber: Int
    var rawLine: String
    var isCompleted: Bool
    var title: String
    var dueDate: DateComponents?
    var scheduledDate: DateComponents?
    var startDate: DateComponents?
    var recurrenceRule: String?
    var priority: Int?
    var alertDate: Date?
    var doneDate: Date?
    var uid: String

    /// The date that drives the reminder's due date: 📅 wins, otherwise ⏳.
    var effectiveDue: DateComponents? { dueDate ?? scheduledDate }

    /// True when the task carries a due (📅) or scheduled (⏳) date.
    var hasDueOrScheduled: Bool { dueDate != nil || scheduledDate != nil }
}

enum TaskParser {

    /// One active occurrence per UID. Completed history of a recurring task
    /// must never hide its current unchecked occurrence.
    static func openDatedTasksByUID(_ tasks: [ObsidianTask]) -> [String: ObsidianTask] {
        var result: [String: ObsidianTask] = [:]
        for task in tasks where task.hasDueOrScheduled && !task.isCompleted {
            result[task.uid] = task
        }
        return result
    }

    /// Splits Markdown into lines. `\r\n` is a single Character in Swift, so a
    /// CRLF file is not counted as having an empty line after every line
    /// (which `components(separatedBy: .newlines)` would do).
    static func lines(of text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }

    // MARK: - Regexes

    private static func re(_ pattern: String) -> NSRegularExpression {
        // Patterns are authored inline and covered by tests; a failure is a programmer error.
        do { return try NSRegularExpression(pattern: pattern) }
        catch {
            Log.error("Bad regex \(pattern): \(error)")
            return try! NSRegularExpression(pattern: "$^")
        }
    }

    /// `- [ ] text` / `* [x] text` / `+ [ ] text`
    private static let taskLine = re("^(\\s*)[-*+]\\s+\\[([ xX])\\]\\s+(.*)$")

    private static let dueRe       = re("📅\\s*(\\d{4})-(\\d{2})-(\\d{2})(?:[ \\t]+(\\d{2}):(\\d{2}))?")
    private static let scheduledRe = re("⏳\\s*(\\d{4})-(\\d{2})-(\\d{2})(?:[ \\t]+(\\d{2}):(\\d{2}))?")
    private static let startRe     = re("🛫\\s*(\\d{4})-(\\d{2})-(\\d{2})(?:[ \\t]+(\\d{2}):(\\d{2}))?")
    private static let alertRe     = re("⏰\\s*(\\d{4})-(\\d{2})-(\\d{2})[ \\t]+(\\d{2}):(\\d{2})")
    private static let doneRe      = re("✅\\s*(\\d{4})-(\\d{2})-(\\d{2})")
    private static let recurrenceRe = re("🔁\\s*([^📅⏳🛫➕✅❌🆔⛔🏁⏰🔺⏫🔼🔽⏬]+)")

    /// Metadata chunks stripped from the title.
    private static let metadataPatterns: [NSRegularExpression] = [
        re("🔁[^📅⏳🛫➕✅❌🆔⛔🏁⏰🔺⏫🔼🔽⏬]*"),
        re("📅\\s*\\d{4}-\\d{2}-\\d{2}(?:[ \\t]+\\d{2}:\\d{2})?"),
        re("⏳\\s*\\d{4}-\\d{2}-\\d{2}(?:[ \\t]+\\d{2}:\\d{2})?"),
        re("🛫\\s*\\d{4}-\\d{2}-\\d{2}(?:[ \\t]+\\d{2}:\\d{2})?"),
        re("⏰\\s*\\d{4}-\\d{2}-\\d{2}(?:[ \\t]+\\d{2}:\\d{2})?"),
        re("➕\\s*\\d{4}-\\d{2}-\\d{2}"),
        re("✅\\s*\\d{4}-\\d{2}-\\d{2}"),
        re("❌\\s*\\d{4}-\\d{2}-\\d{2}"),
        re("🆔\\s*\\S+"),
        re("⛔\\s*\\S+"),
        re("🏁\\s*(?:delete|keep)"),
        re("[🔺⏫🔼🔽⏬]"),
        // Bare recurrence text left behind when the 🔁 emoji is missing, e.g.
        // "Take [[Rex]] for a booster shot every July on the 1st 📅 2027-07-01"
        re("\\s+every\\s+(?:(?:\\d+)\\s+)?(?:day|days|week|weeks|month|months|year|years|"
           + "January|February|March|April|May|June|July|August|September|October|November|December)\\b.*$"),
    ]

    /// `![[note#heading|alias]]` and friends.
    private static let wikiLinkRe = re("!?\\[\\[([^\\]\\|#]*)(?:#([^\\]\\|]*))?(?:\\|([^\\]]*))?\\]\\]")
    /// `[text](url)`
    private static let mdLinkRe   = re("!?\\[([^\\]]*)\\]\\([^)]*\\)")
    /// Inline Obsidian tag.
    private static let tagRe      = re("(^|\\s)#[\\p{L}\\p{N}_\\-/]+")

    // MARK: - Line parsing

    static func parse(line rawLine: String,
                      absolutePath: String,
                      relativePath: String,
                      lineNumber: Int) -> ObsidianTask? {
        let ns = rawLine as NSString
        guard let m = taskLine.firstMatch(in: rawLine, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        let body = ns.substring(with: m.range(at: 3))
        let checked = ns.substring(with: m.range(at: 2))
        let isCompleted = (checked.lowercased() == "x")

        var title = cleanTitle(body)
        if title.isEmpty { title = "Untitled task" }

        return ObsidianTask(
            absolutePath: absolutePath,
            relativePath: relativePath,
            lineNumber: lineNumber,
            rawLine: rawLine,
            isCompleted: isCompleted,
            title: title,
            dueDate: dateComponents(from: dueRe, in: body),
            scheduledDate: dateComponents(from: scheduledRe, in: body),
            startDate: dateComponents(from: startRe, in: body),
            recurrenceRule: capture(from: recurrenceRe, in: body)?.trimmed,
            priority: priority(in: body),
            alertDate: dateComponents(from: alertRe, in: body).flatMap { $0.date },
            doneDate: dateComponents(from: doneRe, in: body).flatMap { $0.date },
            uid: uid(relativePath: relativePath, title: title)
        )
    }

    /// Marks the current, still-unchecked version of `task` as complete while
    /// preserving the rest of the Markdown file, including its line endings and
    /// task metadata. The UID check prevents a stale scan from ticking a
    /// different task that happens to have the same text.
    static func markCompleted(_ task: ObsidianTask) throws -> Bool {
        let url = URL(fileURLWithPath: task.absolutePath)
        let data = try Data(contentsOf: url)
        guard let contents = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }

        let ns = contents as NSString
        let pattern = try NSRegularExpression(pattern: "(?m)^([ \\t]*[-*+][ \\t]+)\\[ \\][^\\r\\n]*")
        let matches = pattern.matches(in: contents, range: NSRange(location: 0, length: ns.length))
        let exact = matches.filter { ns.substring(with: $0.range) == task.rawLine }
        guard !exact.isEmpty else { return false }

        // If identical lines occur more than once, use the scanned line number.
        // An ambiguous or changed source line is left untouched for a later scan.
        let selected: NSTextCheckingResult
        if exact.count == 1 {
            selected = exact[0]
        } else {
            guard let numbered = exact.first(where: { match in
                lines(of: ns.substring(to: match.range.location)).count == task.lineNumber
            }) else { return false }
            selected = numbered
        }
        let currentLine = ns.substring(with: selected.range)
        let nextLine = try Recurrence.nextLine(for: task)
        var completedLine = (currentLine as NSString).replacingCharacters(
            in: NSRange(location: selected.range(at: 1).length, length: 3), with: "[x]")
        if nextLine != nil && !completedLine.contains("✅") {
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd"
            completedLine = completedLine.trimmingCharacters(in: .whitespaces) + " ✅ " + formatter.string(from: Date())
        }
        let newline = contents.contains("\r\n") ? "\r\n" : "\n"
        let replacement = nextLine.map { $0 + newline + completedLine } ?? completedLine
        let updated = NSMutableString(string: contents)
        updated.replaceCharacters(in: selected.range, with: replacement)
        guard let output = (updated as String).data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try output.write(to: url, options: .atomic)
        return true
    }

    // MARK: - Title cleaning

    /// Turn an Obsidian task body into plain text suitable for the Reminders app.
    static func cleanTitle(_ body: String) -> String {
        var s = body

        // 1. Drop scheduling / recurrence metadata.
        for pattern in metadataPatterns { s = pattern.replacingAll(in: s, with: " ") }

        // 2. Resolve wiki links to their display text.
        s = wikiLinkRe.replacingAll(in: s) { g in
            let target = g[1].trimmed
            let heading = g[2].trimmed
            let alias = g[3].trimmed
            if !alias.isEmpty { return alias }
            if !target.isEmpty && !heading.isEmpty { return target + " " + heading }
            return target.isEmpty ? heading : target
        }

        // 3. Resolve markdown links to their link text.
        s = mdLinkRe.replacingAll(in: s, with: "$1")

        // 4. Strip emphasis, code, strikethrough, raw HTML.
        let decorations: [(String, String)] = [
            ("\\*\\*(.+?)\\*\\*", "$1"),
            ("__(.+?)__", "$1"),
            ("~~(.+?)~~", "$1"),
            ("(?<!\\w)\\*(?!\\s)(.+?)(?<!\\s)\\*(?!\\w)", "$1"),
            ("(?<!\\w)_(?!\\s)(.+?)(?<!\\s)_(?!\\w)", "$1"),
            ("`([^`]+)`", "$1"),
            ("<[^>]+>", " "),
        ]
        for (pattern, template) in decorations {
            s = re(pattern).replacingAll(in: s, with: template)
        }

        // 5. Drop inline tags.
        s = tagRe.replacingAll(in: s, with: "$1")

        // 6. Tidy whitespace and dangling punctuation.
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " 　,，;；:：、-–—"))
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func dateComponents(from regex: NSRegularExpression, in text: String) -> DateComponents? {
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              let y = Int(ns.substring(with: m.range(at: 1))),
              let mo = Int(ns.substring(with: m.range(at: 2))),
              let d = Int(ns.substring(with: m.range(at: 3))),
              (1...12).contains(mo), (1...31).contains(d) else { return nil }
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = d
        if m.numberOfRanges > 5,
           m.range(at: 4).location != NSNotFound, m.range(at: 5).location != NSNotFound,
           let hour = Int(ns.substring(with: m.range(at: 4))),
           let minute = Int(ns.substring(with: m.range(at: 5))),
           (0...23).contains(hour), (0...59).contains(minute) {
            c.hour = hour; c.minute = minute
        }
        c.calendar = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }

    private static func capture(from regex: NSRegularExpression, in text: String) -> String? {
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    private static func priority(in text: String) -> Int? {
        if text.contains("🔺") { return 1 }
        if text.contains("⏫") { return 3 }
        if text.contains("🔼") { return 5 }
        if text.contains("🔽") { return 7 }
        if text.contains("⏬") { return 9 }
        return nil
    }

    /// Stable identity for a task: file path + cleaned title. Dates and completion
    /// state can change without breaking the link to the reminder.
    static func uid(relativePath: String, title: String) -> String {
        let digest = SHA256.hash(data: Data((relativePath + "\u{1F}" + title).utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(24))
    }
}

// MARK: - Regex helpers

extension NSRegularExpression {
    /// Replace every match, building the replacement from capture groups (index 0 = whole match).
    func replacingAll(in text: String, _ transform: ([String]) -> String) -> String {
        let ns = text as NSString
        let matches = self.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        let out = NSMutableString()
        var cursor = 0
        for m in matches {
            guard m.range.location != NSNotFound else { continue }
            out.append(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            out.append(transform(groups))
            cursor = m.range.location + m.range.length
        }
        out.append(ns.substring(from: cursor))
        return out as String
    }

    func replacingAll(in text: String, with template: String) -> String {
        stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: template
        )
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
