# ai-usage

常駐 macOS menu bar，追蹤 **Claude** 與 **Codex** 訂閱的 weekly 用量百分比，
每筆原始樣本永久存進本機 SQLite，可回溯任意區間的小時／日／週消耗。

設計與取捨見 [docs/brief.md](docs/brief.md) 與 [docs/design-data-model.md](docs/design-data-model.md)。

## 設定

1. **Codex** —— 免設定。唯讀 `~/.codex/auth.json`，續期由 ChatGPT.app 負責。
2. **Claude** —— 免設定，但**必須安裝 Claude Code 並已登入**。
   本 app 唯讀 Claude Code 的憑證（`~/.claude/.credentials.json`，
   或 Keychain 項目 `Claude Code-credentials`）。

   首次讀取時 macOS 會跳一次授權對話框，按**「一律允許」**即可。
   本 app 為 ad-hoc 簽章，**每次重新建置簽章會改變，可能再次跳出**。

   > ⚠️ **不要用 `claude setup-token`。** 它產生的 token 缺少 `user:profile` scope，
   > 打 `/api/oauth/usage` 會得到
   > `permission_error: OAuth token does not meet scope requirement user:profile`。

   **本 app 會自行續期**（access token 過期前 5 分鐘用 refresh token 換新的，
   完整保留原 JSON 結構寫回，不破壞 `claude` CLI 的登入狀態）。

   > 為何需要自行續期：`Claude Code-credentials` 這個 Keychain 項目**只有 `claude` CLI 會續**。
   > Claude 桌面 App 用的是自己的 Electron cookie，完全不碰它。
   > 若你只用桌面 App，該 token 過期後就再也不會更新 ——
   > Claude 追蹤等於永久停擺，而非偶爾有 gap。

   續期端點若回 429，會退避 15 分鐘再試（不持續敲認證端點）。
   refresh token 本身也會過期（約 30 天），屆時需 `claude auth login`。

## 建置與執行

```bash
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Debug/AIUsage.app
```

測試（純域邏輯與資料層，不需啟動 app）：

```bash
cd Packages/AIUsageKit && swift test
```

## 直接查資料庫

DB 位於 `~/Library/Application Support/AIUsage/usage.sqlite`（WAL 模式，
app 寫入的同時可唯讀查詢）。delta／gap／重置的判定邏輯都寫成 SQL view，
**外部工具與 app 讀的是同一份規則**：

```bash
sqlite3 "$HOME/Library/Application Support/AIUsage/usage.sqlite" \
  "SELECT service, hour_local, used_percent, unknown_percent FROM v_hourly ORDER BY hour_local DESC LIMIT 24;"
```

| View | 用途 |
|---|---|
| `v_current` | 各服務／窗別的最新讀數 |
| `v_hourly` / `v_daily` | 分桶消耗，`used` 與 `unknown` 分離 |
| `v_sample_delta` | 每組相鄰樣本的 delta 與分類（可稽核） |
| `v_unknown_span` | 不可歸屬的區間（圖表畫斜線帶） |
| `v_window_seq` | 為每筆樣本標上窗編號（滾動窗恆為 0） |
| `v_window_summary` | 每個限額窗的實際用量（**不經 delta 推導，最精確**），含 `ended_early`（是否被提前重置）與 `observed_duration_seconds` |
| `v_health` | 取樣健康度，含 `last_weekly_at` |

⚠️ **DB 檔不可放在 iCloud Drive / Dropbox / 網路磁碟** —— WAL 依賴 shared memory。

⚠️ **不要用 `cp` 複製資料庫** —— WAL 模式下最新資料在 `-wal` 檔裡，
`cp` 只會拿到已 checkpoint 的舊資料（實測差了 4 小時）。要複製請用：

```bash
sqlite3 "$HOME/Library/Application Support/AIUsage/usage.sqlite" ".backup /tmp/snapshot.sqlite"
```

直接用 `sqlite3` 開原檔查詢則沒有這個問題。

## 已知限制

- 沒有樣本的小時**不會產生任何列**。無資料 ≠ 0，圖表據此斷線。
- Codex 的 `used_percent` 是整數（解析度 1%），小時層級偏粗，日／週才有意義。
- **限額窗以「首次使用」為錨點**（非日曆固定）。窗尚未開始時，伺服器回報
  `resets_at = 現在 + 窗長` 作為佔位值，倒數永遠不會減少 ——
  UI 因此顯示「未開始計時」而非假倒數。
- 取樣用 `NSBackgroundActivityScheduler`，有 tolerance，**不保證每小時都有樣本**。
- delta 加總是近似值（百分比下修時會夾擠為 0）；精確週用量請讀 `v_window_summary.used_percent`。
