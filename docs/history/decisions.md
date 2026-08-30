# 決策紀錄

依時間排列。**被推翻的決策保留原文並標註**，因為推翻的理由本身是這個專案
最有價值的資產 —— 它記錄了哪些推論方式會出錯。

原始需求與範圍協議見 [brief.md](brief.md)（歷史文件，不再更新）。

---

## D-001 只追 weekly；不做 Gemini
**2026-08-21** · 現行

Gemini / Code Assist 的配額是**每日請求數**（Free 1000、AI Pro 1500、
Ultra 2000 req/day），**weekly % 這個指標不存在**。硬做只能自己編指標。

架構預留 provider 擴充點，等 Google 真的開放再加。

---

## D-002 存不可變的原始樣本，推導一律在查詢時
**2026-08-24** · 現行 · **本專案最重要的決定**

不在寫入時計算 delta。`sample` 只 INSERT，delta / gap / 窗身分全部由 SQL view
在查詢時推導。

理由：允許缺樣本的前提下，若寫入時就算好 delta，一旦補樣本或發現漏抓，
歷史就爛了。

**這個決定已經救過兩次**：D-007 與 D-008 兩個嚴重的推導錯誤（累積出 2641% 假
delta、123 個假窗），修正時**一筆資料都不用動**，只改 view。若當初把 delta
算好才寫進 DB，那兩次都會毀掉全部歷史。

---

## D-003 推導邏輯寫成 SQL view，不寫在 Swift
**2026-08-24** · 現行

使用者是資料工程師，會用 `sqlite3` / DuckDB / pandas 直接查 DB。
若 Swift 一套、外部一套，兩份實作必然漂移。

代價：複雜邏輯用 SQL 表達較費力（見 `v_window_seq` 的 gaps-and-islands）。
收益：單一事實來源，外部工具查到的 delta 與 app 顯示的完全一致。

---

## D-004 取樣間隔 5 分鐘；`sample` 與 `raw_payload` 分表
**2026-08-24** · 現行

**為何不是 1 小時**：`NSBackgroundActivityScheduler` 明確不保證準時，
而 gap 規則禁止跨界均攤。每小時只取樣一次的話，樣本會落在 10:03 / 11:07 / 12:02…，
**每段 delta 都橫跨兩個小時，全部不可歸屬**。相鄰樣本間隔 `i` 分鐘時，
delta 落在同一小時內的機率為 `(60-i)/60`：60 分 → ~0%，5 分 → 92%。

**為何分表**：每次都存完整 `raw_json`（Claude 約 1.5KB）一年約 200 MB。
`sample` 窄行（~50 bytes）每次都寫；`raw_payload` 僅在解析值或**結構**變化時寫。
不可對整包 body 做雜湊去重 —— Codex 回應含 `reset_after_seconds`，每次都不同。

---

## D-005 窗別一律以 `limit_window_seconds` 判定
**2026-08-25** · 現行

不以 `primary_window` / `secondary_window` 的**欄位位置**判定。

