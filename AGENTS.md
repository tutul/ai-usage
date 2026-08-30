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

1. **無資料 ≠ 0。** 沒有樣本的小時不產生列、不畫長條、不補 0。
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
| 對「時間桶」查 `used_percent > 100` | 誤報 —— 一天含約 4.8 個 5 小時窗，session 日桶超過 100 是正常的 | 不變量在**單一窗**，不在時間桶。查 `v_window_summary` |

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
swift /tmp/winlist.swift            # 見 decisions.md，用 CGWindowListCopyWindowInfo 找 window id
screencapture -x -o -l <windowID> /tmp/win.png
```

## 與使用者互動

- 使用者的觀察優先於你的資料範圍。「我的資料裡沒有」不等於「沒發生過」。
- 對端點行為下結論前，先確認資料涵蓋了該變項的變化。
- 推翻自己先前的結論時直說，並記進 decisions.md（含被推翻的理由）。
