# 架構與資料模型

**目前狀態**的描述。歷史決策與被推翻的方案見 [decisions.md](history/decisions.md)。

## 模組

```
AIUsage.xcodeproj
├── AIUsage/                    app 殼（極薄，只做接線）
│   ├── AIUsageApp.swift        MenuBarExtra + Window scene、AppState
│   └── Sampler.swift           NSBackgroundActivityScheduler + 醒來補抓
└── Packages/AIUsageKit/
    └── Sources/
        ├── UsageCore/          純 domain，零 I/O
        │   ├── Model.swift     Service、WindowKind、UsageWindow、FetchFailure
        │   ├── Parsers.swift   Claude / Codex 回應解析
        │   └── JSONShape.swift 結構指紋（偵測端點改版）
        ├── UsageProviders/     HTTP 與憑證
        ├── UsageStore/         GRDB + schema/migrations + 查詢
        │   └── Resources/      001..005_*.sql（migration 正典）
        └── UsageUI/            SwiftUI views + Swift Charts
```

依賴方向：`UI → Store → Core`，`Providers → Core`。

## 資料流

```
NSBackgroundActivityScheduler (≈5 min)
  或 NSWorkspace.didWakeNotification
  或 使用者按重新整理
        │
        ▼
  Provider.fetch()  ── HTTP ──►  端點
        │                         │
        │  ◄── 回應成功才蓋時間戳 ─┘
        ▼
  Parser.parse()  ──► UsageSnapshot（依 limit_window_seconds 判定窗別）
        │
        ▼
  UsageDatabase.record()
        ├── fetch        每次嘗試一列（含失敗）
        ├── sample       每個觀測到的窗一列（每次都寫，即使沒變）
        └── raw_payload  僅在值變或結構變時
        │
        ▼
  SQL views（delta / gap / 窗身分 / 提前重置）
        │
        ├──► UsageViewModel ──► menu bar + 圖表
        └──► 外部工具（sqlite3 / DuckDB / pandas）—— 同一份規則
```

## 端點

| Provider | 端點 | 特性 |
|---|---|---|
| Claude | `GET api.anthropic.com/api/oauth/usage` | 需 `anthropic-beta: oauth-2025-04-20`。回傳 `seven_day.utilization`（float）、`resets_at`（ISO8601，**秒級有 ±1s 抖動**）、`limits[].severity`、`extra_usage` |
| Codex | `GET chatgpt.com/backend-api/codex/usage` | 需 `chatgpt-account-id`。`used_percent` 為**整數**（解析度 1%） |

**User-Agent 是承載性的**（兩者皆已實測）：Claude 缺 `claude-code/<ver>` 會落入
嚴格限流桶持續 429；Codex 缺擬真 `codex_cli_rs/<ver> (...)` 會被 Cloudflare 擋成
403 HTML 挑戰頁。

**窗別一律以 `limit_window_seconds` 判定**：`604800`→`weekly`、`18000`→`session`、
其他→`other` 並保留原始秒數。**絕不以 `primary`/`secondary` 欄位位置判定** ——
Codex 的窗會換位（見 decisions.md D-005）。

## 窗語意

兩家的限額窗都是**固定時長、以首次使用為錨點**（非日曆固定、非滾動）。
OpenAI 客服說法：「weekly window starts at the first message you send」。

**窗尚未開始時，伺服器回報 `resets_at = 現在 + window_seconds` 作為佔位值**，
該值隨每次取樣前移，不帶任何身分資訊。實測對照：

| Codex weekly | `reset_after_seconds` | 意義 |
|---|---|---|
| 用量 2% | 138763（約 1.6 天） | 窗已開始 5.4 天，真實剩餘 |
| 用量 0% | 604800（整整 7 天） | 窗未開始，佔位值 |

由此得到一條**對兩家都成立**的統一規則：

> `resets_at - observed_at ≈ window_seconds` ⟹ 窗未開始，`resets_at` 無身分意義。

