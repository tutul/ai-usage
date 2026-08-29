# ai-usage

常駐 macOS menu bar，持續追蹤 **Claude** 與 **Codex** 訂閱的 weekly 用量百分比。
每筆原始樣本永久存進本機 SQLite，可回溯任意區間的小時／日／週消耗。

```
menu bar 圖示（gauge，隨用量變色）
  └─ 點開 ─ 本週用量：Claude 61% / Codex 2%，重置倒數，資料新鮮度
      └─ 歷史圖表 ─ 小時級長條圖，hover 顯示明細
```

## 需求

| 項目 | 版本 |
|---|---|
| macOS | 14 以上（開發於 26.6） |
| Xcode | 16 以上（開發於 26.6） |
| Claude Code | 必須安裝並已 `claude auth login` |
| ChatGPT / Codex | 必須已登入（本 app 讀 `~/.codex/auth.json`） |

## 安裝

```bash
git clone <repo> && cd ai-usage

xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug \
  -derivedDataPath .build/xcode build

open .build/xcode/Build/Products/Debug/AIUsage.app
```

首次啟動時 macOS 會詢問是否允許讀取 Keychain 中的
「Claude Code-credentials」，**按「一律允許」**。

> ⚠️ 本 app 為 ad-hoc 簽章，**每次重新建置簽章都會改變**，該授權可能再次跳出。
> 日常使用不重建就不會遇到。

## 憑證怎麼來

兩家都是**唯讀既有登入狀態**，你不需要另外準備 token。

| Provider | 來源 | 續期 |
|---|---|---|
| **Claude** | Keychain `Claude Code-credentials`（或 `~/.claude/.credentials.json`） | **本 app 自行續期**（過期前 5 分鐘用 refresh token 換新的，完整保留原 JSON 結構寫回，不破壞 CLI 登入） |
| **Codex** | `~/.codex/auth.json` | 由 ChatGPT.app 負責，本 app **唯讀不寫回** |

> ⚠️ **不要用 `claude setup-token`。** 它產生的 token 缺少 `user:profile` scope，
> 打 `/api/oauth/usage` 只會得到
> `permission_error: OAuth token does not meet scope requirement user:profile`。

Claude 的 refresh token 約 30 天到期，屆時需重跑 `claude auth login`。
選單會顯示明確原因，不會只給看不懂的錯誤。

## 使用上要知道的事

**這個 app 必須一直開著才有資料。** 選單內有「開機時自動啟動」可勾選。

> ⚠️ 若要用開機自啟，**請先把 `AIUsage.app` 複製到 `/Applications`** 再啟用 ——
> 從建置目錄註冊會把該路徑寫進登入項目，`.build` 一清就失效。UI 會提醒你。

未執行期間的空缺會在圖表上誠實呈現為斷點，不會被補成 0。

**圖表上的四種視覺，意義完全不同：**

| 視覺 | 意義 |
|---|---|
| 藍色長條 | 該小時有用量 |
| 橘色長條 | 未知區間 —— 消耗確實發生，但取樣中斷，無法歸屬到特定小時 |
| **灰色基線** | **有取樣，但用量無變化** |
| 完全空白 | **該小時沒有取樣** |

**Codex 的 `used_percent` 只有整數解析度（1%）。** 小時層級多數格子會是灰色基線，
然後某格跳 1 —— 那不是壞掉，是資料源的性質。日／週層級才有意義。

**取樣間隔不保證。** 使用 `NSBackgroundActivityScheduler`（休眠期間不觸發、
醒來不補跑錯過的次數），它有 tolerance，實際間隔會浮動。

## 直接查資料庫

DB 位於 `~/Library/Application Support/AIUsage/usage.sqlite`（WAL 模式，
app 寫入的同時可唯讀查詢）。**delta / gap / 窗身分的判定邏輯都寫成 SQL view，
外部工具與 app 讀的是同一份規則**，不會有兩套實作漂移。

```bash
sqlite3 "$HOME/Library/Application Support/AIUsage/usage.sqlite" \
  "SELECT service, hour_local, used_percent, unknown_percent
     FROM v_hourly WHERE window_kind='weekly'
    ORDER BY hour_local DESC LIMIT 24;"
```

| View | 用途 |
|---|---|
| `v_current` | 各服務／窗別的最新讀數，含 `window_started` |
| `v_hourly` / `v_daily` | 分桶消耗，`used_percent` 與 `unknown_percent` 分離 |
| `v_sample_delta` | 每組相鄰樣本的 delta 與分類（可稽核） |
| `v_unknown_span` | 不可歸屬的區間 |
| `v_window_seq` | 為每筆樣本標上窗編號 |
| `v_window_summary` | 每個窗的實際用量（**不經 delta 推導，最精確**），含 `ended_early` |
| `v_health` | 取樣健康度，含 `last_weekly_at` |

⚠️ **DB 檔不可放在 iCloud Drive / Dropbox / 網路磁碟** —— WAL 依賴 shared memory。

⚠️ **不要用 `cp` 複製資料庫。** WAL 模式下最新資料在 `-wal` 檔裡，`cp` 只會拿到
已 checkpoint 的舊資料（實測差了 4 小時）。要複製請用：

```bash
sqlite3 "$HOME/Library/Application Support/AIUsage/usage.sqlite" ".backup /tmp/snapshot.sqlite"
```

直接用 `sqlite3` 開原檔查詢則沒有這個問題。

## 開發

```bash
cd Packages/AIUsageKit && swift test    # 28 個測試，不需啟動 app
```

- 架構與資料模型 → [docs/architecture.md](docs/architecture.md)
- 工程慣例 → [docs/conventions.md](docs/conventions.md)
- 決策紀錄（含被推翻的） → [docs/history/decisions.md](docs/history/decisions.md)
- 現況 → [docs/status.md](docs/status.md)
- 下一步 → [docs/TODO.md](docs/TODO.md)
- Agent 工作指引 → [AGENTS.md](AGENTS.md)

## 已知限制

- **端點皆為未公開 API**，可能無預警變更。每筆樣本保留原始回應
  （僅在值變或 JSON 結構變時），改版時可回溯比對。
- **delta 加總是近似值** —— 百分比下修時夾擠為 0 會微幅高估。
  精確用量請讀 `v_window_summary.used_percent`（不經 delta 推導）。
- **本地時區分桶由讀取端 TZ 決定**，跨時區讀同一個 DB 會得到不同分桶。
- **Gemini 未支援** —— 其配額是每日請求數，weekly % 這個指標不存在。

## 授權

[MIT](LICENSE)。可自由使用、修改、散布，**須保留著作權聲明與授權條款**。
