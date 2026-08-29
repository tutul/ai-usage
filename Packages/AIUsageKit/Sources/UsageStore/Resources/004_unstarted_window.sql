-- 修正 003 的錯誤模型。
--
-- 003 把 Codex 標成「滾動窗」，依據是 180 筆樣本中 resets_at - observed_at 恆為
-- window_seconds。但那 180 筆的 percent **全部都是 0.0** —— 等於在「毫無用量」的
-- 資料上推論窗的行為，是被混淆變項誤導。
--
-- 對照組就在同一份資料裡：Codex 有 2% 用量時，reset_after_seconds 是 138763
-- （約 1.6 天），不是 604800。官方文件與客服說法一致：
--   「weekly window starts at the first message you send」
--   「each account's window anchors to its own first request after the previous reset」
--
-- 正確模型：兩家都是**固定時長、以首次使用為錨點**的窗。窗尚未開始時，
-- 伺服器回報 resets_at = now + window_seconds 作為佔位值，該值隨每次取樣前移，
-- 不帶任何身分資訊。
--
-- 由此得到一條**對兩家都成立**的統一規則，不需要 per-provider 政策：
--   resets_at - observed_at ≈ window_seconds  =>  窗未開始，resets_at 無效
DROP TABLE IF EXISTS window_policy;

DROP VIEW IF EXISTS v_current;
DROP VIEW IF EXISTS v_unknown_span;
DROP VIEW IF EXISTS v_daily;
DROP VIEW IF EXISTS v_hourly;
DROP VIEW IF EXISTS v_window_summary;
DROP VIEW IF EXISTS v_sample_delta;
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
         THEN s.resets_at END AS effective_resets_at
  FROM sample s CROSS JOIN tol c
),
flagged AS (
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
  WINDOW w AS (PARTITION BY m.service, m.window_kind ORDER BY m.observed_at, m.id)
)
SELECT f.*,
       SUM(f.is_new_window) OVER (
         PARTITION BY f.service, f.window_kind ORDER BY f.observed_at, f.id
       ) AS window_seq
FROM flagged f;

CREATE VIEW v_sample_delta AS
WITH cfg AS (SELECT CAST(value AS INTEGER) AS max_gap FROM setting WHERE key = 'delta_max_gap_seconds'),
paired AS (
  SELECT
    q.id, q.service, q.window_kind, q.observed_at, q.percent, q.resets_at,
    q.window_seq, q.window_started,
    LAG(q.observed_at) OVER w AS prev_observed_at,
    LAG(q.percent)     OVER w AS prev_percent,
    LAG(q.resets_at)   OVER w AS prev_resets_at,
    LAG(q.window_seq)  OVER w AS prev_window_seq
  FROM v_window_seq q
  WINDOW w AS (PARTITION BY q.service, q.window_kind ORDER BY q.observed_at, q.id)
)
SELECT
  p.service, p.window_kind, p.id AS sample_id, p.window_started,
  p.prev_observed_at, p.observed_at,
  p.prev_percent, p.percent,
  p.prev_resets_at, p.resets_at, p.window_seq,
  p.observed_at - p.prev_observed_at AS gap_seconds,
  CASE
    WHEN p.prev_observed_at IS NULL                     THEN 'first'
    WHEN p.window_seq <> p.prev_window_seq
         AND p.observed_at - p.prev_observed_at > c.max_gap THEN 'reset_in_gap'
    WHEN p.window_seq <> p.prev_window_seq              THEN 'reset'
    WHEN p.observed_at - p.prev_observed_at > c.max_gap THEN 'gap'
    WHEN p.percent < p.prev_percent                     THEN 'regress'
    ELSE 'ok'
  END AS kind,
  CASE
    WHEN p.prev_observed_at IS NULL                     THEN NULL
    WHEN p.window_seq <> p.prev_window_seq
         AND p.observed_at - p.prev_observed_at > c.max_gap THEN NULL
    WHEN p.window_seq <> p.prev_window_seq              THEN p.percent
    WHEN p.percent < p.prev_percent                     THEN 0.0
    ELSE p.percent - p.prev_percent
  END AS delta_percent,
  strftime('%Y-%m-%dT%H', p.prev_observed_at, 'unixepoch', 'localtime') AS prev_hour_local,
  strftime('%Y-%m-%d',    p.prev_observed_at, 'unixepoch', 'localtime') AS prev_day_local,
  strftime('%Y-%m-%dT%H', p.observed_at, 'unixepoch', 'localtime')      AS hour_local,
  strftime('%Y-%m-%d',    p.observed_at, 'unixepoch', 'localtime')      AS day_local,
  CAST(strftime('%s', strftime('%Y-%m-%d %H:00:00', p.observed_at, 'unixepoch', 'localtime'), 'utc') AS INTEGER) AS hour_start_epoch
