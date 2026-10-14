# 移動区間の地点設定の再利用 — 設計（レビュー用・実装前）v2

対象 main: `886fcd7`（PR #15 / #16 merge 後）。本書は設計の提示であり、コード・Rules・実データは変更していない。
新しい永続項目の実装は Data Model Gate の確認後に、別 branch / Draft PR で行う。

改訂 v2（2026-10-14）: 設計レビューの Human 判断と修正依頼を反映。

- R1 確定: 明示指定は維持し、建築の既定地点より優先していることを表示する（自動解除しない）。
- R2 確定: 手段・出発／到着の基準時刻は今回保存しない。
- 追加: §3 地点だけの更新と競合処理、§4 検索語の出所、§5 読込み検証と書込み上限の分離、§7.2 旧 build 互換性の実検証計画、§8 文言、§9 状態遷移・検証表。

## 0. 現状と課題

- 移動画面（`TravelView`）の地点は `TravelEndpoint` で解決する: 予定の建築に Place ID があれば `linkedPlace`、利用者が候補を選べば `candidate`、それ以外は `unresolved`（検索語のヒントのみ）。
- `candidate` は画面の `@State` にしかなく、画面を閉じると消える。ID のない住所候補を選んだ区間は、毎回検索からやり直しになる（Human 実機確認での課題）。
- 所要時間・距離・経路・検索結果は画面内限定で保存しない（D-024、PR #16 の方針）。本設計でもこの方針は変えない。
- 現行の Event 更新は、編集画面が読み込んだ `Event` 全体を `updateData` で送る（`DocumentUpdate.fields(for:replacing:)`、`createdAt` 以外の全項目＋nil になった任意項目の `FieldValue.delete()`）。地点設定をこの経路に乗せると、古い `Event` の写しで他端末や別画面の変更を上書きし、編集画面の保存で地点設定を消す経路ができる。本設計はこの経路を使わない（§3）。

## 1. 保存モデル

### 1.1 採用案: Event の任意フィールド `travelPoint`

```text
users/{uid}/trips/{tripId}/events/{eventId}
  travelPoint: map（任意。無いときは未設定）
    kind: "place"   placeId: string  … 利用者が選んだ候補に Place ID があった場合。ID を無加工で保存
    kind: "query"   query:   string  … ID のない候補を選んだ場合。利用者自身が入力した検索語だけ（§4）
```

- 地点は予定（Event）ごとに 1 つ。区間 A→B の出発地は A の、到着地は B の `travelPoint` を使うので、どの区間に現れても同じ設定が再利用される。
- 保存しないもの: Apple の検索結果に由来する名称・住所・座標、所要時間・距離・経路・ETA、検索結果、手段（車/徒歩/公共交通）、出発/到着の基準時刻（R2）。手段と時刻は画面を開くたびに既定（車、出発＝A の終了時刻）に戻る。
- 文字数: `placeId` 128、`query` 200 は候補選択時・書込み時の防御上限であって Apple の形式仕様ではない（`Building.applePlaceIdMaxLength` と同じ扱い）。読込みでは長さを理由に拒否しない（§5）。

Swift 側（実装時の形）:

```swift
/// 予定の移動地点の設定。文書から読める形は 3 つ、書けるのは place / query の 2 つだけ。
nonisolated enum TravelPointSetting: Hashable, Sendable {
    case place(id: String)            // {kind: "place", placeId}  ID は無加工
    case query(String)                // {kind: "query", query}    利用者が入力した検索語
    /// 文書に travelPoint はあるが形が不正（map でない／kind 未知／型不正／余分なキー／空文字／破損）。
    /// 予定全体は読める。この値を書き戻す経路はない（解除か選び直しだけ、§5）。
    case unreadable(reason: String)
}
// Decodable: init(from:) は投げない。読めなければ .unreadable(reason)。
// Event:    var travelPoint: TravelPointSetting?   // 読込み専用。Event の encode には含めない
// Event.optionalFields は変更しない（編集画面の全項目更新で削除も再送もされないため、§3.1）
// Event.isValid は travelPoint を見ない（読込み・表示を妨げないため）。
// Event.travelPointIsWritable: place の id ≤128 かつ query ≤200 かつ unreadable でない（書込み時の判定、§5）
```

