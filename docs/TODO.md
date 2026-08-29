# TODO

依重要性排列。現況見 [status.md](status.md)，決策背景見
[history/decisions.md](history/decisions.md)。

### 1. 校準 `delta_max_gap_seconds`（中）
目前 900 秒是推估值，沒有實證。累積一兩週後可用實際漂移分布校準。
**因存的是原始樣本，改門檻不需重建歷史**，view 重算即可。

### 2. Claude `clientID` 不應寫死（中）
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

### 3. `v_health.failures_total` 改為近期視窗（低）
目前是永久累計，對「現在健不健康」沒有參考價值
（Claude 目前顯示 80 次失敗，全是憑證問題修復前的歷史）。
改為「最近 24 小時失敗次數」較有用。UI 已改用 `last_weekly_at` 判斷停擺，
故此項不影響正確性。

### 4. 週粒度（低）
小時與日已完成。週粒度需要新的 view（`v_weekly`），但在資料累積到數週前
沒有東西可看 —— `v_window_summary` 目前已能回答「每個窗用了多少」。

### 5. 接近上限的通知提醒（低）
brief 列為 v1 non-goal。資料齊備後是很便宜的加法。

## 不做（brief 的 non-goal，仍然有效）

- **Gemini** —— 其配額是每日請求數，weekly % 這個指標不存在
- **token 級成本估算** —— 與官方 % 定義不同，混用會讓數字失去意義
- **多帳號 / 多機器同步 / 雲端備份**
- **上架 App Store** —— 沙盒限制與本專案需求衝突（見 D-006）
