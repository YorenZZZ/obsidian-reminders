import Foundation
import EventKit

/// Converts the supported Obsidian Tasks rules into an EventKit rule. A nil
/// result means there is no exact date-based equivalent in Reminders.
enum NativeRecurrence {
    static func rule(for task: ObsidianTask) -> EKRecurrenceRule? {
        guard let text = task.recurrenceRule?.lowercased().trimmed,
              !text.isEmpty, !text.hasSuffix(" when done"),
              let due = task.effectiveDue,
              let year = due.year, let month = due.month, let day = due.day else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.first == "every" else { return nil }
        var index = 1
        var interval = 1
        if index < words.count, let value = Int(words[index]) {
            guard value > 0 else { return nil }
            interval = value
            index += 1
        }
        guard index < words.count else { return nil }
        let unit = words[index]
        let tail = Array(words.dropFirst(index + 1))
        let weekdays: [String: EKWeekday] = [
            "sunday": .sunday, "monday": .monday, "tuesday": .tuesday,
            "wednesday": .wednesday, "thursday": .thursday,
            "friday": .friday, "saturday": .saturday,
        ]
        let months = ["january", "february", "march", "april", "may", "june",
                      "july", "august", "september", "october", "november", "december"]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let anchor = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }

        if let monthIndex = months.firstIndex(of: unit) {
            let namedMonth = monthIndex + 1
            guard interval == 1, month == namedMonth, tail.count >= 3,
                  tail[0] == "on", tail[1] == "the" else { return nil }
            let ordinalText = tail[2]
            let ordinal = Int(ordinalText.prefix(while: \.isNumber))
            guard let ordinal, ordinal > 0 else { return nil }
            if tail.count == 3 {
                guard ordinal == day else { return nil }
                return EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
            }
            guard tail.count == 4, let weekday = weekdays[tail[3]],
                  calendar.component(.weekday, from: anchor) == weekday.rawValue,
                  (day - 1) / 7 + 1 == ordinal else { return nil }
            return complex(.yearly, interval: 1,
                           weekdays: [EKRecurrenceDayOfWeek(weekday)],
                           months: [NSNumber(value: namedMonth)],
                           setPositions: [NSNumber(value: ordinal)])
        }

        switch unit {
        case "day", "days":
            guard tail.isEmpty else { return nil }
            return EKRecurrenceRule(recurrenceWith: .daily, interval: interval, end: nil)
        case "week", "weeks":
            if tail.isEmpty { return EKRecurrenceRule(recurrenceWith: .weekly, interval: interval, end: nil) }
            guard tail.first == "on", let name = tail.last,
                  tail.count == 2 || (tail.count == 3 && tail[1] == "the") else { return nil }
            let weekday = name == "last" ? EKWeekday.sunday : weekdays[name]
            guard let weekday, calendar.component(.weekday, from: anchor) == weekday.rawValue else { return nil }
            return complex(.weekly, interval: interval,
                           weekdays: [EKRecurrenceDayOfWeek(weekday)])
        case "month", "months":
            if tail.isEmpty {
                guard day <= 28 else { return nil } // Tasks clamps short months; EventKit can skip them.
                return EKRecurrenceRule(recurrenceWith: .monthly, interval: interval, end: nil)
            }
            guard tail.count == 3, tail[0] == "on", tail[1] == "the" else { return nil }
            let monthDay: Int
            if tail[2] == "last" {
                guard let range = calendar.range(of: .day, in: .month, for: anchor), day == range.count else { return nil }
                monthDay = -1
            } else {
                guard let value = Int(tail[2].prefix(while: \.isNumber)), value == day else { return nil }
                monthDay = value
            }
            return complex(.monthly, interval: interval, monthDays: [NSNumber(value: monthDay)])
        case "year", "years":
            if tail.isEmpty {
                guard !(month == 2 && day == 29) else { return nil }
                return EKRecurrenceRule(recurrenceWith: .yearly, interval: interval, end: nil)
            }
            guard tail.count == 3, tail[0] == "on", tail[1] == "the" else { return nil }
            if tail[2] == "last" {
                guard month == 12, day == 31 else { return nil }
            } else {
                guard let value = Int(tail[2].prefix(while: \.isNumber)), month == 1, day == value else { return nil }
            }
            return EKRecurrenceRule(recurrenceWith: .yearly, interval: interval, end: nil)
        default:
            return nil
        }
    }

    private static func complex(_ frequency: EKRecurrenceFrequency,
                                interval: Int,
                                weekdays: [EKRecurrenceDayOfWeek]? = nil,
                                monthDays: [NSNumber]? = nil,
                                months: [NSNumber]? = nil,
                                setPositions: [NSNumber]? = nil) -> EKRecurrenceRule {
        EKRecurrenceRule(recurrenceWith: frequency, interval: interval,
                         daysOfTheWeek: weekdays, daysOfTheMonth: monthDays,
                         monthsOfTheYear: months, weeksOfTheYear: nil,
                         daysOfTheYear: nil, setPositions: setPositions, end: nil)
    }

    static func fingerprint(_ rule: EKRecurrenceRule?) -> String? {
        guard let rule else { return nil }
        let days = (rule.daysOfTheWeek ?? []).map { "\($0.dayOfTheWeek.rawValue):\($0.weekNumber)" }.sorted().joined(separator: ",")
        let monthDays = (rule.daysOfTheMonth ?? []).map { $0.stringValue }.sorted().joined(separator: ",")
        let months = (rule.monthsOfTheYear ?? []).map { $0.stringValue }.sorted().joined(separator: ",")
        let positions = (rule.setPositions ?? []).map { $0.stringValue }.sorted().joined(separator: ",")
        return "\(rule.frequency.rawValue)/\(rule.interval)/\(days)/\(monthDays)/\(months)/\(positions)"
    }
}
