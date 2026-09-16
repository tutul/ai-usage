-- 修正 004 的一個混用：它把「沒有 resets_at」和「窗還沒開始」當成同一件事。
--
-- 實測 2026-09-16 08:59:59（正好是週窗重置的那一秒），端點回的是
--   "seven_day": { "utilization": 38.0, "resets_at": null }
-- 百分比還是舊窗的 38，但身分欄位是 null。004 的規則「effective_resets_at 的
-- NULL 性改變 = 一次窗界線」把它判成重置，於是 delta 直接給當下的百分比 ——
-- **那一天憑空多出 38%**（實測 v_daily 顯示 45%，真實用量約 7%）。
-- session 窗更常遇到（09-08 一天被灌 68%）。
--
-- 兩者必須分開：
--   resets_at 是佔位值（≈ observed_at + window_seconds） -> 窗未開始，**是**真的界線
--   resets_at 是 NULL                                    -> 身分未知，**不是**界線
--
-- 身分未知時沿用前一筆的窗。若那一刻其實真的換了窗，百分比會下降，
-- 落入 regress 夾擠為 0 —— 少算，不會多算。**寧可低估，不可憑空生出用量。**
--
-- 做法：窗界線只由「身分可判定」的樣本決定，身分未知的樣本沿用前一個窗編號。
-- 用 running MAX 取代「上一筆非未知」的查找 —— window_seq 單調不減，
-- 所以 MAX 就是最近一筆的值，不必寫相關子查詢（10k 列會變 O(n²)）。

DROP VIEW IF EXISTS v_window_seq;

CREATE VIEW v_window_seq AS
WITH tol AS (SELECT CAST(value AS INTEGER) AS t FROM setting WHERE key = 'reset_tolerance_seconds'),
marked AS (
  SELECT
    s.id, s.service, s.window_kind, s.observed_at, s.percent, s.resets_at, s.window_seconds,
    CASE WHEN s.resets_at IS NOT NULL AND s.window_seconds IS NOT NULL
              AND (s.resets_at - s.observed_at) < s.window_seconds - c.t
         THEN 1 ELSE 0 END AS window_started,
    -- 未開始的窗，resets_at 是佔位值，視為無身分
    CASE WHEN s.resets_at IS NOT NULL AND s.window_seconds IS NOT NULL
              AND (s.resets_at - s.observed_at) < s.window_seconds - c.t
         THEN s.resets_at END AS effective_resets_at,
    CASE WHEN s.resets_at IS NULL THEN 1 ELSE 0 END AS identity_unknown
  FROM sample s CROSS JOIN tol c
),
-- 只有身分可判定的樣本參與界線判定
known AS (
  SELECT m.*,
    CASE
      WHEN LAG(m.id) OVER w IS NULL THEN 0
      -- 未開始 <-> 已開始 的轉換就是一次真正的窗界線
      WHEN (m.effective_resets_at IS NULL) <> (LAG(m.effective_resets_at) OVER w IS NULL) THEN 1
      WHEN m.effective_resets_at IS NULL THEN 0
      WHEN ABS(m.effective_resets_at - LAG(m.effective_resets_at) OVER w)
           > (SELECT t FROM tol) THEN 1
      ELSE 0
    END AS is_new_window
  FROM marked m
  WHERE m.identity_unknown = 0
  WINDOW w AS (PARTITION BY m.service, m.window_kind ORDER BY m.observed_at, m.id)
),
numbered AS (
  SELECT k.id, k.service, k.window_kind, k.observed_at,
         SUM(k.is_new_window) OVER (
           PARTITION BY k.service, k.window_kind ORDER BY k.observed_at, k.id
         ) AS window_seq
  FROM known k
)
SELECT
  m.id, m.service, m.window_kind, m.observed_at, m.percent, m.resets_at, m.window_seconds,
  m.window_started, m.effective_resets_at, m.identity_unknown,
  COALESCE(
    MAX(n.window_seq) OVER (
      PARTITION BY m.service, m.window_kind ORDER BY m.observed_at, m.id ROWS UNBOUNDED PRECEDING
    ), 0
  ) AS window_seq
FROM marked m
LEFT JOIN numbered n ON n.id = m.id;
