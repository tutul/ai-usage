-- `fetch.error_kind = 'offline'`：這台機器當時連不到網際網路。見 D-022。
--
-- 與 'slept' 同一類 —— 那次沒有觀測，不是服務故障，健康度不計入。
-- 實測 2026-09-15～10-10：Claude 的 568 筆 network 失敗裡有 540 筆落在 13 段
-- 連續失敗中，使用者確認那幾段時間機器醒著但沒有網路。
--
-- **舊資料不回填**（理由同 010）：當時沒有問「連得到網路嗎」，事後只能從
-- 「兩家同時失敗」「連續很多筆」去猜，不把猜測寫進原始紀錄。

DROP VIEW v_health;

CREATE VIEW v_health AS
SELECT f.service,
       MAX(CASE WHEN f.ok=1 THEN f.completed_at END) AS last_success_at,
       MAX(f.completed_at)                           AS last_attempt_at,
       SUM(f.ok=0 AND COALESCE(f.error_kind,'') NOT IN ('slept','offline')) AS failures_total,
       SUM(f.ok=0 AND COALESCE(f.error_kind,'') NOT IN ('slept','offline')
           AND f.completed_at > CAST(strftime('%s','now') AS INTEGER) - 86400) AS failures_24h,
       SUM(f.error_kind = 'slept')                   AS slept_total,
       SUM(f.error_kind = 'offline')                 AS offline_total,
       -- HTTP 成功不等於拿到週用量：窗可能換位或消失。
       -- 週資料的新鮮度直接量在 sample 上，不靠 fetch.ok 兼表。
       (SELECT MAX(s.observed_at) FROM sample s
         WHERE s.service = f.service AND s.window_kind = 'weekly') AS last_weekly_at
FROM fetch f GROUP BY f.service;
