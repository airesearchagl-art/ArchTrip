import Foundation
import Testing
@testable import ArchTrip

struct AppLanguageTests {
    @Test func japaneseIsDefault() {
        #expect(AppLanguage.default == .japanese)
        #expect(AppLanguage.default.locale.language.languageCode == .japanese)
    }

    @Test func storedValuesRoundTrip() {
        #expect(AppLanguage(rawValue: "ja") == .japanese)
        #expect(AppLanguage(rawValue: "en") == .english)
        #expect(AppLanguage(rawValue: "fr") == nil)
    }

    @Test func dateFormattingFollowsSelectedLanguage() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 12))!
        let ja = DateFormatting.dateRange(start, end, locale: AppLanguage.japanese.locale, calendar: calendar)
        let en = DateFormatting.dateRange(start, end, locale: AppLanguage.english.locale, calendar: calendar)
        #expect(ja == "10月15日 – 10月16日")
        #expect(en == "Oct 15 – Oct 16")
        #expect(DateFormatting.dateRange(start, start, locale: AppLanguage.japanese.locale, calendar: calendar) == "10月15日")
    }
}