`window_started = 0` 的樣本其 `effective_resets_at` 視為 NULL；
「未開始 ⟷ 已開始」的轉換即為一次真正的窗界線。

## 資料表

| 表 | 內容 |
|---|---|
| `fetch` | 每一次 HTTP 嘗試（成功或失敗）。`completed_at` 是樣本時間戳的**唯一**來源 |
| `sample` | 每次取樣觀測到的每個窗一列。**每次都寫，即使數值沒變**（約 50 bytes） |
| `raw_payload` | 原始回應，僅在解析值或 JSON 結構變化時寫入 |
| `setting` | `delta_max_gap_seconds`(900)、`reset_tolerance_seconds`(120)。放表裡而非程式常數，讓外部工具套用同一份規則 |
| `meta` | `schema_version` |

## View

### `v_window_seq` — 窗編號

為每筆樣本標上 `window_seq`。只有 `effective_resets_at` 移動超過
`reset_tolerance_seconds`(120) 才遞增。真正換窗會移動約 7 天，抖動只有 1 秒以內 ——
兩者相差 5 個數量級，容差可以乾淨分開。

### `v_sample_delta` — 相鄰配對與分類

| kind | 條件 | `delta_percent` |
|---|---|---|
| `first` | 無前一筆 | NULL |
| `reset_in_gap` | 換窗**且**間隔 > 門檻 | NULL（舊窗尾段與新窗起算時點皆不可知） |
| `reset` | 換窗、間隔夠短 | `percent`（新窗自 0 起算） |
| `gap` | 間隔 > 門檻 | `percent - prev_percent`（**總量已知，時間分布未知**） |
| `regress` | 同窗內百分比下降 | `0.0`（夾擠） |
| `ok` | 其餘 | `percent - prev_percent` |

### 歸屬判準（核心設計）

> **一段 delta 可歸屬於某個桶，若且唯若 `[prev_observed_at, observed_at]`
> 完整落在該桶內；或間隔短於門檻（誤差有界）。**

此判準**自動隨粒度調整**，不需為每個粒度手調門檻。實測示例 —— 同一段 6 小時 gap：

| 粒度 | 結果 | 原因 |
|---|---|---|
| 小時 | 進 `unknown_percent` | 區間橫跨 6 個小時桶 |
| 日 | 進 `used_percent` | 區間完整落在同一天內 |

`v_hourly` / `v_daily` / `v_weekly` 一律**同時輸出 `used_percent` 與 `unknown_percent`**，
消耗量永遠不會憑空消失，只會被標記為「知道發生了、不知道落在哪一格」。

**沒有樣本的小時不會產生任何列。** 無資料 ≠ 0。

### 其餘

| View | 用途 |
|---|---|
| `v_weekly` | 曆週（**週一起算**）。結構與 `v_daily` 相同。注意這不是「額度窗」—— 窗以首次使用為錨點，提前重置時一週內可能有好幾個窗 |
| `cache_request` / `v_cache_request` / `v_cache_daily` | Claude Code 對話紀錄的 token 分解。**另一條管線**，見下節 |
| `v_unknown_span` | 小時層級不可歸屬的區間，供圖表畫斜線帶 |
| `v_window_summary` | 每個窗一列。`used_percent` = 最後觀測值（**權威，不經 delta**）、`peak_percent`、`observed_duration_seconds`、`ended_early`（是否被提前重置） |
| `v_current` | menu bar 用的最新讀數，含 `window_started` |
| `v_health` | `last_success_at` / `last_attempt_at` / `failures_total` / **`failures_24h`** / `slept_total` / **`last_weekly_at`** |
| `credential_event`（表） | 憑證事件：`source_changed` / `renewed` / `renewal_failed` / `discarded` / `rejected`。**不含 token**（D-017） |

