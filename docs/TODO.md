# TODO

依重要性排列。現況見 [status.md](status.md)，決策背景見
[history/decisions.md](history/decisions.md)。

### 1. 開機自啟（中）
`SMAppService.mainApp.register()`。需先把 app 放進 `/Applications`。
狀態要從 `SMAppService` 讀取而非自行記錄（使用者可能在系統設定裡關掉）。

### 2. 校準 `delta_max_gap_seconds`（中）
目前 900 秒是推估值，沒有實證。累積一兩週後可用實際漂移分布校準。
**因存的是原始樣本，改門檻不需重建歷史**，view 重算即可。

### 3. `v_health.failures_total` 改為近期視窗（低）
目前是永久累計，對「現在健不健康」沒有參考價值
（Claude 目前顯示 80 次失敗，全是憑證問題修復前的歷史）。
改為「最近 24 小時失敗次數」較有用。UI 已改用 `last_weekly_at` 判斷停擺，
故此項不影響正確性。

### 4. 日／週粒度切換（低）
目前只有小時圖。資料累積到數天後小時圖會過擠，屆時加粒度切換才有意義。

### 5. 接近上限的通知提醒（低）
brief 列為 v1 non-goal。資料齊備後是很便宜的加法。

## 不做（brief 的 non-goal，仍然有效）

- **Gemini** —— 其配額是每日請求數，weekly % 這個指標不存在
- **token 級成本估算** —— 與官方 % 定義不同，混用會讓數字失去意義
- **多帳號 / 多機器同步 / 雲端備份**
- **上架 App Store** —— 沙盒限制與本專案需求衝突（見 D-006）
