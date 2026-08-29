# ai-usage — brief（歷史文件）

> 📌 **這是 2026-08-25 定案的原始範圍協議，記錄專案開工前的可行性驗證與範圍決定，
> 不再更新。** 部分結論已被後續實測推翻（特別是窗語意與 Claude 憑證方案）——
> 以 [decisions.md](decisions.md) 為準。
>
> 目前架構 → [architecture.md](architecture.md)　現況 → [status.md](status.md)


**Goal**
一個常駐 macOS menu bar 的 app，持續抓取 Claude 與 Codex 訂閱的 **weekly 用量百分比**，
把每一筆原始樣本永久存進本機 SQLite，並提供可回溯任意區間的小時／日／週消耗圖表。

---

## Scope（這一版要做的）

- 兩個 provider：**Claude**、**Codex**
- 預設每 5 分鐘取樣一次（**可設定**，非寫死常數）
- SQLite 只存**不可變的原始樣本**；delta 一律由查詢推導
- 重置邊界以 `resets_at` 變化判定，不靠百分比下降推測
- Menu bar 顯示兩家當下的 weekly %；點開為圖表視窗（Swift Charts）
- 最後一次成功抓取時間必須醒目呈現，逾時變色 —— 抓不到要看得出來
- 缺樣本視為 gap，圖表斷開，不污染既有資料

## 資料來源（皆已實測驗證）

| Provider | 端點 | 驗證結果 |
|---|---|---|
| Claude | `GET api.anthropic.com/api/oauth/usage` | ✅ 200。需 `anthropic-beta: oauth-2025-04-20` + `User-Agent: claude-code/<ver>`（少了 UA 會落入嚴格限流桶）。回傳 `seven_day.utilization`（float）、`resets_at`（ISO8601）、`limits[].severity`、`extra_usage`，另有多個目前為 null 的分桶（`seven_day_opus`/`seven_day_sonnet` 等） |
| Codex | `GET chatgpt.com/backend-api/codex/usage` | ✅ 200。`primary_window.limit_window_seconds = 604800`（即週窗，5h 窗已於 2026-07 停用），`secondary_window: null`。**`used_percent` 為整數 → 解析度僅 1%** |

兩者皆為**未公開端點**，可能無預警變更 → 保存原始回應（見下方雙表設計），解析層薄且集中。

**User-Agent 是承載性的（兩個端點皆然，已實測）**
- Claude：缺少 `claude-code/<ver>` 會落入嚴格限流桶，持續 429
- Codex：缺少擬真的 `codex_cli_rs/<ver> (...)` 會被 Cloudflare 擋下，回 **403 HTML 挑戰頁**（非 JSON）

→ UA 須為顯式、可設定的常數；**403 必須是獨立的 `error_kind`，不可與 401 混用** ——
401 的補救是重新授權，403 是 UA／風控問題，跑去重新登入只是白忙。

