-- v_daily 補上 day_start_epoch，與 v_hourly 的 hour_start_epoch 對齊。
-- 圖表需要 Date 型別的 X 軸；由 SQL 提供而非在 Swift 端解析字串，
-- 維持「時間分桶的定義只有一處」。
DROP VIEW IF EXISTS v_daily;

CREATE VIEW v_daily AS
SELECT
  d.service, d.window_kind, d.day_local,
  CAST(strftime('%s', d.day_local || ' 00:00:00', 'utc') AS INTEGER) AS day_start_epoch,
  ROUND(SUM(CASE WHEN d.prev_day_local = d.day_local THEN d.delta_percent END), 3) AS used_percent,
  ROUND(SUM(CASE WHEN d.prev_day_local <> d.day_local THEN d.delta_percent END), 3) AS unknown_percent,
  COUNT(*) AS pair_count,
  SUM(d.prev_day_local <> d.day_local) AS unattributed_pairs
FROM v_sample_delta d
WHERE d.kind <> 'first'
GROUP BY d.service, d.window_kind, d.day_local;
