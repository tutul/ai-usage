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
| Apple ID | 建置需要，**免費帳號即可**（見下方簽章說明） |

## 安裝

**沒有預先建好的二進位檔可下載。** 本專案以 Apple Development 憑證簽章，那是
開發用憑證、只能在簽章者自己的機器上執行；散布給別人需要 Developer ID
憑證（$99/年）與公證，本專案不打算做。**請自行建置。**

### 1. 設定你自己的簽章

專案檔**不含**任何人的 team ID —— 它讀 `Config/Local.xcconfig`，那個檔案已被
gitignore。複製範本並填入你自己的：

```bash
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

```
AIUSAGE_DEVELOPMENT_TEAM = 你的十位 team ID
```

還沒有 Apple ID 的話先加：`Xcode → Settings → Accounts → +`。**免費帳號就夠**，
不需要付費的 Developer Program。加完之後 team ID 可以這樣查：

```bash
security find-identity -v -p codesigning     # 括號裡那十位英數
```

> **請用 `Config/Local.xcconfig`，不要在 Xcode 的 Signing & Capabilities
> 下拉選單裡選 Team。** 從 UI 選會把 team ID **寫回 `project.pbxproj`**，
> 於是你的 git 永遠帶著一個不該提交的改動。

Xcode UI 裡只需要確認這兩項（專案已設好，正常不用動）：

```
☑ Automatically manage signing
Signing Certificate:  Development        ← 不是 Sign to Run Locally
```

`Sign to Run Locally` 就是 ad-hoc，選了它 team 設定等於沒作用。

在 Xcode 裡按 ⌘B 建置一次，讓它建立憑證（過程中會要求存取鑰匙圈存放私鑰，允許）。
確認：

```bash
security find-identity -v -p codesigning     # 應出現一張 Apple Development
codesign -d -vv .build/xcode/Build/Products/Debug/AIUsage.app 2>&1 | grep TeamIdentifier
```

`TeamIdentifier` 必須有值。若是 `not set`，表示 Signing Certificate 還停在
`Sign to Run Locally`（＝ad-hoc），**團隊設定等於沒作用**。

若建置直接失敗並顯示 `Signing for "AIUsage" requires a development team`，
就是 `Config/Local.xcconfig` 還沒建立或內容是空的。

> **為什麼不能用 ad-hoc？** ad-hoc 沒有 team ID，macOS 只能用 cdhash 把本 app
> 釘進 Keychain 項目的分區清單，而 cdhash **每次重新建置都會變** —— 於是每個
> 新 build 都是陌生身分，都要重新輸入一次鑰匙圈密碼，而且會把 Claude Code
> 自己的存取權擠掉。詳見 [D-015](docs/history/decisions.md)。

### 2. 建置與啟動

```bash
xcodebuild -project AIUsage.xcodeproj -scheme AIUsage -configuration Debug \
  -derivedDataPath .build/xcode build

open .build/xcode/Build/Products/Debug/AIUsage.app
```

### 3. 一次性的 Keychain 授權（重要，順序不能反）

本 app 讀 Claude Code 的 Keychain 項目，而 Claude Code 自己是透過
`/usr/bin/security` 讀它。macOS 的分區清單在使用者批准提示時是**「換成」批准者、
不是「加進」批准者** —— 所以兩邊會輪流被要求輸入密碼，永遠不會停。

**在第一次啟動 app 之前**，把兩邊一次寫進分區清單（`TEAMID` 換成上面查到的、
`ACCOUNT` 通常是你的使用者名稱）：

```bash
security set-generic-password-partition-list \
  -S apple-tool:,apple:,teamid:TEAMID -s "Claude Code-credentials" -a ACCOUNT
```

會跳出系統對話框要求 login keychain 密碼（可能問兩次）。**不要用 `-k` 帶密碼**，
那會留在 shell 歷史裡。

順序反了的話，那一次「一律允許」會覆蓋掉你設定的清單，得重跑一次。

驗證（唯讀）：

```bash
swift scripts/keychain-acl.swift
```

分區清單要同時看到 `apple-tool:`、`apple:`、`teamid:<你的>`。
Keychain Access 的 GUI **看不到分區清單**，只能用這支工具查。

## 憑證怎麼來

兩家都是**唯讀既有登入狀態**，你不需要另外準備 token。

| Provider | 來源 | 續期 |
|---|---|---|
| **Claude** | **讀** Keychain `Claude Code-credentials`（只在本 app 還沒有自己的憑證時），**寫** 自己的 `AIUsage-claude-credentials` | **本 app 自行續期**（過期前 5 分鐘換新）。**絕不寫回 Claude Code 的項目** —— 寫它會重設它的分區清單，害 Claude Code 每天要你輸入好幾次鑰匙圈密碼 |
| **Codex** | `~/.codex/auth.json` | 由 ChatGPT.app 負責，本 app **唯讀不寫回** |

> ⚠️ **不要用 `claude setup-token`。** 它產生的 token 缺少 `user:profile` scope，
> 打 `/api/oauth/usage` 只會得到
> `permission_error: OAuth token does not meet scope requirement user:profile`。

Claude 的 refresh token 約 30 天到期，屆時需重跑 `claude auth login`。
選單會顯示明確原因，不會只給看不懂的錯誤。

> ### ⚠️ 這會讓 `claude` CLI 需要重新登入一次
>
> Claude 的 refresh token 是**單次有效**的：用掉一個就換一個新的，舊的立刻作廢。
> 本 app 續期之後，Claude Code 手上那份就過期了，`claude` CLI 下次要用時會失敗，
> 需要跑一次 `claude auth login`。
>
> **為什麼仍然這樣做**：另一條路是寫回 Claude Code 的項目，但那會重設該項目的
> 分區清單，讓 macOS **每天要你輸入兩三次鑰匙圈密碼、永遠不停**。
> 一次性的重新登入換掉持續的干擾，是刻意的取捨（見 [D-016](docs/history/decisions.md)）。
>
> **不必手動處理**：若你重新登入、把 refresh token 換掉，本 app 的續期會失敗，
> 它會自動丟掉自己那份、下次取樣重新從 Claude Code 的項目取得憑證。
>
> Claude Code 的**桌面版不受影響** —— 實測它不靠這個項目續期。

## 只用其中一家？

選單裡的「追蹤的服務」可以個別關掉 Claude 或 Codex。沒訂閱的那家會持續產生
認證失敗，關掉就不再抓取，menu bar 也不會再把它算進狀態。

**關閉不刪除歷史** —— 已記錄的樣本留著，重新開啟就看得到。

這個開關存在 `UserDefaults`，不在資料庫的 `setting` 表。那張表放的是**推導參數**
（外部分析工具必須套用同一份規則才算得出一樣的結果），而「要不要追蹤」不影響
任何推導，只影響這個 app 抓不抓。

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