Codex 的窗會換位：2026-07 前 primary=5h / secondary=週，5 小時暫停期間
primary=週 / secondary=null，[5 小時於 2026-08-25 對 Plus 恢復](https://9to5mac.com/2026/08/24/openai-restores-5-hour-codex-and-work-limits-for-chatgpt-plus-users/)
後換回 primary=5h / secondary=週。

以欄位位置對應，換位當下會**默默把 5 小時百分比寫進 weekly 序列** ——
不報錯、不崩潰，只是資料錯了。

**這個決定在 4 天後應驗**：2026-08-28 實測到的回應中，`primary_window` 確實
已變成 5 小時窗。有回歸測試釘住。

---

## D-006 關閉 App Sandbox，開啟 Hardened Runtime
**2026-08-25** · 現行

沙盒**技術上做得到**（`NSOpenPanel` + security-scoped bookmark），但代價是：
`~/.codex` 是隱藏目錄、開檔面板預設看不見；且 ChatGPT.app 原子寫入換 inode
會使 bookmark stale。非沙盒下 `~/.codex` 不在 TCC 保護範圍，直接讀、零彈窗。

> 初版文件曾寫「**必須**關掉沙盒」，那是不精確的。正確說法是「可以不關，
> 但代價不划算」。

---

## D-007 窗身分改用容差比對
**2026-08-29** · 現行 · **推翻「以 `resets_at` 精確比對」**

實測發現 Anthropic 的 `resets_at` 在秒級會 **±1s 抖動**（同一個週窗交替出現
`1788310799` / `1788310800`，原值帶 6 位小數且本身有微秒級漂移）。

精確比對把每次抖動判成一次重置，而重置的 delta 規則是「等於當前百分比」——
**49 次假重置累積出 2641% 的假 delta**，小時桶出現 270%、日桶 2106%。

修正：相鄰 `resets_at` 差異超過 `reset_tolerance_seconds`(120) 才算換窗。
真正換窗移動約 7 天，抖動 1 秒以內 —— 相差 5 個數量級。

**教訓**：fixture 用的是乾淨的整數 `resets_at`，永遠測不出這個問題。
只有真實資料會浮現。

---

## D-008 窗模型 = 固定時長、以首次使用為錨點
**2026-08-29** · 現行 · **推翻同日稍早的「Codex 是滾動窗」**

> **被推翻的結論（migration 003）**：依 180 筆樣本中 `resets_at - observed_at`
> 恆為 `window_seconds`，判定 Codex 為滾動窗，並為此加了 per-provider 的
> `window_policy` 表。

該推論有致命缺陷：**那 180 筆的 `percent` 全部是 0.0** —— 等於在「毫無用量」
的資料上推論窗的行為。推翻它所需的對照組一直就在手邊：同一份資料中
Codex 有 2% 用量時，`reset_after_seconds` 是 138763（約 1.6 天），不是 604800。

官方與客服說法：「weekly window starts at the first message you send」；
每個帳號的窗 anchors to its own first request after the previous reset。

正確模型：**窗未開始時，伺服器回報 `resets_at = 現在 + window_seconds` 作為
佔位值**。由此得到一條對兩家都成立的統一規則，`window_policy` 表整個刪除：

> `resets_at - observed_at ≈ window_seconds` ⟹ 窗未開始，`resets_at` 無身分意義。

**現場驗證（2026-08-30）**：Codex 週窗提前重置後，新窗的錨點固定在 07:57:41，
而第一個非零百分比出現在 08:25 —— **錨點早於任何可見用量**（該次請求不足 0.5%，
整數百分比仍顯示 0）。滾動窗模型不可能產生這個現象，首次使用錨點模型才會。
在此之前這個模型只有官方說法支持，現在有直接觀測。

**教訓**：下結論前先問「這份資料涵蓋了我要推論的那個變項的變化嗎」。
錯誤模型需要 per-provider 特例，正確模型只需一條規則 ——
**需要愈多特例，愈可能是模型錯了。**

---

## D-009 Claude 憑證改讀 Claude Code 自己的登入
**2026-08-28** · 現行 · **推翻「用 `claude setup-token`」**

> **被推翻的方案**：請使用者跑 `claude setup-token` 產生專用 token，
> 存進本 app 自己的 Keychain 項目。當時的理由是「keychain 跨 app 分享綁 Team ID」。

實測 `setup-token` 的 token 打 `/api/oauth/usage` 得到：

```
permission_error: OAuth token does not meet scope requirement user:profile
```

它是推論用 token，scope 固定在伺服器端（`claude setup-token` 除了 `-h`
沒有任何參數）。

而「跨 app keychain 綁 Team ID」**只限制沙盒 app** —— 本 app 非沙盒（D-006），
macOS 只會跳一次授權對話框，按「一律允許」即可。

**教訓**：把沙盒情境的限制套用到非沙盒架構上，導致繞了遠路還走不通。

---

## D-010 Claude 憑證由本 app 自行續期並寫回
**2026-08-29** · 現行 · **推翻「唯讀，絕不寫回」**

> **被推翻的原則**：「續期交給 Claude Code，本 app 唯讀，避免與其續期邏輯衝突。」

該原則的前提不成立。實測：`Claude Code-credentials` 這個 Keychain 項目
**只有 `claude` CLI 會續**（`claude auth status` 也不會續，實測 token 尾碼前後相同）。
Claude 桌面 App 用自己的 Electron cookie，完全不碰它。

只用桌面 App 的使用者，該 token 過期後**再也不會更新** ——
Claude 追蹤永久停擺，而非偶爾有 gap。

原則的理由是「避免與續期者打架」，但這裡**根本沒有其他續期者**。

實作：過期前 5 分鐘以 refresh token 換新，完整保留原 JSON 結構寫回
（只替換 oauth 欄位，不破壞 CLI 登入）。429 時退避 15 分鐘 ——
取樣每 5 分鐘一次，不退避等於持續敲一個認證端點。

Codex 的 `~/.codex/auth.json` **維持唯讀**，因為 ChatGPT.app 確實會續期。

**驗證（2026-08-29 20:36）**：access token 於 20:38 到期，20:36:35 那次取樣
觸發續期並成功，`expiresAt` 前移至隔日 04:36。同時確認：

- 該次取樣 `ok=1`，前後 6 小時共 72 次取樣、**0 次失敗**
- `claude auth status` 仍回報 `loggedIn: true` ——
  **寫回未破壞 CLI 登入狀態**，這是本方案最危險的失敗模式

至此 client_id `9d1c250a-…`（從 CLI 執行檔 `strings` 取得）與寫回機制
皆已在真實情境驗證。

---

## D-011 良性停擺與真正故障分級
**2026-08-28** · 現行

憑證過期、被限流屬良性（開一下就好／會自己恢復），不與「取樣壞掉」用同一種
警示強度。menu bar 只在真壞了才顯示警告三角，良性停擺只是變灰。

理由：放個週末回來不該看到警告三角 —— 狼來了喊多了就沒人看。

同時：**已恢復的舊失敗不再影響 UI**（只看最後一次嘗試）。

---

## D-012 拒絕「憑證過期時寫入 0」
**2026-08-29** · 現行

使用者提議「過期就當作 0，沒用就是沒用量」。**未採納**，理由：

1. weekly % 是**帳號層級**的。本機閒置不代表額度未消耗（網頁版、手機、
   另一台電腦都算）。
2. 假 0 會造成實際損害：最後讀數 52%，寫入 0% 後因拿不到 `resets_at`
   會被判成**窗重置**；三天後回來看到真實的 60%，系統會認為新窗從 0 累積到 60，
   **把 60% 全部灌進那一個小時**，同時該窗總量顯示為 0。
3. **使用者要的效果本來就有**：沒樣本 → gap → delta 不累積。
   「沒觀測」對所有用量總和的貢獻本來就是 0，差別只在圖表誠實斷開。

改為處理使用者真正在意的部分：良性停擺不掛警告（D-011）。

---

## D-013 圖上區分「有取樣但無變化」與「完全沒取樣」
**2026-08-29** · 現行

先前兩者在圖上都是空白，得逐格 hover 才分得出來 —— 那正是本專案最該避免的
混淆（無資料 ≠ 0）。有取樣但 delta 為 0 的小時改畫**灰色零基線**。

同批修正（皆由實際截圖才發現）：
- 「未知區間」的 `opacity(0.45)` 讓橘色在深色背景上變成褐色，與圖例對不上 → 移除
- X 軸固定 6 小時一格，長條細又對不上時間 → 依資料跨度自動加密，午夜加粗標日期
- hover 的「最近長條」規則會讓游標停在空白處時跳到遠處長條 → 改為取游標所在整點，
  並以整點高亮帶顯示選中範圍

**教訓**：前面數輪都在盲改 UI。取得 Screen Recording 權限後第一次截圖，
立刻看到三個問題。**UI 一定要親眼看過。**

---

## D-014 排程器放在 app 殼，不另開 target
**2026-08-28** · 現行

`NSBackgroundActivityScheduler` 與 `NSWorkspace` 通知本質是 app 生命週期膠水，
很薄；真正有邏輯的部分（解析、寫入、delta）都已在 Core/Store 裡可測。

若日後排程策略變複雜（例如依用量調整頻率），再抽成 `UsageSampling` target。
