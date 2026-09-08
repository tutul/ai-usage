-- cache_request 原本只有 Claude，隱含假設了單一來源。接 Codex 需要 service 欄位。
--
-- 既有列全部是 Claude，所以 DEFAULT 'claude' 就是正確的回填。
ALTER TABLE cache_request ADD COLUMN service TEXT NOT NULL DEFAULT 'claude';

CREATE INDEX idx_cache_request_service ON cache_request(service, observed_at);

DROP VIEW v_cache_daily;
DROP VIEW v_cache_request;

CREATE VIEW v_cache_request AS
SELECT r.*,
       r.observed_at - LAG(r.observed_at) OVER (
           PARTITION BY r.service, r.session_id ORDER BY r.observed_at
       ) AS gap_seconds,
       date(r.observed_at, 'unixepoch', 'localtime') AS day_local
FROM cache_request r;

-- **`created_after_idle` 只對 Claude 有意義。**
-- 那個門檻（cache_idle_seconds = 3600）來自實測 Claude 的快取幾乎全是 1 小時 TTL。
-- Codex 的 TTL 未知 —— 它的紀錄沒有 TTL 分解欄位，我們也沒有辦法從外部觀測。
-- 套用 Claude 的門檻就是在編一個看起來合理但沒有根據的數字，所以 Codex 一律給 0，
-- UI 顯示為「—」。等哪天能觀測到 Codex 的 TTL 再說。
CREATE VIEW v_cache_daily AS
SELECT d.service,
       d.cwd,
       d.day_local,
       COUNT(*)                     AS requests,
       SUM(d.cache_read_tokens)     AS read_tokens,
       SUM(d.cache_creation_tokens) AS created_tokens,
       SUM(CASE WHEN d.service = 'claude' AND d.gap_seconds > c.idle
                THEN d.cache_creation_tokens ELSE 0 END) AS created_after_idle,
       SUM(CASE WHEN d.service = 'claude' AND d.gap_seconds > c.idle
                THEN 1 ELSE 0 END)  AS idle_resumes,
       SUM(d.input_tokens)          AS input_tokens,
       SUM(d.output_tokens)         AS output_tokens
FROM v_cache_request d
CROSS JOIN (SELECT CAST(value AS INTEGER) AS idle FROM setting WHERE key = 'cache_idle_seconds') c
GROUP BY d.service, d.cwd, d.day_local;
