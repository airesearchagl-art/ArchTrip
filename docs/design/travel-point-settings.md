# 移動区間の地点設定の再利用 — 設計（レビュー用・実装前）

対象 main: `886fcd7`（PR #15 / #16 merge 後）。本書は設計の提示であり、コード・Rules・実データは変更していない。
新しい永続項目の実装は Data Model Gate の確認後に、別 branch / Draft PR で行う。

## 0. 現状と課題

- 移動画面（`TravelView`）の地点は `TravelEndpoint` で解決する: 予定の建築に Place ID があれば `linkedPlace`、利用者が候補を選べば `candidate`、それ以外は `unresolved`（検索語のヒントのみ）。
- `candidate` は画面の `@State` にしかなく、画面を閉じると消える。ID のない住所候補を選んだ区間は、毎回検索からやり直しになる（Human 実機確認での課題）。
- 所要時間・距離・経路・検索結果は画面内限定で保存しない（D-024、PR #16 の方針）。本設計でもこの方針は変えない。

## 1. 保存モデル

### 1.1 採用案: Event の任意フィールド `travelPoint`

```text
users/{uid}/trips/{tripId}/events/{eventId}
  travelPoint: map（任意。無いときは未設定）
    kind: "place"           placeId: string   … 利用者が選んだ候補に Place ID があった場合。ID を無加工で保存（1〜128 文字、Building.applePlaceId と同じ上限）
    kind: "query"           query:   string   … ID のない候補を選んだ場合。利用者が検索欄に入力した文字列だけ（1〜200 文字、locationName と同じ上限）
```

- 地点は予定（Event）ごとに 1 つ。区間 A→B の出発地は A の、到着地は B の `travelPoint` を使うので、どの区間に現れても同じ設定が再利用される。
- 保存しないもの: Apple の検索結果に由来する名称・住所・座標、所要時間・距離・経路・ETA、検索結果、手段（車/徒歩/公共交通）、出発/到着の基準時刻。手段と時刻は画面を開くたびに既定（車、出発＝A の終了時刻）に戻る。
- `kind: "query"` に入るのは利用者が入力した文字列そのもの（検索欄の内容）。候補の名称や住所をコピーして入れることはしない。

Swift 側（実装時）:

```swift
/// 予定の移動地点の設定。候補の ID か、利用者が入力した検索語のどちらか一方だけ。
nonisolated enum TravelPointSetting: Codable, Hashable, Sendable {
    case place(id: String)      // {kind: "place", placeId}
    case query(String)          // {kind: "query", query}
}
// Event: var travelPoint: TravelPointSetting?   // 任意。optionalFields に "travelPoint" を追加
// Event.isValid: travelPoint が place なら id 1…128、query なら 1…200（Rules を鏡写し）
```

### 1.2 不採用案と理由

| 案 | 内容 | 不採用の理由 |
|---|---|---|
| B | 区間（A→B の組）ごとの文書 `trips/{tripId}/travel/{a_b}` | 予定の削除・並び替えで孤児が出る。A の地点は B 以外との区間でも同じであるべき |
| C | `users/{uid}/travelPoints/{eventId}` 別コレクション | Event と寿命が別になり、RF-03 の一括削除・予定削除と連動させる追加の Rules と掃除が要る |
| D | 端末ローカル保存（台帳と同方式） | 同一アカウントの別端末で再利用できない。Event の同期経路が既にある |
| E | 建築（Building）側に保存 | 予定に建築がない場合に置き場がない。建築は複数の予定で共有されるため、予定ごとの地点と合わない |

A（Event の任意フィールド）は寿命が予定と一致し、RF-03 の削除・予定削除・同期がそのまま使え、Rules 差分が最小になる。

## 2. 既存地点との連動（解決順序）

画面表示時の解決順。保存するのは 1 だけで、2 は参照のみ。