**窗別一律以 `limit_window_seconds` 判定，絕不以欄位名稱（`primary`/`secondary`）判定**
Codex 的窗會換位：2026-07 前為 primary=5h / secondary=週，暫停期間為 primary=週 / secondary=null，
[5 小時限額已於 2026-08-25 對 Plus 恢復](https://9to5mac.com/2026/08/24/openai-restores-5-hour-codex-and-work-limits-for-chatgpt-plus-users/)，
預期將換回 primary=5h / secondary=週。若以欄位位置對應，換位當下會**默默把 5 小時百分比寫進 weekly 序列**
——不報錯、不崩潰，只是資料錯了。對應表：`604800`→`weekly`、`18000`→`session`、其他→保留秒數並記為 `other`。
若回應中不存在 604800 的窗，**不得寫入 weekly 樣本**，而應記為「成功但缺 weekly」，
避免 UI 把舊值當現況顯示。

## 認證

- **Claude**：使用者跑 `claude setup-token` 產生獨立長效 token，存入 **本 app 自己的** Keychain item。
  （不讀 Claude Code 的 keychain item —— keychain 跨 app 分享綁 Team ID，非同隊不可行。）
- **Codex**：**唯讀** `~/.codex/auth.json`，由 ChatGPT.app 負責續期。
  **絕不寫回**，避免與其續期邏輯衝突而弄壞登入狀態。

---

## 已定案的關鍵設計

**取樣與休眠**
- 使用 [`NSBackgroundActivityScheduler`](https://developer.apple.com/documentation/foundation/nsbackgroundactivityscheduler)，非 `Timer`。
  休眠期間不觸發、醒來不補跑錯過的次數 —— 正是所需行為。block 結束**必須** `completion(.finished)`。
- 額外觸發：`NSWorkspace.didWakeNotification`（醒來立即補抓）、app 啟動時。
- 因 scheduler 有 tolerance，實際間隔浮動 → **不保證每小時有樣本**，此代價已接受。

**時間戳語意（不可妥協）**
> 存的不是「某小時用了多少」這種**事件**，而是「**此刻計量器的讀數**」。

`sampled_at` 一律為 HTTP 回應成功的真實時刻。睡 6 小時醒來只會產生**一個**當下的點，
**永遠不會**回填過去時段的資料點。這也是「小時用量」必須是查詢時 view 的原因 ——
樣本間隔本就不規則，若存成固定每小時一格，不規則採樣立刻讓資料失真。

**取樣間隔：為何是 5 分鐘而非 1 小時**
取樣間隔與解析度無關，與「多少資料能被自信歸屬到某小時」有關。
`NSBackgroundActivityScheduler` **明確不保證準時**，而 gap 規則又禁止跨界均攤 ——
兩者相加，若每小時只取樣一次，樣本會落在 10:03 / 11:07 / 12:02…，
**每一段 delta 都橫跨兩個小時，全部不可歸屬，小時圖將整片是 unknown**。

超取樣是把「換省電與休眠正確性時讓出去的時間精度」買回來的手段。
相鄰樣本間隔 `i` 分鐘時，delta 落在同一小時內的機率為 `(60-i)/60`：

| 間隔 | delta 落在單一小時內 | 樣本/年（兩家） |
|---|---|---|
| 60 分 | ~0% | 17.5K |
| 15 分 | 75% | 70K |
| 10 分 | 83% | 105K |
| **5 分（預設）** | **92%** | 210K |

5 分鐘距 Claude 端點的安全下限（180 秒）尚有 1.7 倍餘裕，不會踩到限流。
**間隔為設定值**：跑一兩週取得真實漂移數據後可調整。
因存的是原始樣本、delta view 只看時間戳不假設固定間隔，
**歷史資料在間隔變更後依然完全可用**。

**儲存：sample 與 raw_payload 分表**
若每次取樣都存完整 `raw_json`（Claude 回應約 1.5KB），一年約 200 MB —— 對一個 menu bar
工具不合理，且絕大多數樣本百分比未變，存的是重複內容。故拆為兩張表：

- **`sample`** —— **每次觀測都寫**，窄行（`ts, service, window, percent, resets_at, ok`），
  約 50 bytes。這是 delta view 的唯一來源；「值沒變」本身就是資訊，不可省略
- **`raw_payload`** —— **僅在解析後內容與前一筆不同時才寫**。
  Codex 整數百分比一週最多變 100 次，Claude 相近 → 一年數千列，MB 級

保住完整保真度（端點改版時可回溯原始資料），同時將儲存壓回合理範圍。

**Gap 處理**
長 gap 期間若百分比有變動，該段消耗標記為 **unknown 區間**，**不摻入任何小時**。
小時圖上呈現為斷開／斜線區段；日與週彙總則仍計入（因週用量確實被消耗）。不做均攤 —— 那是編造數字。

若**週窗於 gap 期間重置**，舊窗以「未知最終值」關閉，標記為 incomplete，不假裝是完整一週。

**單一事實來源：delta 邏輯寫成 SQL view**
`v_sample_delta` / `v_hourly` 等 view 直接定義在 DB 內。Swift 端與外部工具（sqlite3 / DuckDB /
pandas）**讀同一個 view** → 不會出現兩套實作漂移。`UsageCore` 專心處理 domain 型別與
provider 回應歸一化。

---

## Non-goals（刻意排除，以及為什麼）

- **Gemini**：Gemini / Code Assist 的配額是「每日請求數」，**weekly % 這個指標不存在**。
  硬做只能自行編造指標。架構預留 provider 擴充點，等 Google 真的開放再加。
- **5 小時窗的 UI**：只在意 weekly。5h 資料順手存下，但不做視圖。
- **token 級成本估算**（ccusage 那類從 transcript 累加 token）：與官方 % 定義不同，混用會讓數字失去意義。
- **多帳號 / 多機器同步 / 雲端備份**：單機、單帳號。
- **接近上限的通知提醒**：v1 不做。資料齊了之後是便宜的加法，但不是現在的重點。
- **寫回 `~/.codex/auth.json`**：唯讀。
- **上架 App Store**：不是目標，故不受沙盒限制。

---

## Stack

Swift / SwiftUI `MenuBarExtra` + Swift Charts + GRDB.swift + Keychain。
單一 app 自帶排程器 —— 一個東西要安裝、一個東西要維護。不用 crontab / launchd。
無現成 scaffolder 適用，走手工建置（new-project Phase 5）。

```
ai-usage/
├── AIUsage.xcodeproj        # 薄殼：App entry、MenuBarExtra scene、登入項註冊
├── AIUsage/                 # app target 原始碼（極少，只做接線）
├── Packages/AIUsageKit/
│   ├── Sources/
│   │   ├── UsageCore/       # 純 domain：型別、provider 回應歸一化 — 零 I/O
│   │   ├── UsageProviders/  # ClaudeProvider、CodexProvider（protocol + 實作）
│   │   ├── UsageStore/      # GRDB schema、migrations、views、查詢
│   │   └── UsageUI/         # SwiftUI views + Swift Charts
│   └── Tests/               # UsageCoreTests / UsageStoreTests ← 專案重心
├── docs/
└── README.md
```

**App 組態**
- **App Sandbox 關閉、Hardened Runtime 開啟**（直接分發 Mac app 的標準組合）。
  沙盒下讀 `~/.codex/auth.json` 需 `NSOpenPanel` + security-scoped bookmark，
  且 ChatGPT.app 原子寫入換 inode 會使 bookmark stale —— 代價不划算。
  非沙盒下 `~/.codex` 不在 TCC 保護範圍，直接讀，零彈窗。
- `LSUIElement = true`（無 Dock 圖示）
- 開機自啟用 `SMAppService.mainApp.register()`（macOS 13+）。
  **App 沒在跑就完全沒資料，這是比休眠更大的缺口來源。**

**資料庫組態**
- `DatabasePool` → WAL mode，單 writer（app）+ 多 reader（外部分析工具）
- **DB 檔不得置於 iCloud Drive / Dropbox / 網路磁碟**（WAL 依賴 shared memory）
  → `~/Library/Application Support/AIUsage/usage.sqlite`
- 設 `busyTimeout`；GRDB 寫交易一律 `IMMEDIATE`
- 已知限制：`ValueObservation` 偵測不到外部行程寫入（本專案不從外部寫，不受影響）
- **schema 視為對外契約**，變更一律走 migration

---

## Risks

| 風險 | 應對 |
|---|---|
| 未公開端點改版 | 每筆樣本存完整 `raw_json`；解析層薄且集中，壞掉只需改一處 |
| Codex `used_percent` 整數（解析度 1%） | 小時層級明確標示為粗粒度；日／週彙總為主要視圖 |
| Codex 窗位置變動（5h 於 2026-08-25 回歸） | 以 `limit_window_seconds` 判定窗別；`shape_sha256` 偵測結構改版並留存原始快照。**schema 無需變更** |
| Cloudflare 依 UA 擋下請求（403） | UA 為顯式可設定常數；403 獨立分類，不誤導為認證失效 |
| token 過期導致靜默停擺 | 「上次成功抓取」置於 menu bar 最顯眼處，逾時變色 |
| App 未啟動 / Mac 睡眠造成缺樣本 | 開機自啟 + 醒來立即補抓；殘餘 gap 明確呈現，delta 不跨 gap 硬算 |
| GRDB 官方對跨行程共享措辭嚴厲 | 該警告針對**多 writer**；本專案為單 writer + 唯讀分析，落在安全的一半 |
| 高頻取樣導致 DB 膨脹 | `sample` 窄行 + `raw_payload` 僅存變化；~21 MB/年，非 200 MB |
