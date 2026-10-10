-- 開圖表變慢。實測 2026-10-10（22,268 筆樣本、12,998 次抓取），一次重讀約 4.2 秒，
-- 其中 3 秒花在取樣日誌這一個查詢上。
--
-- 1. 日誌的每一列要查「那次抓取的週用量」：
--      SELECT s.percent FROM sample s WHERE s.fetch_id = f.id AND s.window_kind = 'weekly'
--    sample 沒有 fetch_id 的索引，所以每一列都掃整張 sample；排序又用不到既有索引，
--    於是「取最近 51 筆」實際上對全部抓取都做了一次 —— 成本是 抓取數 × 樣本數，
--    隨資料量**平方成長**。這就是「開始變慢」的原因。
CREATE INDEX idx_sample_fetch ON sample(fetch_id);
CREATE INDEX idx_fetch_time   ON fetch(completed_at, id);

-- 2. 012 把重置原因做成另一個 view，圖表再把它 JOIN 回 v_window_summary ——
--    整個窗推導因此多算一遍（實測每個服務 203 ms -> 320 ms）。
--    把原因併進 v_window_summary 一次算完；v_window_reset_cause 留著當篩選，語意不變。
--    判準與 012 完全相同，見 D-021。
--
-- 3. used_percent（窗的最後觀測值）原本是每個窗一個相關子查詢，每次都把 v_window_seq
--    重算一遍（實測佔這個 view 210 ms 裡的 125 ms）。改成在同一趟裡標出每個窗的最後一筆。
--    數值不變 —— 已在真實資料上逐列比對。
DROP VIEW v_window_reset_cause;
DROP VIEW v_window_summary;

CREATE VIEW v_window_summary AS
WITH cfg AS (
  SELECT CAST(value AS INTEGER) AS span FROM setting WHERE key = 'reset_cause_window_seconds'
),
ranked AS (
  SELECT q.*,
         ROW_NUMBER() OVER (
           PARTITION BY q.service, q.window_kind, q.window_seq
           ORDER BY q.observed_at DESC, q.id DESC
         ) AS recency
  FROM v_window_seq q
),
grouped AS (
  SELECT
    q.service, q.window_kind, q.window_seq,
    MAX(q.window_started) AS window_started,
    MAX(q.resets_at)      AS resets_at,
    MIN(q.observed_at)    AS first_seen_at,
    MAX(q.observed_at)    AS last_seen_at,
    MAX(q.percent)        AS peak_percent,
    COUNT(*)              AS sample_count,
    MAX(CASE WHEN q.recency = 1 THEN q.percent END) AS used_percent
  FROM ranked q
  GROUP BY q.service, q.window_kind, q.window_seq
),
sequenced AS (
  SELECT g.*,
         LEAD(g.first_seen_at) OVER (
           PARTITION BY g.service, g.window_kind ORDER BY g.window_seq
         ) AS next_window_started_at
  FROM grouped g
),
flagged AS (
  SELECT
    s.service, s.window_kind, s.window_seq, s.window_started,
    s.resets_at, s.first_seen_at, s.last_seen_at, s.peak_percent, s.sample_count,
    s.used_percent,
    s.last_seen_at - s.first_seen_at AS observed_duration_seconds,
    CASE WHEN s.window_started = 0 THEN NULL
         ELSE s.resets_at - s.last_seen_at END AS tail_unobserved_seconds,
    CASE
      WHEN s.window_started = 0                THEN NULL   -- 未開始的窗無所謂提前
      WHEN s.next_window_started_at IS NULL    THEN NULL   -- 仍在進行中
      WHEN s.next_window_started_at < s.resets_at - 3600 THEN 1
      ELSE 0
    END AS ended_early
  FROM sequenced s
),
observed AS (
  SELECT f.*,
    -- 只有被提前重置的窗才去查額度數，其餘不付這個成本
    CASE WHEN f.ended_early = 1 THEN
      (SELECT c.available_count FROM reset_credit c
        WHERE c.service = f.service
          AND c.observed_at <= f.last_seen_at
          AND c.observed_at >= f.last_seen_at - cfg.span
        ORDER BY c.observed_at DESC, c.fetch_id DESC LIMIT 1)
    END AS credits_before,
    CASE WHEN f.ended_early = 1 THEN
      (SELECT MIN(c.available_count) FROM reset_credit c
        WHERE c.service = f.service
          AND c.observed_at > f.last_seen_at
          AND c.observed_at <= f.last_seen_at + cfg.span)
    END AS credits_after
  FROM flagged f CROSS JOIN cfg
)
SELECT
  o.service, o.window_kind, o.window_seq, o.window_started,
  o.resets_at, o.first_seen_at, o.last_seen_at, o.peak_percent, o.sample_count,
  o.used_percent, o.observed_duration_seconds, o.tail_unobserved_seconds, o.ended_early,
  o.credits_before, o.credits_after,
  CASE
    WHEN o.credits_before IS NULL OR o.credits_after IS NULL THEN NULL
    WHEN o.credits_after < o.credits_before                  THEN 'redeemed'
    ELSE 'external'
  END AS reset_cause
FROM observed o;

CREATE VIEW v_window_reset_cause AS
SELECT service, window_kind, window_seq, last_seen_at,
       credits_before, credits_after, reset_cause
  FROM v_window_summary
 WHERE ended_early = 1;
