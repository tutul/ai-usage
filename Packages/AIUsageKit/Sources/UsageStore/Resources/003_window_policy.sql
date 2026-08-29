-- 兩家 provider 的窗語意根本不同，必須分別處理。實測（180 筆樣本）：
--
--   codex  weekly   resets_at - observed_at 恆為 604800（= window_seconds）
--   codex  session  resets_at - observed_at 恆為 18000
--   claude weekly   remain 由 382400 遞減至 332007，resets_at 固定在某一時刻
--
-- 即 Codex 回報的是**滾動窗**：reset_at 永遠是「現在 + 窗長」，不帶任何窗身分資訊。
-- 拿它當身分會導致每次取樣都被判成換窗。Claude 才是固定邊界窗。
--
-- 滾動窗沒有「重置」這個離散事件：用量增加代表新消耗，減少代表舊消耗滑出窗外。
-- 因此 delta 規則簡化為 max(0, percent - prev_percent)，永不產生 reset。
--
-- policy 寫成資料而非推測 —— 用「remain ≈ window_seconds」判斷會在
-- 固定窗剛重置後的短時間內誤判為滾動。
CREATE TABLE window_policy (
  service     TEXT NOT NULL,
  window_kind TEXT NOT NULL,
  policy      TEXT NOT NULL CHECK (policy IN ('fixed_reset', 'rolling')),
  note        TEXT,
  PRIMARY KEY (service, window_kind)
);
INSERT INTO window_policy(service, window_kind, policy, note) VALUES
  ('claude', 'weekly',  'fixed_reset', 'resets_at 為固定時刻，秒級有 ±1s 抖動，以容差比對'),
  ('claude', 'session', 'fixed_reset', '同上'),
  ('codex',  'weekly',  'rolling',     'resets_at 恆為 observed_at + 604800，不帶身分資訊'),
  ('codex',  'session', 'rolling',     'resets_at 恆為 observed_at + 18000，不帶身分資訊');

DROP VIEW IF EXISTS v_current;
DROP VIEW IF EXISTS v_unknown_span;
DROP VIEW IF EXISTS v_daily;
DROP VIEW IF EXISTS v_hourly;
DROP VIEW IF EXISTS v_window_summary;
DROP VIEW IF EXISTS v_sample_delta;
DROP VIEW IF EXISTS v_window_seq;

CREATE VIEW v_window_seq AS
WITH tol AS (SELECT CAST(value AS INTEGER) AS t FROM setting WHERE key = 'reset_tolerance_seconds'),
flagged AS (
  SELECT
    s.id, s.service, s.window_kind, s.observed_at, s.percent, s.resets_at, s.window_seconds,
    COALESCE(p.policy, 'fixed_reset') AS policy,
    CASE
      -- 滾動窗永不換窗
      WHEN COALESCE(p.policy, 'fixed_reset') = 'rolling'              THEN 0
      WHEN LAG(s.id) OVER w IS NULL                                   THEN 0
      WHEN (s.resets_at IS NULL) <> (LAG(s.resets_at) OVER w IS NULL) THEN 1
      WHEN s.resets_at IS NULL                                        THEN 0
      WHEN ABS(s.resets_at - LAG(s.resets_at) OVER w) > c.t           THEN 1
      ELSE 0
    END AS is_new_window
  FROM sample s
  CROSS JOIN tol c
  LEFT JOIN window_policy p ON p.service = s.service AND p.window_kind = s.window_kind
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
    q.id, q.service, q.window_kind, q.observed_at, q.percent, q.resets_at, q.window_seq, q.policy,
    LAG(q.observed_at) OVER w AS prev_observed_at,
    LAG(q.percent)     OVER w AS prev_percent,
    LAG(q.resets_at)   OVER w AS prev_resets_at,
    LAG(q.window_seq)  OVER w AS prev_window_seq
  FROM v_window_seq q
  WINDOW w AS (PARTITION BY q.service, q.window_kind ORDER BY q.observed_at, q.id)
)
SELECT
  p.service, p.window_kind, p.policy, p.id AS sample_id,
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
    -- 滾動窗的下降是舊消耗滑出窗外，屬正常；固定窗的下降才是伺服器下修
    WHEN p.percent < p.prev_percent AND p.policy = 'rolling' THEN 'decay'
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
  q.service, q.window_kind, q.policy, q.window_seq,
  MAX(q.resets_at)   AS resets_at,
  MIN(q.observed_at) AS first_seen_at,
  MAX(q.observed_at) AS last_seen_at,
  (SELECT x.percent FROM v_window_seq x
    WHERE x.service = q.service AND x.window_kind = q.window_kind AND x.window_seq = q.window_seq
    ORDER BY x.observed_at DESC, x.id DESC LIMIT 1) AS used_percent,
  MAX(q.percent) AS peak_percent,
  COUNT(*)       AS sample_count,
  CASE WHEN q.policy = 'rolling' THEN NULL
       ELSE MAX(q.resets_at) - MAX(q.observed_at) END AS tail_unobserved_seconds
FROM v_window_seq q
GROUP BY q.service, q.window_kind, q.window_seq;

-- v_current 帶上 policy，讓 UI 知道該不該顯示重置倒數。
-- 滾動窗的 resets_at 恆為「現在 + 窗長」，倒數永遠不會減少，顯示出來是誤導。
CREATE VIEW v_current AS
SELECT s.service, s.window_kind, s.observed_at, s.percent, s.resets_at,
       COALESCE(p.policy, 'fixed_reset') AS policy
FROM sample s
JOIN (SELECT service, window_kind, MAX(observed_at) AS m
        FROM sample GROUP BY service, window_kind) t
  ON s.service = t.service AND s.window_kind = t.window_kind AND s.observed_at = t.m
LEFT JOIN window_policy p ON p.service = s.service AND p.window_kind = s.window_kind;