### 1.2 不採用案と理由

| 案 | 内容 | 不採用の理由 |
|---|---|---|
| B | 区間（A→B の組）ごとの文書 `trips/{tripId}/travel/{a_b}` | 予定の削除・並び替えで孤児が出る。A の地点は B 以外との区間でも同じであるべき |
| C | `users/{uid}/travelPoints/{eventId}` 別コレクション | Event と寿命が別になり、RF-03 の一括削除・予定削除と連動させる追加の Rules と掃除が要る |
| D | 端末ローカル保存（台帳と同方式） | 同一アカウントの別端末で再利用できない。Event の同期経路が既にある |
| E | 建築（Building）側に保存 | 予定に建築がない場合に置き場がない。建築は複数の予定で共有されるため、予定ごとの地点と合わない |
| F | 編集画面と同じ「Event 全体を `updateData`」で書く | 古い写しで他の項目を上書きし、編集画面の保存が地点設定を消す（§0、§3） |

A（Event の任意フィールド＋専用の項目限定更新）は寿命が予定と一致し、RF-03 の削除・予定削除・同期がそのまま使え、Rules 差分が最小になる。

## 2. 既存地点との連動（解決順序）

画面表示時の解決順。保存するのは 1 だけで、2 は参照のみ。

1. `Event.travelPoint` があればそれを使う（利用者の明示指定）。
   - `place`: 表示時に `PlaceDirectory` で ID から再取得（建築の Place ID と同じ経路: 取得中／失敗／再試行の表示あり）。名称・住所は取得結果を画面に出すだけで保存しない。
   - `query`: 検索欄に文字列を復元し、検索を自動実行する。候補は自動確定しない。利用者が選び直すまで地点は未確定（§8 の説明文を表示）。
   - `unreadable`: 地点は未確定。建築の既定地点には黙って戻さず、問題と解除／選び直しの導線を表示する（§5）。
2. なければ、予定の建築に `applePlaceId` があればその場所（PR #16 と同じ。参照のみで Event には何も書かない）。
   - 建築の関連付け変更・Place ID 変更・解除・削除は、表示のたびに建築を読むため自動で追従する。
3. どちらもなければ未確定。検索欄のヒントは従来どおり `locationName` か建築名（自動ヒント。§4 のとおり保存対象ではない）。

明示指定と建築（R1 確定）: 利用者が候補を選んだ予定は、建築の関連付け・Place ID が変わっても明示指定を維持し、自動解除しない。画面には「建築の場所ではなく、選んだ地点を使用中」を表示し、解除ボタンの文言は建築の既定地点がある場合「建築の場所に戻す」、ない場合「地点設定を解除」とする（§8）。

## 3. 地点だけの更新と競合処理

### 3.1 書込み経路

- 新設: `TripStore.setTravelPoint(_ setting: TravelPointSetting?, event: Event, uid:, serverAcknowledged:)`。送るのは次の 2 項目だけ。

```swift
// 設定・変更
updateData(["travelPoint": ["kind": "place", "placeId": id],       // または ["kind": "query", "query": text]
            "updatedAt":   Timestamp(date: max(Date(), event.createdAt))])
// 解除（現在のローカル表示に travelPoint がある場合だけ送る。無いときは何も送らない）
updateData(["travelPoint": FieldValue.delete(),
            "updatedAt":   Timestamp(date: max(Date(), event.createdAt))])
```

- `title`、日時、`locationName`、`note`、`buildingId`、全日フラグ、時刻項目、`createdAt` は送らない。サーバーは項目単位で統合するため、他の項目は書いた時点の値を保たない（＝上書きしない）。
- `Event` の `encode(to:)` は `travelPoint` を出力しない。したがって編集画面の `updateEvent`（全項目更新）も `createEvent` も `travelPoint` を送らず、`optionalFields` に無いので `FieldValue.delete()` も送らない。編集画面で保存しても地点設定は保持される。構造テストで固定する（§9.3）。
- `updatedAt` を更新するのは、既存の `TravelRequestKey`（`fromEventUpdatedAt` / `toEventUpdatedAt` を含む）が不一致になり、旧経路結果が「条件が変わりました。再検索してください。」になるため。結果は保存しない。
- `AppSession.setTravelPoint(_:for:)` は既存の `write(_:_:)` を使う: ローカルキャッシュへ即時反映、サーバーの可否は後から `handleServerResult` → `saveFailure`（既存の「変更を保存できませんでした」アラート）。アプリ側で独自の巻戻しは行わない（§3.3）。

