PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
INSERT INTO meta(key,value) VALUES ('schema_version','1');

CREATE TABLE setting (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
-- 相鄰樣本間隔超過此秒數，該段 delta 視為不可歸屬（unknown）
INSERT INTO setting(key,value) VALUES ('delta_max_gap_seconds','900');

-- 每一次 HTTP 取樣嘗試（成功或失敗）
CREATE TABLE fetch (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  service       TEXT    NOT NULL,              -- 'claude' | 'codex'
  started_at    INTEGER NOT NULL,              -- unix epoch (UTC)
  completed_at  INTEGER NOT NULL,              -- 樣本時間戳的唯一來源
  ok            INTEGER NOT NULL CHECK (ok IN (0,1)),
  http_status   INTEGER,
  error_kind    TEXT,                          -- 'auth'(401)|'blocked'(403 UA/風控)|'network'|'http'|'parse'|'missing_window'
  error_detail  TEXT,
  raw_id        INTEGER REFERENCES raw_payload(id)
);
CREATE INDEX idx_fetch_service_time ON fetch(service, completed_at);

-- 每次取樣觀測到的每一個限額窗（Claude 一次回兩個窗）
CREATE TABLE sample (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  fetch_id       INTEGER NOT NULL REFERENCES fetch(id),
  service        TEXT    NOT NULL,             -- 反正規化：外部查詢與索引用
  window_kind    TEXT    NOT NULL,             -- 'weekly'|'session'|'other'；由 limit_window_seconds 判定，非欄位位置
  observed_at    INTEGER NOT NULL,             -- = fetch.completed_at
  percent        REAL    NOT NULL,             -- 0..100
  resets_at      INTEGER,                      -- 窗的身分識別
  window_seconds INTEGER
);
CREATE INDEX idx_sample_series ON sample(service, window_kind, observed_at);
CREATE INDEX idx_sample_window ON sample(service, window_kind, resets_at);

-- 原始回應：僅在「解析值變化」或「結構變化」時寫入
CREATE TABLE raw_payload (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  service      TEXT    NOT NULL,
  captured_at  INTEGER NOT NULL,
  body         TEXT    NOT NULL,
  shape_sha256 TEXT    NOT NULL,               -- 排序後 JSON key path 的雜湊
  reason       TEXT    NOT NULL                -- 'first'|'value_change'|'shape_change'|'error'
);
CREATE INDEX idx_raw_service_time ON raw_payload(service, captured_at);
-- 相鄰樣本配對，計算 delta 並分類
CREATE VIEW v_sample_delta AS
WITH cfg AS (
  SELECT CAST(value AS INTEGER) AS max_gap FROM setting WHERE key='delta_max_gap_seconds'
),
paired AS (
  SELECT
    s.id, s.service, s.window_kind, s.observed_at, s.percent, s.resets_at,
    LAG(s.observed_at) OVER w AS prev_observed_at,
    LAG(s.percent)     OVER w AS prev_percent,
    LAG(s.resets_at)   OVER w AS prev_resets_at
  FROM sample s
  WINDOW w AS (PARTITION BY s.service, s.window_kind ORDER BY s.observed_at)
)
SELECT
  p.service, p.window_kind, p.id AS sample_id,
  p.prev_observed_at, p.observed_at,
  p.prev_percent, p.percent,
  p.prev_resets_at, p.resets_at,
  p.observed_at - p.prev_observed_at AS gap_seconds,
  CASE
    WHEN p.prev_observed_at IS NULL                     THEN 'first'
    WHEN p.resets_at IS NOT p.prev_resets_at
         AND p.observed_at - p.prev_observed_at > c.max_gap THEN 'reset_in_gap'
    WHEN p.resets_at IS NOT p.prev_resets_at            THEN 'reset'
    WHEN p.observed_at - p.prev_observed_at > c.max_gap  THEN 'gap'
    WHEN p.percent < p.prev_percent                     THEN 'regress'
    ELSE 'ok'
  END AS kind,
  CASE
    WHEN p.prev_observed_at IS NULL                     THEN NULL
    WHEN p.resets_at IS NOT p.prev_resets_at
         AND p.observed_at - p.prev_observed_at > c.max_gap THEN NULL
    WHEN p.resets_at IS NOT p.prev_resets_at            THEN p.percent
    WHEN p.percent < p.prev_percent                     THEN 0.0
    ELSE p.percent - p.prev_percent
  END AS delta_percent,
  strftime('%Y-%m-%dT%H', p.prev_observed_at,'unixepoch','localtime') AS prev_hour_local,
  strftime('%Y-%m-%d',    p.prev_observed_at,'unixepoch','localtime') AS prev_day_local,
  strftime('%Y-%m-%dT%H', p.observed_at,'unixepoch','localtime') AS hour_local,
  strftime('%Y-%m-%d',    p.observed_at,'unixepoch','localtime') AS day_local,
  CAST(strftime('%s', strftime('%Y-%m-%d %H:00:00', p.observed_at,'unixepoch','localtime'),'utc') AS INTEGER) AS hour_start_epoch
FROM paired p CROSS JOIN cfg c;

-- 小時桶：歸屬於「後一個樣本所在的小時」；跨長 gap 者不歸屬，改計入 unknown
CREATE VIEW v_hourly AS
SELECT
  d.service, d.window_kind, d.hour_local, d.hour_start_epoch,
  ROUND(SUM(CASE WHEN d.prev_hour_local = d.hour_local OR d.gap_seconds <= c.max_gap
                 THEN d.delta_percent END),3) AS used_percent,
  ROUND(SUM(CASE WHEN d.prev_hour_local <> d.hour_local AND d.gap_seconds > c.max_gap
                 THEN d.delta_percent END),3) AS unknown_percent,
  COUNT(*)                                        AS pair_count,
  SUM(d.prev_hour_local <> d.hour_local AND d.gap_seconds > c.max_gap) AS unattributed_pairs
FROM v_sample_delta d
CROSS JOIN (SELECT CAST(value AS INTEGER) AS max_gap FROM setting WHERE key='delta_max_gap_seconds') c
WHERE d.kind <> 'first'
GROUP BY d.service, d.window_kind, d.hour_local;

-- 日桶：門檻放寬為 1 小時（跨小時的 delta 在日層級仍可信）
CREATE VIEW v_daily AS
SELECT
  d.service, d.window_kind, d.day_local,
  ROUND(SUM(CASE WHEN d.prev_day_local = d.day_local THEN d.delta_percent END),3) AS used_percent,
  ROUND(SUM(CASE WHEN d.prev_day_local <> d.day_local THEN d.delta_percent END),3) AS unknown_percent,
  COUNT(*) AS pair_count
FROM v_sample_delta d
WHERE d.kind <> 'first'
GROUP BY d.service, d.window_kind, d.day_local;

-- 不可歸屬區間：供圖表畫斜線帶
CREATE VIEW v_unknown_span AS
SELECT d.service, d.window_kind,
       prev_observed_at AS from_at, observed_at AS to_at, gap_seconds,
       prev_percent, percent, kind,
       CASE WHEN kind='reset_in_gap' THEN NULL ELSE percent - prev_percent END AS known_total_percent
FROM v_sample_delta d
CROSS JOIN (SELECT CAST(value AS INTEGER) AS max_gap FROM setting WHERE key='delta_max_gap_seconds') c
WHERE d.prev_hour_local <> d.hour_local AND d.gap_seconds > c.max_gap;

-- 每個限額窗的總結：max_percent 就是該窗實際用量，不需 delta
CREATE VIEW v_window_summary AS
SELECT s.service, s.window_kind, s.resets_at,
       MIN(s.observed_at) AS first_seen_at,
       MAX(s.observed_at) AS last_seen_at,
       -- 權威值：該窗最後一次觀測到的百分比（不受 regress 夾擠影響）
       (SELECT x.percent FROM sample x
         WHERE x.service=s.service AND x.window_kind=s.window_kind AND x.resets_at=s.resets_at
         ORDER BY x.observed_at DESC LIMIT 1) AS used_percent,
       MAX(s.percent)   AS peak_percent,
       COUNT(*)         AS sample_count,
       s.resets_at - MAX(s.observed_at) AS tail_unobserved_seconds
FROM sample s
WHERE s.resets_at IS NOT NULL
GROUP BY s.service, s.window_kind, s.resets_at;

-- menu bar 用：每個服務／窗別的最新讀數
CREATE VIEW v_current AS
SELECT s.service, s.window_kind, s.observed_at, s.percent, s.resets_at
FROM sample s
JOIN (SELECT service, window_kind, MAX(observed_at) AS m
      FROM sample GROUP BY service, window_kind) t
  ON s.service=t.service AND s.window_kind=t.window_kind AND s.observed_at=t.m;

-- 健康度：抓不到要看得出來
CREATE VIEW v_health AS
SELECT service,
       MAX(CASE WHEN ok=1 THEN completed_at END) AS last_success_at,
       MAX(completed_at)                         AS last_attempt_at,
       SUM(ok=0)                                 AS failures_total
FROM fetch GROUP BY service;
