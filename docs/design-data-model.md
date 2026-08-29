# 資料模型設計

本文說明資料模型的設計與取捨。
**Schema 正典位於 `Packages/AIUsageKit/Sources/UsageStore/Resources/schema.sql`**
（由 GRDB migration 直接載入；`PRAGMA` 設定在 GRDB `Configuration`，不寫在 SQL 內）。**所有 SQL 均已用 fixture 實測驗證**，涵蓋
休眠長 gap、密集取樣下的窗重置、長 gap 中的窗重置、百分比倒退等邊界情境。

## 約定

| 項目 | 約定 |
|---|---|
| 時間儲存 | unix epoch 秒、**UTC**。所有 `*_at` 欄位皆然 |
| 時間分桶 | **本地時區**（透過 `'localtime'` modifier，由讀取端的 TZ 決定）。你在 UTC+8 且無日光節約，桶邊界穩定 |
| 百分比 | `REAL`，0..100。Codex 實際只給整數，Claude 給 float |
| 窗身分 | 以 `resets_at` 識別。**不以百分比下降推測重置**（已於真實資料驗證：曾觀測到 2%→0% 且 `resets_at` 換號的週窗轉換） |
| 窗身分 policy | **兩家 provider 的窗語意根本不同**，見下節。以 `window_policy` 表明確記錄，不靠推測 |
| Migration | `Resources/NNN_name.sql`，依檔名順序註冊。**已套用的檔案不得再修改** —— 既有資料庫不會重跑它 |
| 窗別判定 | 以 `limit_window_seconds` 對應：`604800`→`weekly`、`18000`→`session`、其他→`other` 並保留原始秒數。**絕不以 `primary`/`secondary` 欄位位置判定** |
| Schema 契約 | `meta.schema_version`。變更一律走 migration |

## 表

- **`fetch`** — 每一次 HTTP 嘗試一列（成功或失敗）。`completed_at` 是樣本時間戳的
  **唯一**來源。失敗列帶 `error_kind`，供 `v_health` 判斷停擺。
  `error_kind` 分類：`auth`(401) / `blocked`(403，UA 或風控) / `network` / `http` / `parse` /
  `missing_window`（回應成功但缺 604800 的窗）。
  **`auth` 與 `blocked` 必須分開** —— 補救方式完全不同。
- **`sample`** — 每次取樣觀測到的每一個限額窗一列（Claude 一次回 weekly + session 兩個窗）。
  **每次取樣都寫，即使數值沒變** —— 「值沒變」本身就是資訊，少了它就無法區分
  「這段時間沒用」與「這段時間沒觀測」。窄行約 50 bytes。
- **`raw_payload`** — 原始回應，**僅在解析值變化或 JSON 結構變化時寫入**。
  `shape_sha256` 是排序後 key path 的雜湊，用來偵測端點改版；
  **不可對整個 body 做雜湊去重** —— Codex 回應含 `reset_after_seconds`，每次呼叫都不同，
  逐 byte 比對會導致每筆都被視為新內容，儲存量回到 200 MB/年。
- **`setting`** — `delta_max_gap_seconds`（預設 900）。放在表裡而非程式常數，
  **讓 SQL view 與外部工具套用同一份規則**。

## View（單一事實來源）

### `v_sample_delta` — 相鄰樣本配對與分類

| kind | 條件 | `delta_percent` |
|---|---|---|
| `first` | 無前一筆 | NULL |
| `reset_in_gap` | `resets_at` 變動**且**間隔 > 門檻 | NULL（舊窗尾段與新窗起算時點皆不可知） |
| `reset` | `resets_at` 變動、間隔夠短 | `percent`（新窗自 0 起算，已知） |
| `gap` | 間隔 > 門檻 | `percent - prev_percent`（**總量已知，只是時間分布未知**） |
| `regress` | 同窗內百分比下降 | `0.0`（夾擠） |
| `ok` | 其餘 | `percent - prev_percent` |

### 歸屬判準（關鍵設計）

> **一段 delta 可歸屬於某個桶，若且唯若 `[prev_observed_at, observed_at]` 完整落在該桶內；
> 或間隔短於門檻（誤差有界，可安全歸給後一個樣本所在的桶）。**

此判準**自動隨粒度調整**，不需為每個粒度手調門檻。實測示例 —— 同一段 6 小時睡眠 gap：

| 粒度 | 結果 | 原因 |
|---|---|---|
| 小時 | 進 `unknown_percent` | 區間橫跨 6 個小時桶 |
| 日 | 進 `used_percent` | 區間完整落在同一天內 |

