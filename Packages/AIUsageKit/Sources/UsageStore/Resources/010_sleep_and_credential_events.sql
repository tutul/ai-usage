-- 兩件事，見 D-017。
--
-- 1. `fetch.error_kind = 'slept'`：請求期間系統睡著了，這次沒有觀測，不是服務故障。
--    健康度不計入。**舊資料不回填** —— 010 之前的睡眠逾時仍記為 'network'，
--    當時沒有量清醒時間，事後只能用持續時間猜，不把猜測寫進原始紀錄。
--
-- 2. `credential_event`：憑證生命週期的事件。系統日誌保存期太短，出事時常常已經查不到。
--    **絕不存 token。**

CREATE TABLE credential_event (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  service     TEXT    NOT NULL,
  occurred_at INTEGER NOT NULL,              -- unix epoch (UTC)
  event       TEXT    NOT NULL,              -- 'source_changed'|'renewed'|'renewal_failed'|'discarded'|'rejected'
  source      TEXT,                          -- 'own'|'file'|'claude_code'
  detail      TEXT    NOT NULL
);
CREATE INDEX idx_credential_event_time ON credential_event(service, occurred_at);

DROP VIEW v_health;

-- failures_total 原本是永久累計，對「現在健不健康」沒有參考價值（TODO #2）。
-- 保留它（語意改為不含 slept），另加最近 24 小時的版本。
CREATE VIEW v_health AS
SELECT f.service,
       MAX(CASE WHEN f.ok=1 THEN f.completed_at END) AS last_success_at,
       MAX(f.completed_at)                           AS last_attempt_at,
       SUM(f.ok=0 AND COALESCE(f.error_kind,'') <> 'slept') AS failures_total,
       SUM(f.ok=0 AND COALESCE(f.error_kind,'') <> 'slept'
           AND f.completed_at > CAST(strftime('%s','now') AS INTEGER) - 86400) AS failures_24h,
       SUM(f.error_kind = 'slept')                   AS slept_total,
       -- HTTP 成功不等於拿到週用量：窗可能換位或消失。
       -- 週資料的新鮮度直接量在 sample 上，不靠 fetch.ok 兼表。
       (SELECT MAX(s.observed_at) FROM sample s
         WHERE s.service = f.service AND s.window_kind = 'weekly') AS last_weekly_at
FROM fetch f GROUP BY f.service;
