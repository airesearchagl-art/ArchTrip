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
        ]
        for (key, value) in expected {
            #expect(try japanese(key) == value, "\(key)")
        }
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
