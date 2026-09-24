import Foundation

/// The Tasks-plugin recurrence forms used by this vault. Unknown rules are
/// deliberately rejected: ticking a task without creating its successor would
/// silently lose work.
enum Recurrence {
    enum Failure: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            switch self { case .unsupported(let rule): return "Unsupported recurrence rule: \(rule)" }
        }
    }

    private static var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = .current
        return result
    }

    static func nextLine(for task: ObsidianTask, completedOn today: Date = Date()) throws -> String? {
        guard let range = task.rawLine.range(of: "🔁") else { return nil }
        let tail = task.rawLine[range.upperBound...]
        let rule = String(tail.prefix { !"📅⏳🛫➕✅❌🆔⛔🏁⏰🔺⏫🔼🔽⏬".contains($0) }).trimmingCharacters(in: .whitespaces)
        guard let reference = date(task.dueDate ?? task.scheduledDate ?? task.startDate) else {
            throw Failure.unsupported(rule)
        }
        let whenDone = rule.lowercased().hasSuffix(" when done")
        let core = whenDone ? String(rule.dropLast(" when done".count)) : rule
        let anchor = whenDone ? calendar.startOfDay(for: today) : reference
        guard let next = nextDate(after: anchor, rule: core) else { throw Failure.unsupported(rule) }
        let difference = calendar.dateComponents([.day], from: reference, to: next).day ?? 0
        // The next occurrence is based on the original, open line, not the done line.
        var line = task.rawLine
        for marker in ["📅", "⏳", "🛫", "⏰"] {
            let pattern = "(" + NSRegularExpression.escapedPattern(for: marker)
                + "\\s*)(\\d{4}-\\d{2}-\\d{2})([ \\t]+\\d{2}:\\d{2})?"
            let regex = try NSRegularExpression(pattern: pattern)
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let datePart = ns.substring(with: match.range(at: 2))
            guard let old = Self.date(datePart), let shifted = calendar.date(byAdding: .day, value: difference, to: old) else { continue }
            line = (line as NSString).replacingCharacters(in: match.range(at: 2), with: Self.string(shifted))
        }
        // A newly generated occurrence must not inherit completion metadata.
        line = line.replacingOccurrences(of: "\\s*✅\\s*\\d{4}-\\d{2}-\\d{2}", with: "", options: .regularExpression)
        line = line.replacingOccurrences(of: "\\s*➕\\s*\\d{4}-\\d{2}-\\d{2}", with: "", options: .regularExpression)
        return line
    }

    private static func nextDate(after anchor: Date, rule: String) -> Date? {
        let words = rule.lowercased().split(separator: " ").map(String.init)
        guard words.first == "every" else { return nil }
        var position = 1
        var interval = 1
        if position < words.count, let number = Int(words[position]) {
            guard number > 0 else { return nil }
            interval = number
            position += 1
        }
        guard position < words.count else { return nil }
        let unit = words[position].trimmingCharacters(in: CharacterSet(charactersIn: ","))
        let tail = Array(words.dropFirst(position + 1))
        let c = calendar
        let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if let month = months.firstIndex(of: unit) {
            guard tail.count >= 2, tail[0] == "on", tail[1] == "the" else { return nil }
            let targetMonth = month + 1
            let daySpec = Array(tail.dropFirst(2))
            for yearOffset in 0...20 {
                let year = c.component(.year, from: anchor) + yearOffset
                if let candidate = inMonth(year: year, month: targetMonth, specification: daySpec), candidate > anchor { return candidate }
            }
            return nil
        }
        let component: Calendar.Component
        switch unit {
        case "day", "days": component = .day
        case "week", "weeks": component = .weekOfYear
        case "month", "months": component = .month
        case "year", "years": component = .year
        default: return nil
        }
        if tail.isEmpty { return c.date(byAdding: component, value: interval, to: anchor) }
        guard tail.count >= 2, tail[0] == "on" else { return nil }
        if component == .weekOfYear {
            let name = tail.last ?? ""
            let weekday: Int
            if name == "last" { weekday = 0 }
            else if let value = weekdays.firstIndex(of: name) { weekday = value }
            else { return nil }
            // Weekly BYDAY rules advance to the next matching weekday.
            let current = c.component(.weekday, from: anchor) - 1
            var delta = (weekday - current + 7) % 7
            if delta == 0 { delta = 7 * interval }
            else if interval > 1 { delta += 7 * (interval - 1) }
            return c.date(byAdding: .day, value: delta, to: anchor)
        }
        guard tail.count >= 3, tail[1] == "the" else { return nil }
        let daySpec = Array(tail.dropFirst(2))
        for multiplier in 1...240 {
            guard let base = c.date(byAdding: component, value: interval * multiplier, to: anchor) else { break }
            let parts = c.dateComponents([.year, .month], from: base)
            let month = component == .year ? (daySpec.first == "last" ? 12 : 1) : parts.month!
            if let candidate = inMonth(year: parts.year!, month: month, specification: daySpec), candidate > anchor { return candidate }
        }
        return nil
    }

    private static func inMonth(year: Int, month: Int, specification: [String]) -> Date? {
        guard let first = specification.first,
              let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: monthStart) else { return nil }
        if first == "last" {
            if specification.count == 1 { return calendar.date(from: DateComponents(year: year, month: month, day: range.count)) }
            return nil
        }
        let digits = String(first.prefix(while: { $0.isNumber }))
        guard let ordinal = Int(digits), ordinal > 0 else { return nil }
        if specification.count == 1 {
            guard ordinal <= range.count else { return nil }
            return calendar.date(from: DateComponents(year: year, month: month, day: ordinal))
        }
        let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        guard specification.count == 2, let weekday = weekdays.firstIndex(of: specification[1]) else { return nil }
        let firstWeekday = calendar.component(.weekday, from: monthStart) - 1
        let day = 1 + (weekday - firstWeekday + 7) % 7 + (ordinal - 1) * 7
        guard day <= range.count else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func date(_ components: DateComponents?) -> Date? {
        guard let value = components else { return nil }
        return calendar.date(from: DateComponents(year: value.year, month: value.month, day: value.day))
    }
    private static func date(_ value: String) -> Date? {
        let pieces = value.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: pieces[0], month: pieces[1], day: pieces[2]))
    }
    private static func string(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}
