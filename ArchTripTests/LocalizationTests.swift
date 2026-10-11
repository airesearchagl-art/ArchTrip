import Foundation
import Testing
@testable import ArchTrip

struct LocalizationTests {
    private func bundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"), "\(language).lproj missing")
        return try #require(Bundle(path: path))
    }

    private func japanese(_ key: String) throws -> String {
        try bundle("ja").localizedString(forKey: key, value: "<missing>", table: "Localizable")
    }

    @Test func japaneseEventTypeLabels() throws {
        let expected = [
            "Flight": "飛行機", "Train": "電車", "Car": "車", "Walk": "徒歩", "Hotel": "ホテル",
            "Business": "業務", "Architecture Visit": "建築見学", "Food": "食事", "Other": "その他",
        ]
        #expect(expected.count == EventType.allCases.count)
        for (key, value) in expected {
            #expect(try japanese(key) == value, "\(key)")
        }
    }

    @Test func japaneseCoreUIStrings() throws {
        let expected = [
            "Upcoming": "予定の出張", "Past": "過去の出張", "Add Trip": "出張を追加",
            "Travel / Free Time": "移動時間・空き時間", "Settings": "設定", "Language": "言語",
            "Developer Diagnostics": "開発者診断", "Couldn't save changes": "変更を保存できませんでした",
            "Architecture": "建築", "Add to Trip": "出張に追加", "Open in Apple Maps": "Apple Mapsで開く",
            "Visit duration": "見学時間", "This building is no longer available": "この建築は削除されています",
        ]
        for (key, value) in expected {
            #expect(try japanese(key) == value, "\(key)")
        }
    }

    /// G6-UX-01: the gap row is labelled "Travel / Free Time"; the old key is gone.
    @Test func travelFreeTimeWording() throws {
        #expect(try japanese("Travel / Free Time") == "移動時間・空き時間")
        #expect(try japanese("Free time") == "<missing>")
    }

    @Test func japaneseG5RepairStrings() throws {
        let expected = [
            "Events outside the trip dates": "出張期間外の予定があります",
            "Outside the trip dates": "出張期間外の予定",
            "Event dates aren't changed automatically. Edit them individually if needed.": "予定の日付は自動変更されません。必要に応じて個別に編集してください。",
            "Existing building": "既存の建築", "Enter manually": "自由入力する", "Unlink building": "建築のリンクを解除",
            "The building's name is used as the title. Enter the location yourself.": "建築名がタイトルになります。場所は自分で入力してください。",
        ]
        for (key, value) in expected {
            #expect(try japanese(key) == value, "\(key)")
        }
        #expect(String(format: try japanese("%lld events outside the new dates"), 2) == "期間外の予定：2件")
        #expect(String(format: try japanese("New trip dates: %@"), "10月15日 – 10月17日") == "変更後の出張期間：10月15日 – 10月17日")
    }

    @Test func japaneseG6AllDayStrings() throws {
        let expected = [
            "All-day": "終日", "All-day & stays": "終日・滞在情報", "Stay": "宿泊", "Rental car": "レンタカー",
            "Check-in": "チェックイン", "Check-out": "チェックアウト", "Pickup day": "利用開始日", "Return day": "返却日",
            "First day": "開始日", "Last day": "終了日", "No timed events on this day": "この日の時刻付き予定はありません",
            "Shown on each night from check-in until the day before check-out.": "チェックイン日からチェックアウト前日までの各夜に表示します。",
            "Shown on each day from pickup through return.": "利用開始日から返却日までの各日に表示します。",
            "Shown on each day in this range.": "開始日から終了日までの各日に表示します。",
            "All-day events don't count toward Travel / Free Time.": "終日の予定は移動時間・空き時間の計算に含まれません。",
        ]
        for (key, value) in expected {
            #expect(try japanese(key) == value, "\(key)")
        }
        #expect(String(format: try japanese("Check-in %@ · Check-out %@"), "10月15日", "10月17日") == "チェックイン 10月15日・チェックアウト 10月17日")
    }

    /// G6-UX-06: the current-time row and the completed-Event accessibility value.
    @Test func japaneseNowAndCompletedStrings() throws {
        #expect(try japanese("Now") == "現在時刻")
        #expect(try japanese("Completed") == "終了済み")
    }

    /// G6-UX-05: hotel clock-time controls and the derived marker rows.
    @Test func japaneseHotelClockTimeStrings() throws {
        let expected = [
            "Set check-in time": "チェックイン時刻を指定する", "Check-in time": "チェックイン時刻",
            "Set check-out time": "チェックアウト時刻を指定する", "Check-out time": "チェックアウト時刻",
            "Stay times": "宿泊の時刻", "Hotel check-in": "ホテルチェックイン", "Hotel check-out": "ホテルチェックアウト",
            "Shown on the timeline as check-in and check-out markers on their own days. The stay itself stays under All-day & stays.":
                "時刻付きの予定一覧に、それぞれの日のチェックイン・チェックアウトの目印として表示します。宿泊自体は「終日・滞在情報」に残ります。",
        ]
        for (key, value) in expected {
            #expect(try japanese(key) == value, "\(key)")
        }
        #expect(String(format: try japanese("Stay: %@"), "Hotel") == "宿泊：Hotel")
    }

    @Test func japaneseFormatStringsKeepSpecifiers() throws {
        #expect(String(format: try japanese("%lld hr %lld min"), 2, 30) == "2時間30分")
        #expect(String(format: try japanese("%lld min"), 45) == "45分")
    }

    @Test func englishPluralization() throws {
        let format = try bundle("en").localizedString(forKey: "%lld items couldn't be loaded", value: nil, table: "Localizable")
        #expect(String(format: format, locale: AppLanguage.english.locale, 1) == "1 item couldn't be loaded")
        #expect(String(format: format, locale: AppLanguage.english.locale, 3) == "3 items couldn't be loaded")
    }

    @Test func appIconIsConfigured() throws {
        let icons = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let primary = try #require(icons["CFBundlePrimaryIcon"] as? [String: Any])
        #expect(primary["CFBundleIconName"] as? String == "AppIcon")
    }
}