### 3.2 同一性と無操作

- 選んだ設定が現在のローカル表示（`events` の該当 Event の `travelPoint`）と等しければ何も送らない。`updatedAt` も変わらず、表示中の結果は無効化されない。
- 「同じ地点への連続操作」はこの規則で無操作になる。異なる地点への連続操作はそれぞれ独立した更新で、最後に ACK されたものが残る（サーバーは受信順に適用）。

### 3.3 競合・遅延・画面終了・削除・別端末

前提（Firestore SDK の挙動。§9.2 の統合テストで確認し、異なれば設計へ戻す）: `updateData` は 1 件ずつ独立した書込みとしてローカルに即時反映され、サーバーが拒否した書込みはその 1 件だけがローカルから取り消され、残りの未送信・送信済み書込みはそのまま順に適用される。アプリは「取り消し」を自分では行わず、リスナーが届ける再計算後の Event を表示する。

| 場面 | 扱い |
|---|---|
| 同じ地点を続けて選ぶ | 無操作（§3.2）。 |
| 別の地点を続けて選ぶ（1 件目の返答前） | 2 件とも送る。画面は常にローカル表示（最新）を示す。 |
| 遅れて届く保存成功 | ログ「Server acknowledged …」のみ。画面を閉じていても同じ。 |
| 遅れて届く保存失敗（Rules 拒否・not-found 等） | その 1 件だけ取り消され、アラート「変更を保存できませんでした」。後から送った新しい選択は残る（取り消されるのは拒否された 1 件だけ）。画面が開いていればリスナー経由で復元後の状態を表示する。 |
| 古い失敗による巻戻しで新しい選択が消えないこと | 上の規則と、アプリが写しを書き戻さないこと（§3.1）で保証。§9.2 の「先に不正、後に正常」テストで確認。 |
| 画面終了（完了・スワイプ） | 送信済みの書込みは取り消さない。候補ピッカーのキャンセルは何も送らない。 |
| 予定の削除（この端末・別端末）: 選ぶ前 | `events` に無い → 「この予定は利用できなくなりました」を表示し、選択・解除ボタンを出さない。何も送らない。 |
| 予定の削除: 送信後 | サーバーが not-found で拒否 → アラート。文書は無いままで、復元するものはない。 |
| 別端末が他の項目を編集 | 項目単位で統合され両方残る（旧 build の編集画面は `travelPoint` を知らず送らない、新 build の編集画面は送らない）。リスナーで `updatedAt` が変わり結果は無効化。 |
| 別端末が同じ予定の地点を変更 | 最後に ACK された設定が残る。画面はリスナー表示に従う。 |
| この端末で編集画面と移動画面を続けて使う | 互いに素な項目（`updatedAt` だけ両方が書く。後勝ちで無害）。両方残る。 |
| 同時にネットワーク断（全件未送信） | 再接続後に受信順で適用。拒否された件だけ取り消し。 |
| RF-03 一括削除・予定削除 | フィールドごと消える。追加対応なし。 |
| アカウント | データは `users/{uid}` 配下。端末のアカウント切替機能はない（サインアウト非対応）。同一アカウントの別端末では Event として同期され、ID は端末ごとに再取得。端末ローカルには何も置かない。 |

### 3.4 画面側の表示遷移

選択直後は候補を画面上で保持し（現在の `candidate` と同じ）、リスナーが同じ設定を持つ Event を届けた時点で「保存済み」の表示に切り替える（ローカル反映は通常即時）。候補の名称・住所は表示だけで保存しない。

## 4. 検索語の出所

### 4.1 規則

