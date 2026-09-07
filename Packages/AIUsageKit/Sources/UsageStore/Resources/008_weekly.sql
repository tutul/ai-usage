-- 週粒度。結構照抄 v_daily —— 同樣的歸屬判準，只是換一個分桶單位。
--
-- **這是曆週（週一起算），不是「額度週窗」。** 兩者不同：額度窗以首次使用為錨點，
-- 每個人、每次重置都不一樣；曆週是固定的。實測 2026-08-30／08-31 有兩次外部提前
-- 重置（見 D-016 前的紀錄），那段期間一個窗只活了 16 與 26 小時 —— 若用「窗」當
-- 週的代理，那幾天會冒出好幾個假的「週」。要看每個額度窗用了多少，讀
-- v_window_summary，那裡的 used_percent 是最後觀測值、不經 delta 推導。
--
-- 週一起算：%w 是 0(日)–6(六)，(%w + 6) % 7 就是「距離本週一幾天」。
CREATE VIEW v_weekly AS
WITH w AS (
    SELECT d.*,
           date(d.observed_at, 'unixepoch', 'localtime',
                '-' || ((CAST(strftime('%w', d.observed_at, 'unixepoch', 'localtime') AS INTEGER) + 6) % 7)
                    || ' days') AS week_local,
           date(d.prev_observed_at, 'unixepoch', 'localtime',
                '-' || ((CAST(strftime('%w', d.prev_observed_at, 'unixepoch', 'localtime') AS INTEGER) + 6) % 7)
                    || ' days') AS prev_week_local
      FROM v_sample_delta d
     WHERE d.kind <> 'first'
)
SELECT
  w.service, w.window_kind, w.week_local,
  CAST(strftime('%s', w.week_local, 'utc') AS INTEGER) AS week_start_epoch,
  ROUND(SUM(CASE WHEN w.prev_week_local = w.week_local THEN w.delta_percent END), 3) AS used_percent,
  ROUND(SUM(CASE WHEN w.prev_week_local <> w.week_local THEN w.delta_percent END), 3) AS unknown_percent,
  COUNT(*) AS pair_count,
  SUM(w.prev_week_local <> w.week_local) AS unattributed_pairs
FROM w
GROUP BY w.service, w.window_kind, w.week_local;