1. `Event.travelPoint` があればそれを使う（利用者の明示指定）。
   - `place`: 表示時に `PlaceDirectory` で ID から再取得（Building の Place ID と同じ経路: 取得中／失敗／再試行の表示あり）。名称・住所は取得結果を画面に出すだけで保存しない。
   - `query`: 検索欄に文字列を復元し、検索を自動実行する。候補は自動確定しない。利用者が選び直すまで地点は未確定。
2. なければ、予定の建築に `applePlaceId` があればその場所（PR #16 と同じ。参照のみで Event には何も書かない）。
   - 建築の関連付け変更・Place ID 変更・解除・削除は、表示のたびに建築を読むため自動で追従する。
3. どちらもなければ未確定。検索欄のヒントは従来どおり `locationName` か建築名。

明示指定（1）と建築の変更: 利用者が建築の場所ではなく候補を選んだ予定は、建築が変わっても明示指定を維持する（黙って利用者の選択を消さないため）。画面には「建築の場所ではなく、選んだ地点を使用中」と「建築の場所に戻す」（＝解除）を表示する。
→ レビュー論点 R1: 建築の Place ID が変わった場合に明示指定を自動解除する方が良いか。本設計は「維持＋表示」を提案。

## 3. 操作と各場面の扱い

| 場面 | 扱い |
|---|---|
| 候補を選ぶ（ID あり） | `travelPoint = place(id)` で Event を即時更新（`updateEvent`、`createdAt` 不変、`updatedAt` 更新）。 |
| 候補を選ぶ（ID なし） | `travelPoint = query(検索欄の文字列)` で即時更新。画面に「この候補には ID がないため保存できません。保存されるのは入力した検索語だけで、次回は候補を選び直す必要があります。」 |
| 地点の変更 | 選び直し＝上書き更新。 |
| 地点の解除 | `travelPoint = nil` で更新（`DocumentUpdate` が `FieldValue.delete()` を送る）。建築の場所か未確定に戻る。 |
| 旧経路の無効化 | 更新で `Event.updatedAt` が変わり、`TravelRequestKey` が不一致になるため既存ロジックで「条件が変わりました。再検索してください。」になる。結果は保存しない。 |
| 取消 | 候補ピッカーの「キャンセル」は何も書かない。移動画面の「完了」は保存操作ではない（選んだ時点で保存済み）。 |
| 予定の削除 | フィールドごと消える。RF-03 の一括削除でも同じ。 |
| 建築の変更・解除・削除 | 2 のとおり。明示指定は維持（R1）。 |
| サーバー拒否・オフライン | 既存の書込み経路と同じ: ローカルに即反映、サーバー拒否は「変更を保存できませんでした」で巻き戻し。 |
| アカウント | データは `users/{uid}` 配下にあり、端末のアカウント切替機能はない（サインアウト非対応）。同一アカウントの別端末では Event として同期され、ID は端末ごとに再取得する。端末ローカルには何も置かない。 |
| 画面の説明 | 地点セクションの脚注に「保存されるのは選んだ候補の ID、または入力した検索語だけです。名称・住所・座標・経路・所要時間は保存しません。」を常時表示。 |

## 4. Rules 差分（候補。公開は Human Gate）

`isValidEvent` の任意フィールドに `travelPoint` を加え、形を検証する。他は変更しない。

```diff
+    // Optional travel point of an Event (travel MVP): either a Place ID the user picked,
+    // kept verbatim, or the search text the user typed. Never a name, address or
+    // coordinates from Apple Maps, never a route or a time.
+    function isValidTravelPoint(p) {
+      return p is map
+        && (
+          (p.keys().hasOnly(['kind', 'placeId']) && p.keys().hasAll(['kind', 'placeId'])
+            && p.kind == 'place' && p.placeId is string && p.placeId.size() >= 1 && p.placeId.size() <= 128)
+          || (p.keys().hasOnly(['kind', 'query']) && p.keys().hasAll(['kind', 'query'])
+            && p.kind == 'query' && p.query is string && p.query.size() >= 1 && p.query.size() <= 200)
+        );
+    }
+
     function isValidEvent(tripId, eventId) {
       let d = request.resource.data;
       let fields = ['id', 'tripId', 'type', 'title', 'startDate', 'endDate', 'locationName', 'note', 'createdAt', 'updatedAt'];
-      return d.keys().hasOnly(fields.concat(['buildingId', 'isAllDay', 'checkInMinutes', 'checkOutMinutes', 'pickupMinutes', 'returnMinutes']))
+      return d.keys().hasOnly(fields.concat(['buildingId', 'isAllDay', 'checkInMinutes', 'checkOutMinutes', 'pickupMinutes', 'returnMinutes', 'travelPoint']))
         && d.keys().hasAll(fields)
         ...
         && (!('returnMinutes' in d) || isCarClockTime(d, d.returnMinutes))
+        && (!('travelPoint' in d) || isValidTravelPoint(d.travelPoint));
     }
```