FROM paired p CROSS JOIN cfg c;

CREATE VIEW v_hourly AS
SELECT
  d.service, d.window_kind, d.hour_local, d.hour_start_epoch,
  ROUND(SUM(CASE WHEN d.prev_hour_local = d.hour_local OR d.gap_seconds <= c.max_gap
                 THEN d.delta_percent END), 3) AS used_percent,
  ROUND(SUM(CASE WHEN d.prev_hour_local <> d.hour_local AND d.gap_seconds > c.max_gap
                 THEN d.delta_percent END), 3) AS unknown_percent,
  COUNT(*) AS pair_count,
  SUM(d.prev_hour_local <> d.hour_local AND d.gap_seconds > c.max_gap) AS unattributed_pairs
FROM v_sample_delta d
CROSS JOIN (SELECT CAST(value AS INTEGER) AS max_gap FROM setting WHERE key = 'delta_max_gap_seconds') c
WHERE d.kind <> 'first'
GROUP BY d.service, d.window_kind, d.hour_local;

CREATE VIEW v_daily AS
SELECT
  d.service, d.window_kind, d.day_local,
  ROUND(SUM(CASE WHEN d.prev_day_local = d.day_local THEN d.delta_percent END), 3) AS used_percent,
  ROUND(SUM(CASE WHEN d.prev_day_local <> d.day_local THEN d.delta_percent END), 3) AS unknown_percent,
  COUNT(*) AS pair_count
FROM v_sample_delta d
WHERE d.kind <> 'first'
GROUP BY d.service, d.window_kind, d.day_local;

CREATE VIEW v_unknown_span AS
SELECT d.service, d.window_kind,
       d.prev_observed_at AS from_at, d.observed_at AS to_at, d.gap_seconds,
       d.prev_percent, d.percent, d.kind,
       CASE WHEN d.kind = 'reset_in_gap' THEN NULL ELSE d.percent - d.prev_percent END AS known_total_percent
FROM v_sample_delta d
CROSS JOIN (SELECT CAST(value AS INTEGER) AS max_gap FROM setting WHERE key = 'delta_max_gap_seconds') c
WHERE d.prev_hour_local <> d.hour_local AND d.gap_seconds > c.max_gap;

CREATE VIEW v_window_summary AS
SELECT
  q.service, q.window_kind, q.window_seq, q.window_started,
  MAX(q.resets_at)   AS resets_at,
  MIN(q.observed_at) AS first_seen_at,
  MAX(q.observed_at) AS last_seen_at,
  (SELECT x.percent FROM v_window_seq x
    WHERE x.service = q.service AND x.window_kind = q.window_kind AND x.window_seq = q.window_seq
    ORDER BY x.observed_at DESC, x.id DESC LIMIT 1) AS used_percent,
  MAX(q.percent) AS peak_percent,
  COUNT(*)       AS sample_count,
  CASE WHEN q.window_started = 0 THEN NULL
       ELSE MAX(q.resets_at) - MAX(q.observed_at) END AS tail_unobserved_seconds
FROM v_window_seq q
GROUP BY q.service, q.window_kind, q.window_seq;

-- window_started 決定 UI 該不該顯示重置倒數：
-- 窗未開始時 resets_at 是佔位值，倒數永遠不會減少，顯示出來是誤導。
CREATE VIEW v_current AS
SELECT q.service, q.window_kind, q.observed_at, q.percent, q.resets_at,
       q.window_started, q.window_seconds
FROM v_window_seq q
JOIN (SELECT service, window_kind, MAX(observed_at) AS m
        FROM sample GROUP BY service, window_kind) t
  ON q.service = t.service AND q.window_kind = t.window_kind AND q.observed_at = t.m;