`v_hourly` / `v_daily` 一律**同時輸出 `used_percent` 與 `unknown_percent`**，
消耗量永遠不會憑空消失，只會被標記為「知道發生了、不知道落在哪一格」。
圖表以斜線帶呈現 `v_unknown_span`。

**沒有樣本的小時不會產生任何列** —— 無資料 ≠ 0。圖表必須據此斷線，不可補 0。

### 其餘 view

- **`v_unknown_span`** — 小時層級不可歸屬的區間，供圖表畫斜線帶
- **`v_window_summary`** — 每個限額窗一列。`used_percent` = 該窗**最後一次觀測值**（權威），
  `peak_percent` = 峰值，`tail_unobserved_seconds` 大表示窗尾未觀測、數值低估
- **`v_current`** — menu bar 用的最新讀數
- **`v_health`** — `last_success_at` / `last_attempt_at` / `failures_total` /
  **`last_weekly_at`**（週樣本的新鮮度直接量在 `sample` 上）。
  HTTP 成功不等於拿到週用量 —— 窗可能換位或消失，故兩者分開度量，不以 `fetch.ok` 兼表。

## 窗語意：固定時長、以首次使用為錨點

兩家的限額窗都是**固定時長、從首次使用起算**，而非日曆固定或滾動。
[OpenAI 客服說法](https://community.openai.com/t/reset-codex-s-weekly-limit-on-a-fixed-day/1386852)：
「weekly window starts at the first message you send」；每個帳號的窗
anchors to its own first request after the previous reset。

**窗尚未開始時，伺服器回報 `resets_at = 現在 + window_seconds` 作為佔位值**，
該值隨每次取樣前移，不帶任何身分資訊。實測對照：

| Codex weekly | `reset_after_seconds` | 意義 |
|---|---|---|
| 用量 2% | 138763（約 1.6 天） | 窗已開始 5.4 天，真實剩餘 |
| 用量 0% | 604800（整整 7 天） | **窗未開始**，佔位值 |

由此得到一條**對兩家都成立**的統一規則，不需 per-provider 政策：

> `resets_at - observed_at ≈ window_seconds` ⟹ 窗未開始，`resets_at` 無身分意義。

`window_started = 0` 的樣本其 `effective_resets_at` 視為 NULL；
「未開始 ⟷ 已開始」的轉換即為一次真正的窗界線。

### 這在真實資料上造成過的損害

1. **Claude 的 `resets_at` ±1s 抖動**：以精確比對判定換窗，同一週窗被判成 49 次重置，
   每次 delta = 當前百分比（約 54%）→ 累積 **2641% 假 delta**，小時桶 270%、日桶 2106%。
2. **Codex 閒置時 `resets_at` 持續前移**：每次取樣都被判成換窗 → **123 個假窗**。

兩者的原始樣本都完全正確 —— 錯的只有推導層，改 view 即可，**不需修任何資料**。
這是「存原始樣本、查詢時才推導」的直接回報。

### 兩個推論教訓（比 bug 本身更值得記）

- **只有真實資料會浮現這類問題。** fixture 用乾淨的整數 `resets_at` 測不出抖動，
  用固定值也測不出未開始窗。回歸測試必須照真實觀察到的現象撰寫。
- **不可在「無用量」的資料上推論窗行為。** 曾據 180 筆 `percent` 全為 0 的樣本
  推論 Codex 是「滾動窗」（migration 003），那是被混淆變項誤導的錯誤結論；
  同一份資料中「用量 2%」的對照組就足以推翻它。004 已更正。

## 已知取捨（誠實記錄）

1. **delta 加總是近似值，窗總結才是精確值。**
   `regress` 夾擠為 0 會在伺服器下修百分比時產生微幅高估。實測 fixture 中
   實際消耗 20.0、delta 加總得 20.2（誤差來自一次 0.2 的下修）。
   **要精確的週用量請讀 `v_window_summary.used_percent`，它不經 delta 推導。**
   `regress` 列保留在 `v_sample_delta` 中，隨時可稽核。

2. **Codex 解析度為 1%。** 小時層級多數格子會是 0，然後某格跳 1。
   日／週層級才有意義。此為資料源性質，非實作缺陷。

3. **本地時區分桶由讀取端 TZ 決定。** 跨時區讀同一個 DB 會得到不同分桶。
   單機單人使用下這是期望行為；若日後需要固定時區，改為存 TZ 並顯式轉換。

## 待確認

- `delta_max_gap_seconds` 預設 900（= 3 × 取樣間隔）是否合理？
  跑一兩週後可用實際漂移數據回頭校準 —— 因存的是原始樣本，**改門檻不需重建歷史**。