`v_health` 分開量 `ok` 與 `last_weekly_at`：HTTP 成功不等於拿到週用量
（窗可能換位或消失），兩者混在同一欄位會讓健康度誤報一切正常。
失敗次數**不含 `slept`**（請求期間系統睡過）—— 那次沒有觀測，不是故障（D-017）。

## 第二條管線：對話紀錄的 token 分解

與用量取樣**刻意不共用任何機制**：

| | 用量取樣（`sample`） | 快取分析（`cache_request`） |
|---|---|---|
| 來源 | 輪詢未公開端點 | 本機 JSONL，已經在硬碟上 |
| 取得 | 取樣，會漏、會有 gap | 匯入，完整不會漏 |
| 需要 delta／窗身分／無資料≠0 | ✅ 全部 | ❌ 一條都不需要 |
| 共用的原則 | D-002：存原始值，推導留給查詢時 | 同左 |

**去重鍵是 `requestId` 不是 `uuid`**：一次 API 請求會在 JSONL 產生多行（每個內容
區塊一行），而每一行都帶著同一份 `usage`。逐行加總會放大約 1.74 倍且不均勻。

歸因只做**能可靠判斷**的那一種：「距上次請求超過快取 TTL」。其餘重寫（改動前面
的內容、context 壓縮、換模型…）從紀錄判斷不出來，不歸因，只呈現數量。

## 排程與生命週期

- **`NSBackgroundActivityScheduler`**（非 `Timer`）：休眠期間不觸發、醒來
  **不補跑**錯過的次數 —— 正是所需行為。代價是有 tolerance，**不保證每小時有樣本**。
  block 結束**必須** `completion(.finished)`，否則不會排下一次。
- 額外觸發：`NSWorkspace.didWakeNotification`、app 啟動、使用者按重新整理。
- **睡眠中的短暫喚醒也會觸發排程**，而且有時請求會成功（實測 162 次），所以**不跳過**。
  每次請求前後記下牆上時間與 `systemUptime`（不計睡眠），差距超過 1 秒的網路失敗記為 `slept`（D-017）。
- app 為 `LSUIElement`（無 Dock 圖示），activation policy 是 `.accessory` ——
  開視窗**不會**自動變前景，需明確 `NSApp.activate()` + `makeKeyAndOrderFront`。

## 憑證

| Provider | 來源 | 續期 |
|---|---|---|
| Claude | **讀**：自己的 `AIUsage-claude-credentials` → `~/.claude/.credentials.json` → Claude Code 的 `Claude Code-credentials`（種子）。**寫**：只寫自己的那個 | **本 app 自行續期**：過期前 5 分鐘換新，429 時退避 15 分鐘。**絕不寫 Claude Code 的項目**（會重設其分區清單，見 D-016）。續期鏈失效時自動清除自己的項目、重新種子（`invalid_client` 除外） |
| Codex | `~/.codex/auth.json` | ChatGPT.app 負責，本 app **唯讀不寫回** |

Claude 續期端點：`POST platform.claude.com/v1/oauth/token`，
client_id 預設 `9d1c250a-e61b-44d9-88ed-5944d1962f5e`（從 CLI 執行檔取得的
OAuth public client，非機密）。**可在選單「進階」覆寫**，存 `UserDefaults`
（`claude.oauthClientID`），每次續期時才讀，改了立即生效（D-018）。

憑證的每個轉折（來源改變、續期成敗、自癒、被用量端點拒絕）寫一筆 `credential_event`。
系統日誌保存期太短，出事時常常已經查不到（D-017）。

## App 組態

- **App Sandbox 關閉、Hardened Runtime 開啟**（直接分發 Mac app 的標準組合）。
  沙盒下讀 `~/.codex/auth.json` 需 `NSOpenPanel` + security-scoped bookmark，
  且 ChatGPT.app 原子寫入換 inode 會使 bookmark stale。非沙盒下 `~/.codex`
  不在 TCC 保護範圍。
- `LSUIElement = true`
- Xcode 專案使用 **synchronized file groups**（新增檔案不需改 pbxproj）
