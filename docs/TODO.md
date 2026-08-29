# TODO

依重要性排列。現況見 [status.md](status.md)，決策背景見
[history/decisions.md](history/decisions.md)。

### 1. 驗證憑證自動續期（高）

> ⏰ **首次驗證時點：2026-08-29 約 20:33**
> （access token 於 20:38 到期，續期緩衝為到期前 5 分鐘）
> 前提：app 必須在該時刻執行中。憑證已備份於 Keychain 項目
> `ai-usage.claude-credentials-backup`。

D-010 的實作**尚未在真實過期情境下跑過** —— 當時續期端點持續回 429，
最後是使用者重新登入解決的。下次 token 接近到期時要確認：

- 是否在到期前 5 分鐘自動續期成功
- 寫回後 `claude` CLI 是否仍正常（refresh token 若輪替，寫回失敗會使 CLI 失效）
- client_id `9d1c250a-…`（從 CLI 執行檔 `strings` 取得）是否確實適用

**若續期失敗，Claude 追蹤會再次永久停擺** —— 這是目前最大的單點風險。

驗證方式（20:40 之後）：

```bash
# 續期成功的話 expiresAt 會往後跳
security find-generic-password -s "Claude Code-credentials" -w | \
  python3 -c "import json,sys,time; o=json.load(sys.stdin)['claudeAiOauth']; \
  print(time.strftime('%Y-%m-%d %H:%M', time.localtime(o['expiresAt']/1000)))"

# 該時段的取樣應全部 ok=1；若出現 auth/rate_limited 即為失敗
sqlite3 "$HOME/Library/Application Support/AIUsage/usage.sqlite" \
  "SELECT datetime(completed_at,'unixepoch','localtime'), ok, error_kind
     FROM fetch WHERE service='claude' AND completed_at > strftime('%s','now','-1 hour')
    ORDER BY id;"
```

### 2. 開機自啟（中）
`SMAppService.mainApp.register()`。需先把 app 放進 `/Applications`。
狀態要從 `SMAppService` 讀取而非自行記錄（使用者可能在系統設定裡關掉）。

### 3. 校準 `delta_max_gap_seconds`（中）
目前 900 秒是推估值，沒有實證。累積一兩週後可用實際漂移分布校準。
**因存的是原始樣本，改門檻不需重建歷史**，view 重算即可。

### 4. `v_health.failures_total` 改為近期視窗（低）
目前是永久累計，對「現在健不健康」沒有參考價值
（Claude 目前顯示 80 次失敗，全是憑證問題修復前的歷史）。
改為「最近 24 小時失敗次數」較有用。UI 已改用 `last_weekly_at` 判斷停擺，
故此項不影響正確性。

### 5. 日／週粒度切換（低）
目前只有小時圖。資料累積到數天後小時圖會過擠，屆時加粒度切換才有意義。

### 6. 接近上限的通知提醒（低）
brief 列為 v1 non-goal。資料齊備後是很便宜的加法。

## 不做（brief 的 non-goal，仍然有效）

- **Gemini** —— 其配額是每日請求數，weekly % 這個指標不存在
- **token 級成本估算** —— 與官方 % 定義不同，混用會讓數字失去意義
- **多帳號 / 多機器同步 / 雲端備份**
- **上架 App Store** —— 沙盒限制與本專案需求衝突（見 D-006）
