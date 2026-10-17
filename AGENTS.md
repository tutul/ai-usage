# AGENTS.md

給在此 repo 工作的 agent。**先讀這份，再動程式碼。**

## 這是什麼

常駐 macOS menu bar 的用量追蹤器：每 5 分鐘抓取 Claude 與 Codex 訂閱的
**weekly 用量百分比**，存進本機 SQLite，提供可回溯的小時／日／週消耗圖表。

- 詳細架構 → [docs/architecture.md](docs/architecture.md)
- 工程慣例 → [docs/conventions.md](docs/conventions.md)
- 為什麼是現在這樣 → [docs/history/decisions.md](docs/history/decisions.md)
- 現況 → [docs/status.md](docs/status.md)
- 下一步 → [docs/TODO.md](docs/TODO.md)

## 指令

```bash
# 域邏輯與資料層測試（快，不需啟動 app，先跑這個）
cd Packages/AIUsageKit && swift test

# 建置 .app
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug \
  -derivedDataPath .build/xcode build

# 重新啟動（改完一定要重啟才會生效）
pkill -f 'AIUsage.app/Contents/MacOS/AIUsage'
open .build/xcode/Build/Products/Debug/AIUsage.app
```

## 不可違反的原則

這些不是風格偏好，是這個專案存在的理由。違反了，資料就沒有價值。

1. **無資料 ≠ 0。** 沒有樣本的區間不產生列、不畫點、不補 0，折線在那裡斷開。
   「有取樣但用量沒變」與「完全沒取樣」必須在 UI 上可分辨。
2. **樣本不可變。** `sample` 只寫入，不更新、不刪除。所有推導（delta、gap、
   窗身分）都在查詢時由 SQL view 計算 —— 推導錯了改 view，資料不用動。
   這條原則已經救過兩次（見 decisions.md 的 D-007、D-008）。
3. **絕不寫入合成樣本。** 抓不到就是抓不到。寫一筆假的 0 會被判成窗重置，
   讓後續讀數整包灌進單一小時，並使該窗總量顯示為 0。
4. **時間戳 = HTTP 回應成功的真實時刻。** 不是排程時刻，不是呼叫開始時刻。
   永遠不回填過去時段的資料點。
5. **失敗要留痕且分類正確。** `auth`(401) / `blocked`(403 風控) /
   `rate_limited`(429) / `network` / `http` / `parse` / `missing_window`
   的補救方式完全不同，混為一談會害人查錯方向。
   `slept` 與 `offline` 是**沒有觀測**，不是失敗 —— 不計入健康度，但照樣留痕。
6. **Migration 只增不改。** 已套用的 `NNN_*.sql` 不得修改 —— 既有資料庫不會重跑。

## 踩過的坑（別再踩一次）

