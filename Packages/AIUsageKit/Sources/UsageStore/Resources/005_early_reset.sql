-- 標記「提前重置」。
--
-- OpenAI 在 2026-08-07~13 間多次對全體付費用戶重置 Codex 額度
-- （由 Codex 工程主管在 X 宣布，慶祝突破 1500 萬活躍用戶）。
-- 這類外部重置在資料上與正常窗到期完全相同：百分比歸零、resets_at 換值。
--
-- 但兩者對分析的意義不同：被提前重置切斷的「週」會比正常的短，
-- 若不標記，事後會分不清「那週我沒用」與「額度被提前清掉」。
--
-- 判準：下一個窗在本窗排定的 resets_at 之前就開始 => 提前重置。
-- 容差 1 小時，避免取樣間隔造成誤判。
DROP VIEW IF EXISTS v_window_summary;

CREATE VIEW v_window_summary AS
WITH grouped AS (
  SELECT
    q.service, q.window_kind, q.window_seq,
    MAX(q.window_started) AS window_started,
    MAX(q.resets_at)      AS resets_at,
    MIN(q.observed_at)    AS first_seen_at,
    MAX(q.observed_at)    AS last_seen_at,
    MAX(q.percent)        AS peak_percent,
    COUNT(*)              AS sample_count
  FROM v_window_seq q
  GROUP BY q.service, q.window_kind, q.window_seq
),
sequenced AS (
  SELECT g.*,
         LEAD(g.first_seen_at) OVER (
           PARTITION BY g.service, g.window_kind ORDER BY g.window_seq
         ) AS next_window_started_at
  FROM grouped g
)
SELECT
  s.service, s.window_kind, s.window_seq, s.window_started,
  s.resets_at, s.first_seen_at, s.last_seen_at, s.peak_percent, s.sample_count,
  (SELECT x.percent FROM v_window_seq x
    WHERE x.service = s.service AND x.window_kind = s.window_kind AND x.window_seq = s.window_seq
    ORDER BY x.observed_at DESC, x.id DESC LIMIT 1) AS used_percent,
  s.last_seen_at - s.first_seen_at AS observed_duration_seconds,
  CASE WHEN s.window_started = 0 THEN NULL
       ELSE s.resets_at - s.last_seen_at END AS tail_unobserved_seconds,
  CASE
    WHEN s.window_started = 0                THEN NULL   -- 未開始的窗無所謂提前
    WHEN s.next_window_started_at IS NULL    THEN NULL   -- 仍在進行中
    WHEN s.next_window_started_at < s.resets_at - 3600 THEN 1
    ELSE 0
  END AS ended_early
FROM sequenced s;
