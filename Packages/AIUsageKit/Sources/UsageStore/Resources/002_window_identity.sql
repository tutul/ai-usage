-- 窗身分改用容差比對。
--
-- 實測發現 Anthropic 回傳的 resets_at 在秒級會來回抖動一秒
-- （同一個週窗交替出現 1788310799 與 1788310800），原值帶 6 位小數且本身有微秒級漂移。
-- 原本以 resets_at 做精確比對判定換窗，導致每抖一次就被判成一次重置；
-- 而重置的 delta 規則是「等於當前百分比」，於是 49 次假重置累積出 2641% 的假 delta。
--
-- 真正換窗會讓 resets_at 移動約 7 天，抖動只有 1 秒以內 —— 兩者相差 5 個數量級，
-- 容差比對可以乾淨地分開，且不需要更動任何原始樣本。
INSERT OR REPLACE INTO setting(key, value) VALUES ('reset_tolerance_seconds', '120');

DROP VIEW IF EXISTS v_unknown_span;
DROP VIEW IF EXISTS v_daily;
DROP VIEW IF EXISTS v_hourly;
DROP VIEW IF EXISTS v_window_summary;
DROP VIEW IF EXISTS v_sample_delta;

-- 為每筆樣本標上「第幾個窗」。只有 resets_at 移動超過容差才會遞增。
CREATE VIEW v_window_seq AS
WITH tol AS (SELECT CAST(value AS INTEGER) AS t FROM setting WHERE key = 'reset_tolerance_seconds'),
flagged AS (
  SELECT
    s.id, s.service, s.window_kind, s.observed_at, s.percent, s.resets_at, s.window_seconds,
    CASE
      WHEN LAG(s.id) OVER w IS NULL                                   THEN 0
      WHEN (s.resets_at IS NULL) <> (LAG(s.resets_at) OVER w IS NULL) THEN 1
      WHEN s.resets_at IS NULL                                        THEN 0
      WHEN ABS(s.resets_at - LAG(s.resets_at) OVER w) > c.t           THEN 1
      ELSE 0
    END AS is_new_window
  FROM sample s CROSS JOIN tol c
  WINDOW w AS (PARTITION BY s.service, s.window_kind ORDER BY s.observed_at, s.id)
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
    q.id, q.service, q.window_kind, q.observed_at, q.percent, q.resets_at, q.window_seq,
    LAG(q.observed_at) OVER w AS prev_observed_at,
    LAG(q.percent)     OVER w AS prev_percent,
    LAG(q.resets_at)   OVER w AS prev_resets_at,
    LAG(q.window_seq)  OVER w AS prev_window_seq
  FROM v_window_seq q
  WINDOW w AS (PARTITION BY q.service, q.window_kind ORDER BY q.observed_at, q.id)
)
SELECT
  p.service, p.window_kind, p.id AS sample_id,
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

-- 以 window_seq 分組，不再以抖動的 resets_at 分組
CREATE VIEW v_window_summary AS
SELECT
  q.service, q.window_kind, q.window_seq,
  MAX(q.resets_at)   AS resets_at,
  MIN(q.observed_at) AS first_seen_at,
  MAX(q.observed_at) AS last_seen_at,
  (SELECT x.percent FROM v_window_seq x
    WHERE x.service = q.service AND x.window_kind = q.window_kind AND x.window_seq = q.window_seq
    ORDER BY x.observed_at DESC, x.id DESC LIMIT 1) AS used_percent,
  MAX(q.percent) AS peak_percent,
  COUNT(*)       AS sample_count,
  MAX(q.resets_at) - MAX(q.observed_at) AS tail_unobserved_seconds
FROM v_window_seq q
GROUP BY q.service, q.window_kind, q.window_seq;
