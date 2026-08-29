# 工程慣例

適用於本 repo 的所有程式碼。與一般 Swift 風格不同之處都附了理由 ——
**不同意可以改，但要連理由一起改。**

## 分層

```
AIUsage（app 殼，極薄）
    └── AIUsageKit
          UsageUI ──────► UsageStore ──► UsageCore
          UsageProviders ──────────────► UsageCore
```

依賴方向單向向右。**`UsageCore` 零 I/O** —— 不碰網路、不碰檔案、不碰資料庫、
不 import SwiftUI。它裝的是型別、解析器、與窗別判定這些純函式。

理由：整個專案唯一有複雜度、也唯一會出微妙 bug 的地方就是這些推導。
隔離成純函式，就能用單元測試餵各種變態情境，完全不用開 app、不用打網路。
**這是本專案該花力氣的地方，不是切模組的數量。**

app 殼只做接線（`AppState`、`Sampler`）。排程器放在 app 殼是刻意的 ——
`NSBackgroundActivityScheduler` 與 `NSWorkspace` 通知本質是 app 生命週期膠水，
真正有邏輯的部分都已在 Core/Store 裡可測。

## 資料層

**Schema 是對外契約。** 使用者會用 `sqlite3` / DuckDB / pandas 直接查。
欄位不隨手改名，變更一律走 migration。

**Migration 只增不改。** `Sources/UsageStore/Resources/NNN_name.sql`，
依檔名順序註冊。已套用的檔案**不得修改** —— 既有資料庫不會重跑它。
要改 schema 或 view，新增下一個編號。

**推導邏輯寫成 SQL view，不寫在 Swift。** delta、gap、窗身分、提前重置判定
全部住在 view 裡。Swift 端與外部分析工具讀同一份規則 —— 單一事實來源，
永遠不會漂移。`UsageCore` 只負責 domain 型別與 provider 回應歸一化。

**原始樣本不可變。** `sample` 只 INSERT。推導錯了改 view，資料不用動。

**每次取樣都寫 `sample`，即使數值沒變。** 「值沒變」本身就是資訊 ——
少了它就無法區分「沒用」與「沒觀測」，而那正是本專案要回答的核心問題。

**`raw_payload` 只在解析值或 JSON 結構變化時寫入。** 不可對整包 body 做雜湊去重
（Codex 回應含 `reset_after_seconds`，每次呼叫都不同，逐 byte 比對會讓儲存量
回到 200 MB/年）。結構指紋用排序後的 key path 雜湊，順便當端點改版的偵測器。

**GRDB 設定**：`DatabasePool`（自動 WAL）+ `busyTimeout`。
app 是唯一 writer，外部分析工具為唯讀 reader —— 這是 WAL 最理想的情境。
`ValueObservation` 偵測不到外部行程寫入（本專案不從外部寫，不受影響）。

## 錯誤處理

**分類必須反映補救方式的差異**，不是反映 HTTP 狀態碼：

| kind | 觸發 | 使用者該做什麼 |
|---|---|---|
| `auth` | 401，或憑證過期／缺 scope | 重新登入 |
| `blocked` | 403 且 body 非 JSON | UA／風控問題，**不是**認證問題 |
| `rate_limited` | 429 | 什麼都不用做，會自動退避重試 |
| `missing_window` | 回應成功但缺該窗 | 觀察，可能是端點改版 |

403 要看 body：Anthropic 的 API 層 `permission_error` 是 JSON，
Cloudflare 的風控頁是 HTML。前者歸 `auth`，後者歸 `blocked`。

**錯誤訊息要可行動。** 「Claude token 已過期」不夠，要寫「開一次 Claude Code
讓它續期即可 —— 本 app 唯讀，不會自行續期」。

**良性停擺與真正故障要分級。** 憑證過期、被限流屬良性（開一下就好／會自己恢復），
不該與「取樣壞掉」用同一種警示強度 —— 狼來了喊多了就沒人看。

## 測試

**fixture 照真實觀察到的現象寫，不要理想化。** 本專案最嚴重的兩個 bug
都通過了當時的全部測試，因為 fixture 用乾淨的整數 `resets_at`，
測不出真實的 ±1s 抖動與佔位值。

每個回歸測試的註解要寫明**它在防什麼真實事故**，例如：

```swift
/// Anthropic 的 resets_at 在秒級會 ±1s 抖動（實測同一個週窗交替出現
/// 1788310799 / 1788310800）。精確比對會把每次抖動判成一次重置，
/// 而重置的 delta 等於當前百分比 —— 實測累積出 2641% 的假 delta。
```

改動推導邏輯後，**必須在真實資料庫的副本上驗證**（見 AGENTS.md）。

## Swift

- Swift 6 嚴格並行。不要用 `static var` 全域可變狀態 ——
  需要可設定就從建構子注入（見 `UserAgent`）。
- 需要序列化的有狀態元件用 `actor`（見 `ClaudeCredentialSource` 的續期冷卻）。
- UI 狀態用 `@Observable` + `@MainActor`。
- **加 SF Symbol 前先驗證名稱存在** —— 打錯不會編譯失敗，只會畫空白。

## 註解

註解寫**為什麼**，不寫做什麼。特別是這三種情況一定要寫：

1. 違反直覺的決定（為何唯讀、為何不寫回、為何不用 `Timer`）
2. 從真實事故學到的約束（附上實測數字）
3. 繞過的 API 陷阱（附上不繞會怎樣）

## Commit

主旨用祈使句，中文。內文說明**為什麼**與**推翻了什麼**，附實測數字。
決策若被推翻，在 [decisions.md](decisions.md) 補一筆，不要默默改掉。

```
fix: 更正窗模型 —— 以首次使用為錨點，而非滾動窗

003 依 180 筆樣本判定 Codex 為「滾動窗」。該推論有致命缺陷：
那 180 筆的 percent 全部是 0.0，等於在「毫無用量」的資料上推論窗行為。
```
