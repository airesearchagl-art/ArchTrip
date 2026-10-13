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

    /// G6-UX-05-RF-Display-01: VoiceOver names the marker row's location and note lines.
    @Test func japaneseEventMarkerDetailStrings() throws {
        #expect(String(format: try japanese("Location: %@"), "Fixture address") == "場所：Fixture address")
        #expect(String(format: try japanese("Note: %@"), "Fixture note") == "メモ：Fixture note")
    }

    /// G6-UX-07: rental car clock-time controls and the derived marker rows; hotel strings unchanged.
    @Test func japaneseRentalCarClockTimeStrings() throws {
        let expected = [
            "Set pickup time": "貸出時刻を指定する", "Pickup time": "貸出時刻",
            "Set return time": "返却時刻を指定する", "Return time": "返却時刻",
            "Rental times": "貸出・返却の時刻", "Rental car pickup": "レンタカー貸出", "Rental car return": "レンタカー返却",
            "Shown on the timeline as pickup and return markers on their own days. The rental car itself stays under All-day & stays.":
                "時刻付きの予定一覧に、それぞれの日の貸出・返却の目印として表示します。レンタカー自体は「終日・滞在情報」に残ります。",
        ]
        for (key, value) in expected {
            #expect(try japanese(key) == value, "\(key)")
        }
        #expect(String(format: try japanese("Rental car: %@"), "Car") == "レンタカー：Car")
        #expect(try japanese("Stay times") == "宿泊の時刻")
        #expect(try japanese("Pickup day") == "利用開始日" && (try japanese("Return day")) == "返却日")
    }

    /// v0.2: Apple Maps place linking, lookup states and the unlink confirmation.
    @Test func japaneseApplePlaceStrings() throws {
        let expected = [
            "Apple Maps place": "Apple Mapsの場所", "Linked to Apple Maps": "Apple Mapsの場所を関連付け済み",
            "Unlink place": "場所を解除", "Unlink this place?": "この場所を解除しますか？",
            "Unlinking shows the stored address and coordinates again.": "解除すると保存済みの住所・座標の表示に戻ります。",
            "Unlinking leaves this building without a location.": "解除すると位置情報なしになります。",
            "Link this place": "この場所を関連付ける", "Confirm place": "候補の確認", "Can't be linked": "関連付けできない候補",
            "This place's ID can't be saved.": "この場所のIDは保存できません。",
            "Only the place's ID is saved. Its name, address and map are fetched from Apple Maps when shown.":
                "保存するのは場所のIDだけです。名称・住所・地図は表示時にApple Mapsから取得します。",
            "The stored address and coordinates aren't used while a place is linked. Unlinking shows them again.":
                "場所を関連付けている間、保存済みの住所・座標は使われません。解除すると再び表示されます。",
            "Search Apple Maps and link a place. Only its ID is saved.": "Apple Mapsを検索して場所を関連付けます。保存するのはIDだけです。",
            "This place ID can't be saved by this version. Unlink the place or update the app.":
                "この場所IDはこのバージョンでは保存できません。場所を解除するか、アプリを更新してください。",
            "Fetching place…": "場所を取得中…", "Place not available offline": "オフラインのため場所を取得できません",
            "Couldn't fetch the place": "場所を取得できませんでした", "Not found in Apple Maps": "Apple Mapsで見つかりません",
            "Retry": "再試行", "Place": "場所", "No location": "位置情報なし",
        ]
        for (key, value) in expected {
            #expect(try japanese(key) == value, "\(key)")
        }
        #expect(String(format: try japanese("A building for this place already exists: %@"), "Fixture") == "同じ場所の建築があります：Fixture")
        #expect(String(format: try japanese("Fetched at %@"), "10:00") == "取得時刻 10:00")
        #expect(String(format: try japanese("%lld buildings are waiting for their place."), 2) == "2件は場所を取得できていません")
        let waiting = try bundle("en").localizedString(forKey: "%lld buildings are waiting for their place.", value: nil, table: "Localizable")
        #expect(String(format: waiting, locale: AppLanguage.english.locale, 1) == "1 building is waiting for its place.")
        // Search no longer sets coordinates, so the old hint is gone.
        #expect(try japanese("No location (search to set one)") == "<missing>")
    }

    /// Place search sections (points of interest / addresses), their own empty and failure
    /// states, the no-ID reason and the note that a Building saves without a place.
    @Test func japanesePlaceSearchStrings() throws {
        let expected = [
            "Places": "施設候補", "Addresses": "住所候補", "Searching…": "検索中…",
            "No places found.": "施設候補はありません。", "No addresses found.": "住所候補はありません。",
            "Couldn't search places.": "施設候補を検索できませんでした。",
            "Couldn't search addresses.": "住所候補を検索できませんでした。",
            "This result can't be linked to a place.": "この検索結果は場所の関連付けに対応していません。",
            "You can save the building without linking a place.": "場所を関連付けなくても、建築名やメモを保存できます。",
            "This place's ID can't be saved.": "この場所のIDは保存できません。",
            "Search for a place or address": "場所名や住所で検索", "Search": "検索",
        ]
        for (key, value) in expected {
            #expect(try japanese(key) == value, "\(key)")
        }
        // The old wording and the single network message are gone: each section reports its own outcome.
        #expect(try japanese("This place has no ID.") == "<missing>")
        #expect(try japanese("Search needs a network connection. Try again later.") == "<missing>")
    }

    /// RF-03: the Trip deletion screen, its blockers and its failure wording.
    @Test func japaneseTripDeletionStrings() throws {
        let expected = [
            "Delete Trip": "出張を削除", "Delete this trip?": "この出張を削除しますか？",
            "What will be deleted": "削除される項目", "This can't be undone.": "この操作は取り消せません。",
            "Buildings are kept. They're shared across trips.": "建築は削除されません。建築は出張をまたいで共有されています。",
            "Checking the server…": "サーバーの内容を確認中…", "Check again": "再確認", "Deleted": "削除しました",
            "Not in sync with the server (offline, or changes not sent yet). Check the connection and try again once synced.": "サーバーと同期できていません（オフラインまたは未送信の変更）。接続を確認し、同期が終わってからやり直してください。",
            "Can't delete while offline. Connect and try again.": "オフラインのため削除できません。接続してからやり直してください。",
            "The server rejected the deletion.": "サーバーが削除を拒否しました。",
            "No reply from the server. The deletion may still complete once connected. Check again.":
                "サーバーの応答がありません。接続後に削除が完了することがあります。再確認してください。",
        ]
        for (key, value) in expected {
            #expect(try japanese(key) == value, "\(key)")
        }
        #expect(String(format: try japanese("%lld events"), 3) == "予定 3件")
        #expect(String(format: try japanese("Delete trip and %lld events"), 3) == "出張と予定3件を削除")
        #expect(String(format: try japanese("Deleting… %lld of %lld"), 1, 3) == "削除中… 1 / 3")
        #expect(String(format: try japanese("%lld of them can't be read and will be deleted too."), 1) == "うち1件は読み取れない予定ですが、同じく削除されます。")
        #expect(String(format: try japanese("This trip has too many events to delete here (%lld)."), 2_001) == "予定が多すぎるため、この画面では削除できません（2001件）。")
        #expect(try japanese("Deletion stopped after %lld events. The trip stays until all its events are gone.") == "<missing>")
        #expect(try japanese("Deletion stopped.") == "削除を中断しました。")
        #expect(String(format: try japanese("No reply from the server. A sent batch (%lld events and the trip) may still apply once connected."), 101) == "サーバーの応答がありません。送信済みの削除（予定101件と出張）は接続後に適用されることがあります。")
        #expect(String(format: try japanese("No reply from the server. A sent batch (%lld events) may still apply once connected."), 450) == "サーバーの応答がありません。送信済みの削除（予定450件）は接続後に適用されることがあります。")
        #expect(try japanese("The result couldn't be verified on the server. Check again before assuming anything was deleted.") == "削除結果をサーバーで確認できませんでした。再確認するまで削除済みとみなさないでください。")
        #expect(String(format: try japanese("%lld events and the trip are still there after verification."), 5) == "確認後も予定5件と出張が残っています。")
        #expect(String(format: try japanese("%lld events are still there after verification."), 5) == "確認後も予定5件が残っています。")
        #expect(String(format: try japanese("Confirmed deleted: %lld events and the trip"), 900) == "削除確認済み：予定900件と出張")
        #expect(String(format: try japanese("Confirmed deleted: %lld events"), 450) == "削除確認済み：予定450件")
        #expect(try japanese("The trip is deleted. Remaining events are deleted after checking again.") == "出張は削除済みです。残った予定は再確認後に削除できます。")
        #expect(try japanese("Whether the trip is deleted is not confirmed.") == "出張の削除は未確定です。")
        #expect(try japanese("The trip is still there.") == "出張は残っています。")
        #expect(try japanese("Check again waits for queued writes, then lists the server; only what is still there can be deleted.") == "再確認では未送信の書込みの完了を待ってからサーバーを再確認し、残っているものだけを削除できます。")
        let one = try bundle("en").localizedString(forKey: "Delete trip and %lld events", value: nil, table: "Localizable")
        #expect(String(format: one, locale: AppLanguage.english.locale, 1) == "Delete trip and 1 event")
        #expect(String(format: one, locale: AppLanguage.english.locale, 2) == "Delete trip and 2 events")
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
