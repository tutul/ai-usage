# 現況

下一步見 [TODO.md](TODO.md)。

**最後更新：2026-08-29**

## 目前可用

| 功能 | 狀態 |
|---|---|
| Claude weekly / session 追蹤 | ✅ 運作中 |
| Codex weekly / session 追蹤 | ✅ 運作中 |
| Claude 憑證自動續期 | ⚠️ 已實作，**尚未在真實過期時驗證過** |
| SQLite 永久記錄 + SQL view 推導 | ✅ |
| menu bar 圖示（用量變色、停擺示警） | ✅ |
| 歷史圖表（小時級、hover 明細、重新整理） | ✅ |
| 開機自啟（`SMAppService`） | ❌ 未做 |

資料累積起點：2026-08-28 22:32:40，目前 724 筆樣本。
測試：28 個，`cd Packages/AIUsageKit && swift test`。
Migration：001–005 已套用。

## 已知限制（設計上接受的）

- **app 必須開著才有資料。** 尚未接開機自啟，關掉或重開機後需手動開啟。
- **取樣間隔不保證。** `NSBackgroundActivityScheduler` 有 tolerance。
- **Codex 解析度 1%**（整數百分比），小時層級偏粗。
- **delta 加總是近似值**（`regress` 夾擠為 0 會微幅高估）。
  精確值讀 `v_window_summary.used_percent`。
- **本地時區分桶由讀取端 TZ 決定。**
- **端點皆未公開**，可能無預警變更。

## 觀察中

- **背景取樣完成後圖表是否自動更新** —— 理論上 `@Observable` 會處理，
  但曾有使用者回報需手動重新整理。已加重新整理鈕與焦點自動重讀作為保險，
  但根因尚未確認（可能只是取樣間隔太長造成的錯覺）。
- **OpenAI 的外部提前重置** —— 2026-08 曾多次對全體付費用戶重置。
  `v_window_summary.ended_early` 會標記，但目前資料尚未涵蓋任何一次。
- **Codex 5 小時窗回歸後的行為**（2026-08-25 對 Plus 恢復）。
