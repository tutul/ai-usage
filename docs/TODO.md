# TODO

依重要性排列。現況見 [status.md](status.md)，決策背景見
[history/decisions.md](history/decisions.md)。

### 1. Claude `clientID` 不應寫死（中）
`ClaudeCredentials.swift` 的 `clientID = "9d1c250a-…"` 是從 `claude` CLI
執行檔 `strings` 取得後硬編進原始碼的。這是**單點故障**：Anthropic 若輪替
client_id，續期會永久失敗，Claude 追蹤整條停擺（而非偶爾有 gap），
且錯誤會顯示為 auth 失敗，看不出真正原因。

三種可能做法，尚未決定：

| 做法 | 優點 | 問題 |
|---|---|---|
| 使用者可填（設定 UI／設定檔覆寫） | 最簡單，可立即解套 | 使用者不會知道要填什麼 |
| 開機時從 CLI 執行檔萃取 | 自動跟隨官方更新 | 需定位執行檔；官方改打包方式即失效 |
| 從憑證 JSON 讀 | 最乾淨 | **尚未確認該欄位是否存在**，要先驗證 |

先做的最小改動：把 `clientID` 提為 `init` 參數（與 `fileURL`、
`keychainService` 一致），硬編值僅作預設 —— 這樣至少可被覆寫、可被測試，
不必等自動萃取設計定案。

### 2. `v_health.failures_total` 改為近期視窗（低）
目前是永久累計，對「現在健不健康」沒有參考價值
（Claude 目前顯示 80 次失敗，全是憑證問題修復前的歷史）。
改為「最近 24 小時失敗次數」較有用。UI 已改用 `last_weekly_at` 判斷停擺，
故此項不影響正確性。

### 3. UI 顯示 `ended_early`（低）
目前這個標記只躺在 DB 裡。使用者看到週用量從 3% 掉回 0% 時，第一直覺是
「抓取壞了」—— 而這個標記存在的理由就是要區分這兩件事。

### 4. 接近上限的通知提醒（低）
brief 列為 v1 non-goal。資料齊備後是很便宜的加法。

### 5. 決定小時桶可接受的抹平上限（低 —— 實測目前無影響）
`delta_max_gap_seconds`(900) **不是排程參數，是讀取時的歸屬政策**：一對樣本
跨過整點界線時，間隔要多短才算「整包算給其中一小時可以接受」。它管的是
「一根小時長條最多可以錯幾分鐘」。

**它無法挽回排程沒抓到的解析度。** 若 app 真的 30 分鐘才取樣一次，把門檻調大
只是把 unknown 改標成「已歸屬（但可能錯 30 分鐘）」—— 拿誠實換覆蓋率的假象。
取樣間隔受 `NSBackgroundActivityScheduler` 的 `.utility` QoS 影響（系統在電源／
散熱吃緊時會延後），那是另一個問題，且是設計上接受的行為。

本條原本寫「累積資料後用實際漂移分布校準」，**那是錯的框法** —— 漂移分布決定
不了這個值，它要回答的是產品問題。資料只能告訴你門檻落在密集區還是平坦區。

**2026-08-30 實測：落在平坦區。** 600～7200 秒之間，已歸屬與 unknown 的百分比
完全不動（只有 pair 計數在變，因為長間隔那些 pair 的 delta 本來就是 0）；
往下調到 300 秒才開始有影響（7% 轉為 unknown）。

結論：**暫時不需要動。** 除非日後 UI 要對使用者明示「這根長條可能偏移多久」，
屆時才需要把這個數字當成一個公開的產品承諾來訂。

### 7. 備援：不需憑證的 Claude 數字來源（低，尚未需要）
[Claude-Code-Usage-Monitor](https://github.com/Maciek-roboblog/Claude-Code-Usage-Monitor)
的 `--statusline` 模式接收 **Claude Code 主動餵給 statusline 指令的 `rate_limits`** ——
那是官方數字，而且**完全不需要認證**，是 Claude Code 自己遞過來的。

不能取代目前的做法：只有 Claude Code 正在跑時才有新數字（本專案要的是常駐背景
取樣），而且沒有 Codex。但如果哪天憑證那條路又壞掉（scope 變更、端點下線、
Keychain 政策再改），這是唯一已知的 plan B，值得記著。

同一個專案的預設模式是讀本機 JSONL 對話紀錄自己算 token —— **那條路本專案不走**，
理由見 non-goal：它只看得到這台機器上透過 Claude Code 做的事，而週用量是帳號
層級的（與 D-012 拒絕「過期寫 0」是同一個理由）。

### 6. 接 Codex 的快取資料（中）
Codex 的 `~/.codex/sessions` 與 `archived_sessions` 的 `rollout-*.jsonl` 裡有對等資料：
`payload.info.last_token_usage` 含 `input_tokens` / `cached_input_tokens` /
`cache_write_input_tokens` / `output_tokens` / `reasoning_output_tokens`。

四個與 Claude 的差異要處理：

| | Claude | Codex |
|---|---|---|
| 去重鍵 | `requestId` | 沒有；用 **session 檔 + `ordinal`** |
| 專案路徑 | 每行都有 `cwd` | 只在第一行的 `session_meta`，要往下帶 |
| 額外欄位 | — | `reasoning_output_tokens` |
| 快取 TTL | 有 5m／1h 分解 | **未知** |

最後一項最重要：**「閒置後重寫」這個歸因對 Codex 不成立**，因為我們不知道它的
快取存活多久。套用 Claude 的 1 小時門檻就是在編。接進來時那一欄要留白，
等有辦法觀測到 TTL 再說。

另外那些檔案裡有 `payload.rate_limits` —— **官方用量數字，不需要憑證**。
這是 #7 在找的 Codex 備援路徑。

## 不做（brief 的 non-goal，仍然有效）

- **Gemini** —— 其配額是每日請求數，weekly % 這個指標不存在
- **token 級成本估算** —— 與官方 % 定義不同，混用會讓數字失去意義
- **多帳號 / 多機器同步 / 雲端備份**
- **上架 App Store** —— 沙盒限制與本專案需求衝突（見 D-006）