- 文字数上限: `placeId` 128 は `Building.applePlaceId` と同じ防御的上限、`query` 200 は `locationName` と同じ。
- `kind` 以外のキーは `hasOnly` で閉じる（名称・住所・座標のキーは入れられない）。

## 5. 互換性

| 組合せ | 挙動 |
|---|---|
| 旧 build（`ab93b8e`〜`886fcd7`）× 新 Rules | 影響なし。旧 build は `travelPoint` を書かない。 |
| 旧 build が `travelPoint` 付き Event を読む | `Firestore.Decoder` は未知キーを無視するため読込・編集・保存できる。更新は `updateData` で既知フィールドだけを送るため `travelPoint` は保持される。 |
| 新 build × 旧 Rules（未公開） | `travelPoint` を含む更新は `hasOnly` で拒否され「変更を保存できませんでした」で巻き戻る。地点を保存しない操作は従来どおり動く。→ 順序: Rules 公開 → 公開後検証 → merge → 導入。 |
| RF-03（PR #15） | Event ごと削除されるため追加対応なし。 |

旧 build での実際の読込・編集・保存は、従来どおり「未検証」として残す（実装時に、未知キーのデコード耐性テストと「`updateData` で `travelPoint` が残る」統合テストを追加する）。

## 6. 検証計画（実装時）

- 単体: 解決順序（明示指定 > 建築 Place ID > 未確定）、建築変更・解除・削除への追従、`query` の復元と再選択要求、解除、`TravelPointSetting` のエンコード形（`kind` と 1 キーだけで、名称・住所・座標のキーが存在しない構造テスト）、更新で `updatedAt` が変わり経路キーが無効になること。
- Rules 統合（gated）: `place`/`query` の受理、両キー同時・未知キー・空・上限超過・`kind` 不正の拒否、`travelPoint` なしの従来形 Event の受理、`createdAt` 不変。
- シミュレータ受入（専用機・使い捨てユーザー・Fixture）: ①候補（ID あり）を選び画面を閉じて再表示→同じ地点が再取得される ②アプリ再起動後も同じ ③ID なし候補→検索語だけが復元され候補の選び直しを求められる ④候補ピッカーのキャンセルで何も変わらない ⑤解除で建築の場所／未確定に戻る ⑥建築の関連付けを解除／別の場所に変更→建築既定の地点が追従し、明示指定は維持される ⑦地点変更後に旧結果が「条件が変わりました」になる。
- 実機受入条件（Human）: 上記①〜⑦のうち ①②③⑤⑦ を実データではなく試用用の予定で確認。所要時間・経路が予定に保存されないことを予定編集画面で確認。

## 7. Human Gate と未決事項

- Data Model Gate: `Event.travelPoint` の追加（`06_Data_Model` の更新は Vault 側）。
- Rules Gate: 4 の差分の公開と公開後検証（既存 gated suite ＋ 新規 suite）。
- R1: 建築の Place ID 変更時に明示指定を維持するか自動解除するか（提案: 維持＋表示）。
- R2: 手段・時刻基準を保存するか（提案: 今回は保存しない）。
- 実装見積: 1.0〜1.5 人日（モデル・Rules・画面・テスト・シミュレータ確認）＋ Rules 公開/検証 ＋ 実機受入。