- 検索欄の文字列には 3 つの出所がある。
  - 自動ヒント: `locationName`、建築名、または「この検索だけ」の候補の名称／住所（`TravelEndpoint.hint`）。画面が自動で入れる。
  - 保存済み: `travelPoint.query` の復元。
  - 手入力: 利用者が検索欄を変更した後の文字列。
- 候補ピッカーは出所を追跡する: 初期値は保存済み（あれば）か自動ヒント。文字列が変わるたびに、自動ヒントと一致すれば「自動」、保存済みと一致すれば「保存済み」、それ以外は「手入力」。検索欄にあるだけでは利用者入力とみなさない。
- ID なし候補を選んだとき `query` として保存するのは「手入力」の文字列だけ。「保存済み」は既に保存済みなので無操作。「自動」は保存しない。
- 候補の名称・住所を `query` へ入れる経路はコード上に設けない。ピッカーが呼出し元へ返すのは `(選んだ候補, 保存する検索語?)` で、検索語は検索欄の手入力文字列からだけ作る。構造テストで候補の名称・住所が保存マップに現れないことを固定する（§9.1）。
- 自動ヒントを変更せずに ID なし候補を選んだ場合: 候補は「この検索だけ」に使い、何も保存しない。画面に「検索語は自動入力のため保存されません。この検索だけに使います。保存するには検索語を自分で入力してください。」を表示する。
- ID あり候補を選んだときは検索語を保存しない（`placeId` だけ）。

### 4.2 保存可否のテスト表

| # | 検索欄の文字列の出所 | 候補 | 保存 | 備考 |
|---|---|---|---|---|
| Q1 | 空欄に手入力 | ID なし | `query(入力文)` | |
| Q2 | 自動ヒント（`locationName`）未変更 | ID なし | 保存しない | 説明文を表示 |
| Q3 | 自動ヒント（建築名）未変更 | ID なし | 保存しない | 同上 |
| Q4 | 「この検索だけ」の候補由来のヒント未変更 | ID なし | 保存しない | 候補の名称／住所は自動扱い |
| Q5 | 自動ヒントを一部編集 | ID なし | `query(編集後の全文)` | 手入力扱い |
| Q6 | 自動ヒントを編集後、同じ文字列に戻した | ID なし | 保存しない | 自動ヒントと一致 |
| Q7 | 自動ヒントと同じ文字列を手で打った | ID なし | 保存しない | 区別できないため保守的に自動扱い。説明文で案内 |
| Q8 | 保存済み `query` を復元、未変更 | ID なし | 無操作 | 既に保存済み |
| Q9 | 保存済み `query` を編集 | ID なし | `query(編集後)` | |
| Q10 | 任意 | ID あり | `place(id)` | 検索語は保存しない |
| Q11 | 候補の名称／住所 | — | 経路なし | 構造テストで固定 |
| Q12 | 空白のみ | ID なし | 保存しない | 検索自体が無効 |
| Q13 | 手入力 201 文字以上 | ID なし | 保存しない | 「検索語が長すぎます（200 文字まで）」。候補はこの検索だけに使う |
| Q14 | 手入力 | ID が 129 文字以上 | 保存しない | 「この候補の ID は長すぎて保存できません。この検索だけに使います。」（§5） |

## 5. 読込み検証と書込み上限の分離

### 5.1 読込み（拒否しない）

- `Event` のデコードは `travelPoint` の内容で失敗しない。`place` の ID は長さに関係なく無加工で保持し、`query` も同様。形が不正なら `.unreadable(reason)` にして予定全体は読む。
- `Event.isValid`（`TripStore` の読込み検証・編集画面の保存判定）は `travelPoint` を見ない。
- 保存済みの長い ID（129 文字以上）を持つ予定: 一覧・編集画面・移動画面に通常どおり表示される。移動画面では ID で再取得し、経路検索にも使える。