| 坑 | 症狀 | 正解 |
|---|---|---|
| `cp` 複製 WAL 資料庫 | 拿到的是舊資料（實測差 4 小時），害你誤判邏輯有問題 | `sqlite3 src ".backup dst"` |
| SF Symbols 名稱打錯 | **不報錯**，只是畫空白 | 加符號前先用 `NSImage(systemSymbolName:)` 驗證存在 |
| `RuleMark(x:)` 單參數 | 被解析成 3D 圖表多載，編譯失敗 | 用 `chartOverlay` 自繪，別硬碰 |
| User-Agent 沒帶對 | Claude 落入嚴格限流桶持續 429；Codex 被 Cloudflare 擋成 403 HTML | UA 是承載性的，見 `UserAgent` |
| 以欄位位置認窗 | 5 小時的數字被靜默寫進 weekly 序列 | 一律以 `limit_window_seconds` 判定 |
| 在「零用量」資料上推論窗行為 | 得出「滾動窗」的錯誤結論 | 推論前先問：資料涵蓋了要推論的變項變化嗎 |
| `WHERE` 濾掉了要觀察的現象 | 門檻掃描加了 `kind='ok'`，睡眠長間隔全被排除 | 同上，但**自己下的過濾條件也算**一種資料範圍 |
| ad-hoc 簽章的 app 讀寫別人的 Keychain 項目 | 每次重新建置都被要求輸入 login 密碼 —— 因為分區清單只能用 cdhash 釘住，而 cdhash 每 build 都變 | 不是 ACL 問題，別去動 ACL（見 D-015）。要根治得有穩定簽章 |
| 對「時間桶」查 `used_percent > 100` | 誤報 —— 一天含約 4.8 個 5 小時窗，session 日桶超過 100 是正常的 | 不變量在**單一窗**，不在時間桶。查 `v_window_summary` |
| 睡眠中的短暫喚醒觸發取樣 | 取樣日誌塞滿 `The request timed out.`，看起來像網路或服務壞了 | 比對牆上時間與 `systemUptime`，睡過的記成 `slept`（D-017）。**別**在短暫喚醒時跳過取樣 —— 實測有 162 次成功 |
| 端點在重置那一秒少給 `resets_at` | 那一天的用量憑空暴增（實測日用量 45%，真實約 7%） | NULL 是「身分未知」，不是「換窗」—— 沿用前一個窗（D-019） |
| 續期鏈斷掉後繼續重試 | 每 5 分鐘拿同一個死 token 敲認證端點（實測敲了一整天） | 記住失效 token 的指紋（只存雜湊），換了新的才再試（D-020） |
| 把連續一整段的 `network` 當成服務壞了 | 查了半天端點與逾時設定，其實是機器沒網路（實測 540/568 筆） | `offline` 只認得出「完全沒連線」；「Wi-Fi 連著但不通」仍記成 `network`，這是知情的取捨（D-022）。成段出現、兩家同時失敗，先想是不是沒網路 |
| 在 app 自己的視窗裡放「結束 app」的步驟 | 按下去視窗跟著關，後面的步驟再也看不到 | 需要結束 app 的流程交給終端機跑一整段（D-026）。順帶：可點的東西要**看起來**能點 |
| 兩種失敗共用一個訊息欄位 | 寫入失敗的訊息被緊接著的讀取成功清掉，從來沒顯示過 | 各自的欄位、各自的清除條件：只有「同一件事後來成功了」才清（D-025） |
| 把同步的讀取搬到背景 | 結果亂序到達、選單與資料不同步、蓋掉使用者剛展開的內容 —— 同步時都不存在 | 編號丟棄舊結果；畫圖用與資料一起更新的 `shownGranularity`（D-024） |
| 相關子查詢的條件欄位沒有索引 | 測試資料上毫無感覺，真實資料上平方成長（實測六週後單一查詢 3 秒） | 看 `EXPLAIN QUERY PLAN`，不要量時間；回歸測試也是驗查詢計畫（D-023） |
| 逐個服務查 view | 每查一家就把全部樣本推導一遍 —— `WHERE service = ?` 推不進視窗函式 | 一次查完所有服務，在 Swift 端分組 |
| 續期失敗一律丟憑證 | client ID 錯了也把還能用的 refresh token 丟掉，重新種子拿到的早已作廢 | `invalid_client` 不丟（D-018） |

## 驗證要求

**fixture 過了不等於對。** 這個專案的兩個最嚴重 bug（假窗導致 2641% 假 delta、
123 個假窗）都通過了當時的全部測試 —— 因為 fixture 用的是乾淨的整數
`resets_at`，測不出真實世界的 ±1s 抖動與佔位值。

改動推導邏輯後，**一定要在真實資料庫的副本上驗證**：

```bash
sqlite3 "$HOME/Library/Application Support/AIUsage/usage.sqlite" ".backup /tmp/v.sqlite"
sqlite3 /tmp/v.sqlite ".read Packages/AIUsageKit/Sources/UsageStore/Resources/00N_xxx.sql"
# 健全性：任一「窗」的用量不得超過 100（這才是不變量，都應為 0）
sqlite3 /tmp/v.sqlite "SELECT COUNT(*) FROM v_window_summary WHERE used_percent > 100 OR peak_percent > 100;"
sqlite3 /tmp/v.sqlite "SELECT COUNT(*) FROM v_hourly WHERE window_kind='weekly' AND used_percent > 100;"
# 對帳：delta 加總應等於該窗百分比的實際變化
```

新的回歸測試要**照真實觀察到的現象**撰寫，不要用理想化的假資料。

## UI 改動的驗證

有 Screen Recording 權限時，只截取本 app 的視窗，不要整螢幕擷取
（會拍到使用者其他 app 的私人內容）：

```bash
swift scripts/window-id.swift       # 只列畫面上的視窗；選單沒點開時不會出現
screencapture -x -o -l <windowID> /tmp/win.png
```

## 查 Keychain 授權狀態

```bash
swift scripts/keychain-acl.swift    # 唯讀。印出信任應用程式清單與分區清單
```

分區清單是提示的真正成因，**Keychain Access 的 GUI 看不到它**（見 D-015）。

## 與使用者互動

- 使用者的觀察優先於你的資料範圍。「我的資料裡沒有」不等於「沒發生過」。
- 對端點行為下結論前，先確認資料涵蓋了該變項的變化。
- 推翻自己先前的結論時直說，並記進 decisions.md（含被推翻的理由）。
