import XCTest
@testable import CamberRedline

final class TriageRelativeTimeFormatterTests: XCTestCase {
    private let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }()

    private let locale = Locale(identifier: "en_US_POSIX")
    private let timeZone = TimeZone(secondsFromGMT: 0)!
    private let now = Date(timeIntervalSince1970: 1_772_588_400) // 2026-03-03 20:00:00 UTC

    func testFormats59MinutesAsMinutes() {
        let date = now.addingTimeInterval(-59 * 60)
        XCTAssertEqual(
            TriageRelativeTimeFormatter.string(
                from: date,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ),
            "59m ago"
        )
    }

    func testFormats60MinutesAsOneHour() {
        let date = now.addingTimeInterval(-60 * 60)
        XCTAssertEqual(
            TriageRelativeTimeFormatter.string(
                from: date,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ),
            "1 hr ago"
        )
    }

    func testFormatsOneHourFiftyNineMinutesAsOneHour() {
        let date = now.addingTimeInterval(-((60 + 59) * 60))
        XCTAssertEqual(
            TriageRelativeTimeFormatter.string(
                from: date,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ),
            "1 hr ago"
        )
    }

    func testFormatsTwentyFourHoursAsYesterdayWhenCalendarDayMatches() {
        let date = now.addingTimeInterval(-24 * 60 * 60)
        XCTAssertEqual(
            TriageRelativeTimeFormatter.string(
                from: date,
                now: now,
                calendar: calendar,
                locale: locale,
                timeZone: timeZone
            ),
            "Yesterday"
        )
    }
}