| 文書の `travelPoint` | 読込み結果 | 移動画面の表示 |
|---|---|---|
| map で `kind:"place"`, `placeId` 1〜128 文字 | `place(id)` | 通常 |
| map で `kind:"place"`, `placeId` 129 文字以上 | `place(id)`（無加工） | 通常の取得表示＋注意「保存済みの場所 ID がこのバージョンの上限（128 文字）を超えています。表示と経路検索には使えますが、この予定の編集を保存するには解除が必要です。」＋解除 |
| map で `kind:"query"`, `query` 1〜200 文字 | `query(text)` | 検索欄に復元 |
| map で `kind:"query"`, 201 文字以上 | `query(text)` | 検索欄に復元＋同種の注意＋解除 |
| map でない（string／number／array） | `unreadable("not a map")` | §5.2 |
| `kind` 無し／未知（例 `"coordinate"`） | `unreadable("unknown kind")` | §5.2 |
| `place` で `placeId` 無し／string でない／空 | `unreadable("invalid placeId")` | §5.2 |
| `query` で `query` 無し／string でない／空 | `unreadable("invalid query")` | §5.2 |
| 余分なキー（`name`、`address`、`latitude` 等。`kind`/`placeId` が正しくても） | `unreadable("unexpected keys")` | §5.2。余分なキーの値は表示しない |
| 両方のキー（`placeId` と `query`） | `unreadable("unexpected keys")` | §5.2 |

### 5.2 不正な設定の表示と修復

- 表示: 「保存済みの地点設定を読み込めません（形式が不正）。建築の場所には自動で戻しません。」＋理由の短い英字コード（開発者向け、ID や値は出さない）。
- 導線: 「地点設定を解除」（`FieldValue.delete()`＋`updatedAt`。フィールドは存在するので送る）と「候補を選ぶ」（選び直し＝上書き）。どちらも利用者の操作でだけ起きる。自動修復・自動削除はしない。
- 解除するまで、その側は未確定（経路検索不可）。建築の既定地点は使わない（黙ってフォールバックしない）。

### 5.3 書込み時の阻止

- 候補選択時: ID が 129 文字以上の候補は保存しない（Q14）。候補自体は座標で経路検索できるので「この検索だけ」に使う。手入力の検索語が 201 文字以上なら保存しない（Q13）。
- 編集画面: Rules は更新後の文書全体を検証する（§6）ため、保存済みの `travelPoint` が上限超過／不正なまま他の項目を保存すると Rules が拒否する。`Building.applePlaceIdExceedsLimit` と同じく、編集画面は `event.travelPointIsWritable == false` のとき保存を無効化し「この予定の地点設定はこのバージョンでは保存できません。移動画面で地点設定を解除するか、アプリを更新してください。」を表示する。予定の削除・RF-03 は影響を受けない。
- 旧 build（`travelPoint` を知らない）で同じ予定を編集・保存した場合は Rules 拒否で「変更を保存できませんでした」になり、旧 build からは修復できない（§7.2 の制限として記録）。

→ レビュー論点 R3: Rules を「`travelPoint` が変更されたときだけ検証」（`request.resource.data.diff(resource.data).affectedKeys().hasAny(['travelPoint'])`）にすれば、上限超過／不正な保存済み設定があっても他の項目の編集は通る。提案は Building と同じ「文書全体を検証＋編集画面で阻止・解除案内」（Rules が単純で、既存 Building の扱いと揃う）。

## 6. Rules 差分（候補。公開は Human Gate）

`isValidEvent` の任意フィールドに `travelPoint` を加え、形を検証する。他は変更しない。Rules の `request.resource.data` は更新後の文書全体なので、§3.1 の 2 項目だけの `updateData` でも、統合後の文書が `isValidEvent` を満たすかで判定される（`createdAt` は送らないので不変条件を満たす）。

