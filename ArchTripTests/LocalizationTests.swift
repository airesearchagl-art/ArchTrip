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
            "Free time": "空き時間", "Settings": "設定", "Language": "言語",
            "Developer Diagnostics": "開発者診断", "Couldn't save changes": "変更を保存できませんでした",
            "Architecture": "建築", "Add to Trip": "出張に追加", "Open in Apple Maps": "Apple Mapsで開く",
            "Visit duration": "見学時間", "This building is no longer available": "この建築は削除されています",
        ]
        for (key, value) in expected {
            #expect(try japanese(key) == value, "\(key)")
        }
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
