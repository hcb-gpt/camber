import Foundation

enum TriageRelativeTimeFormatter {
    static func string(
        from date: Date,
        now: Date = Date(),
        calendar inputCalendar: Calendar = .current,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let elapsedSeconds = max(0, now.timeIntervalSince(date))
        let elapsedMinutes = Int(elapsedSeconds / 60)

        if elapsedMinutes < 60 {
            return "\(elapsedMinutes)m ago"
        }

        let elapsedHours = elapsedMinutes / 60
        if elapsedHours < 24 {
            return "\(elapsedHours) hr ago"
        }

        var calendar = inputCalendar
        calendar.locale = locale
        calendar.timeZone = timeZone

        let startOfNow = calendar.startOfDay(for: now)
        let startOfDate = calendar.startOfDay(for: date)
        let dayDelta = calendar.dateComponents([.day], from: startOfDate, to: startOfNow).day ?? 0
        if dayDelta == 1 {
            return "Yesterday"
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}