```diff
+    // Optional travel point of an Event (travel MVP): either a Place ID the user picked,
+    // kept verbatim, or the search text the user typed. Never a name, address or
+    // coordinates from Apple Maps, never a route or a time. The 128 / 200 are this
+    // project's write-time bounds (Event.travelPointPlaceIdMaxLength / queryMaxLength),
+    // not an Apple format; reading never checks them.
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

- `kind` 以外のキーは `hasOnly` で閉じる（名称・住所・座標のキーは入れられない）。
- 解除（`FieldValue.delete()`）後の文書には `travelPoint` が無いので、上限超過／不正な保存済み設定でも解除は通る。

## 7. 互換性

### 7.1 組合せ

| 組合せ | 挙動 |
|---|---|
| 旧 build（`ab93b8e`〜`886fcd7`）× 新 Rules | 旧 build は `travelPoint` を書かない。更新は `updateData` で既知項目だけを送り、`optionalFields` に無いので削除も送らない → 保持される（§7.2 で実検証）。 |
| 旧 build が `travelPoint` 付き Event を読む | `Firestore.Decoder` は未知キーを無視するため読込・編集・保存できる（§7.2 で実検証）。旧 build の移動画面は設定を知らず、建築既定／未確定として扱う（制限）。 |
| 旧 build × 上限超過／不正な `travelPoint` | 旧 build の編集保存は Rules 拒否（§5.3）。旧 build では修復不可。クライアントからは Rules を通らず作れないため、§7.2 の対象外（未検証として記録）。 |
| 新 build × 旧 Rules（未公開） | `travelPoint` を含む更新は `hasOnly` で拒否され「変更を保存できませんでした」。その 1 件だけ取り消される。地点を保存しない操作は従来どおり動く。 |
| RF-03（PR #15） | Event ごと削除されるため追加対応なし。 |

順序: Rules 公開 → 公開後検証（gated suite）→ 旧 build 実検証（§7.2）→ merge → 導入。

### 7.2 旧 build 互換性の実検証計画

デコーダ単体と新コードの統合テストだけでは「旧 build 互換 PASS」としない。次を実施するまで「旧 build 互換: 未検証」と明記する。

- 前提: 新 Rules 公開済み。使い捨てユーザー、Fixture Trip、Fixture Event 3 件（`place` 付き／`query` 付き／なし）を、新 build 側の gated 支援テスト（secondary FirebaseApp）で作成。実データは使わない。
- 旧 build: `git worktree` で `886fcd7` を取り出し、別 DerivedData（`$S/DD-old`）で Debug ビルドし、専用シミュレータ（実行ごとに作成・削除）へ導入。使い捨てユーザーでサインイン。
- 確認項目（それぞれ結果とスクリーンショットを記録）:
  1. 出張一覧・予定一覧に Fixture 3 件が表示され、読込み失敗の表示が無い。
  2. `place` 付き Event の編集画面を開き、利用者項目（title と note）を編集して保存。開発者ログに「Server acknowledged update event …」が出る（server ACK）。
  3. 支援テストで生文書を `getDocument(source: .server)` で読み、`travelPoint` の map が作成時と同一（キー・値とも無加工）で、title／note が更新済み。
  4. `query` 付き Event で 2〜3 を繰り返す。
  5. 旧 build の移動画面で `place` 付き Event を出発地にし、設定が使われず建築既定／未確定になることを記録（制限の確認）。
  6. 後片付け: Fixture と使い捨てユーザーを削除、worktree と DerivedData を削除。
- 記録する制限: 旧 build では新地点設定を表示・利用・編集できない。上限超過／不正な設定を持つ予定は旧 build では保存できず修復もできない。

## 8. 文言（日本語。英語キーは実装時に xcstrings へ）

| 場面 | 文言 |
|---|---|
| 地点セクションの脚注（常時） | 保存されるのは選んだ候補の ID か、入力した検索語だけです。名称・住所・座標・経路・所要時間は保存しません。 |
| 明示指定が建築の既定より優先 | 建築の場所ではなく、選んだ地点を使用中 |
| 解除ボタン（建築の既定地点あり） | 建築の場所に戻す |
| 解除ボタン（建築の既定地点なし） | 地点設定を解除 |
| ID なし候補＋手入力検索語を保存したとき | この候補には ID がないため、保存されるのは入力した検索語だけです。次回は検索語が検索欄に戻り、候補を選び直す必要があります。 |
| 保存済み `query` の復元時 | 前回の検索語を復元しました。候補を選び直してください（候補は保存されていません）。 |
| ID なし候補＋自動ヒント未変更 | 検索語は自動入力のため保存されません。この検索だけに使います。保存するには検索語を自分で入力してください。 |
| 候補の ID が 129 文字以上 | この候補の ID は長すぎて保存できません。この検索だけに使います。 |
| 検索語が 201 文字以上 | 検索語が長すぎます（200 文字まで）。この検索だけに使います。 |
| 保存済み ID／検索語が上限超過 | 保存済みの場所 ID がこのバージョンの上限（128 文字）を超えています。表示と経路検索には使えますが、この予定の編集を保存するには解除が必要です。（検索語は「200 文字」で同形） |
| 設定が読めない | 保存済みの地点設定を読み込めません（形式が不正）。建築の場所には自動で戻しません。 |
| 編集画面の保存阻止 | この予定の地点設定はこのバージョンでは保存できません。移動画面で地点設定を解除するか、アプリを更新してください。 |
| 予定が無い | この予定は利用できなくなりました（既存） |
| 保存失敗 | 変更を保存できませんでした（既存アラート。取り消されるのは拒否された 1 件だけ） |

自動解除の文言は設けない（R1）。

## 9. 状態遷移・検証表

### 9.1 保存状態の遷移

保存状態: なし / `place(id)` / `query(text)` / `unreadable`。画面だけの状態: 候補（この検索だけ）。

| 現在の保存状態 | 操作 | 送る書込み | 次の保存状態 | 画面 |
|---|---|---|---|---|
| 任意 | ID あり候補を選ぶ（ID ≤128） | `travelPoint=place`, `updatedAt` | `place(id)` | 保存済み表示、旧結果は無効化 |
| `place(id)` と同じ | 同じ ID の候補を選ぶ | なし | 変化なし | 結果は有効のまま |
| 任意 | ID あり候補（ID ≥129）を選ぶ | なし | 変化なし | 候補をこの検索だけに使う＋Q14 文言 |
| 任意 | ID なし候補＋手入力検索語（≤200） | `travelPoint=query`, `updatedAt` | `query(text)` | 候補をこの検索だけに使う＋説明 |
| `query(text)` と同じ | ID なし候補＋保存済み検索語未変更 | なし | 変化なし | 候補をこの検索だけに使う |
| 任意 | ID なし候補＋自動ヒント未変更 | なし | 変化なし | 候補をこの検索だけに使う＋自動入力の説明 |
| `place` / `query` / `unreadable` | 解除 | `travelPoint=delete`, `updatedAt` | なし | 建築既定／未確定へ、旧結果は無効化 |
| なし | 解除 | なし（ボタン無し） | なし | — |
| 任意 | ピッカーのキャンセル | なし | 変化なし | — |
| 任意 | 建築の関連付け・Place ID 変更／解除／削除 | なし（建築側の操作のみ） | 変化なし | 建築既定だけ追従。明示指定は維持＋優先表示 |
| 任意 | 予定の編集画面で保存（他項目） | 編集画面の更新（`travelPoint` を含まない） | 変化なし | `updatedAt` 変化で旧結果は無効化 |
| 上限超過／`unreadable` | 予定の編集画面で保存 | なし（保存無効化） | 変化なし | 阻止文言 |
| 任意 | 予定の削除／RF-03 | 文書削除 | 文書ごと消滅 | 「この予定は利用できなくなりました」 |
| 任意 | 別端末の更新を受信 | なし | 受信した値 | リスナー表示に従う、旧結果は無効化 |

書込み 1 件の遷移: 送信（ローカル即時反映）→ ACK（ログ）／拒否（その 1 件だけ取り消し＋アラート）。拒否された件より後の書込みは影響を受けない。

### 9.2 検証表

| 区分 | 内容 | 方法 |
|---|---|---|
| 単体（モデル） | `travelPoint` の全形（§5.1 の表）が投げずにデコードされ、`place`/`query`/`unreadable` になる。129 文字 ID と 201 文字 query が読める。`Event.isValid` が影響を受けない | `EventTests`／`DocumentDecodingTests` |
| 単体（構造） | `Event` の encode に `travelPoint` キーが無い。`DocumentUpdate.fields(for:replacing:)` が `travelPoint` を送らず削除もしない（`optionalFields` 不変）。`setTravelPoint` の送信マップが `travelPoint` と `updatedAt` の 2 キーだけ。保存マップに候補の名称・住所・座標の文字列が現れない（番兵文字列） | `DocumentUpdateTests` 追加、新規 `TravelPointTests` |
| 単体（出所） | §4.2 Q1〜Q14 | 新規 `TravelPointTests`（ピッカーの出所判定を純粋関数に切り出す） |
| 単体（解決順） | 明示指定 > 建築 Place ID > 未確定、建築変更後も明示指定維持、`unreadable` で建築既定へ戻らない、解除ボタン文言の切替（建築既定あり／なし）、同一設定で無操作、設定変更で `TravelRequestKey` 不一致 | `TravelSearchTests` 追加 |
| Rules 統合（gated） | `place`/`query` の受理、両キー・未知キー・空・上限超過・`kind` 不正・map でない値の拒否、従来形 Event の受理、`createdAt` 不変、2 項目だけの `updateData` が通る、解除の `delete` が通る | 新規 `FirebaseTravelPointIntegrationTests` |
| 競合（gated） | 先に不正（129 文字 ID をテストから直接送る）→ 後に正常、両方 ACK 後にサーバー・ローカルとも後者。編集画面の全項目更新の前後で `travelPoint` が保持。オフラインで「編集→地点設定」「地点設定→編集」を積んで再接続後に両方残る。削除済み文書への設定が not-found で可視に失敗 | 同上 |
| シミュレータ受入（専用機・使い捨てユーザー・Fixture） | ①ID あり候補→閉じて再表示→同じ地点が再取得 ②アプリ再起動後も同じ ③ID なし＋手入力→検索語だけ復元、再選択を求める ④ID なし＋自動ヒント未変更→保存されず説明 ⑤ピッカーのキャンセルで変化なし ⑥解除で建築の場所／未確定へ（文言の切替） ⑦建築の関連付けを変更→建築既定が追従し明示指定は維持＋優先表示 ⑧地点変更後に旧結果が「条件が変わりました」 ⑨地点設定後に編集画面で title／note を変更・保存→両方残る（生文書でも確認） ⑩129 文字 ID 候補の拒否（Debug 用検索フック）⑪長い保存済み ID／不正 map の表示・解除・編集画面の阻止（Debug 用読込みフックで表示経路。実文書での確認は R5） | XCUITest プローブ（既存方式） |
| 旧 build 実検証 | §7.2 | 旧 build 専用シミュレータ |
| 実機受入条件（Human） | ①②③⑥⑧⑨ を試用用の予定で確認。所要時間・経路が予定に保存されないことを編集画面で確認。設定が優先表示と解除文言どおりに出ること | 実機 |

### 9.3 固定する不変条件（テストで常時）

- `Event` の encode に `travelPoint` が無い。`optionalFields` に `travelPoint` が無い。
- `setTravelPoint` の送信は `travelPoint` と `updatedAt` だけ。
- `query` に入る文字列は検索欄の手入力だけ。候補の名称・住所・座標はどの保存マップにも現れない。
- `.unreadable` を書き戻す経路がない（Encodable が throw）。
- 読込みは長さ・形で失敗しない。

## 10. Human Gate と未決事項・見積

- Data Model Gate: `Event.travelPoint` の追加（`06_Data_Model` の更新は Vault 側）。
- Rules Gate: §6 の差分の公開と公開後検証（既存 gated suite ＋ 新規 suite）、続けて §7.2 の旧 build 実検証。
- 確定: R1 維持＋優先表示（自動解除なし）、R2 手段・時刻は保存しない。
- R3: Rules を文書全体検証（提案）か、`travelPoint` 変更時だけ検証（`diff().affectedKeys()`）にするか。
- R4: ID が 129 文字以上の候補を「この検索だけに使う」（提案）か、Building 編集と同じくグレー表示で選べなくするか。
- R5: 長い保存済み ID／不正 map の実文書はクライアントから Rules を通して作れない。使い捨てユーザーの Fixture に Console で値を入れる Human 操作で確認するか、表示経路は Debug 用読込みフックだけで確認し実文書は未検証として残すか。
- 実装見積: 2.0〜2.5 人日（モデルと許容デコード、専用更新経路、出所追跡付きピッカー、画面と文言、編集画面の阻止、単体・構造・gated テスト、Debug 用フック、シミュレータ確認）＋ Rules 公開/検証（Human）＋ 旧 build 実検証 0.5 人日 ＋ 実機受入（Human）。
