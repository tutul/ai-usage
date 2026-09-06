-- Claude Code 對話紀錄（JSONL）的 token 分解。
--
-- 這與 sample 是**兩條不同的管線**，刻意不共用任何機制：
--   sample        取樣外部端點，會漏、會有 gap，需要 delta／窗身分／無資料≠0
--   cache_request 匯入本機已存在的完整紀錄，不會漏，以上機制一條都用不到
-- 唯一共用的原則是 D-002：**存原始值，推導留給查詢時**。

CREATE TABLE cache_request (
    -- 去重鍵。一次 API 請求會在 JSONL 產生多行（每個內容區塊一行），
    -- 而**每一行都帶著同一份 usage** —— 逐行加總會灌水（實測 1.74 倍，且不均勻）。
    -- requestId 才是一次請求；少數缺 requestId 的退回用 uuid。
    request_key           TEXT PRIMARY KEY,
    session_id            TEXT,
    cwd                   TEXT,
    git_branch            TEXT,
    observed_at           INTEGER NOT NULL,
    input_tokens          INTEGER NOT NULL,
    cache_creation_tokens INTEGER NOT NULL,
    cache_read_tokens     INTEGER NOT NULL,
    output_tokens         INTEGER NOT NULL,
    ttl_5m_tokens         INTEGER NOT NULL,
    ttl_1h_tokens         INTEGER NOT NULL
);

CREATE INDEX idx_cache_request_time ON cache_request(observed_at);
CREATE INDEX idx_cache_request_session ON cache_request(session_id, observed_at);

-- 閒置多久算「快取已過期」。實測快取幾乎全是 1 小時 TTL
-- （155.5M vs 5 分鐘的 2.8M），所以門檻取 3600。
INSERT OR IGNORE INTO setting(key, value) VALUES ('cache_idle_seconds', '3600');

-- 距上次請求的間隔是推導值，查詢時算。
CREATE VIEW v_cache_request AS
SELECT r.*,
       r.observed_at - LAG(r.observed_at) OVER (
           PARTITION BY r.session_id ORDER BY r.observed_at
       ) AS gap_seconds,
       date(r.observed_at, 'unixepoch', 'localtime') AS day_local
FROM cache_request r;

-- 按專案 × 日的分布。
--
-- **只標記能可靠判斷的原因。** 「距上次超過 TTL」是可驗證的；其餘的重寫可能來自
-- 改動了前面的內容、context 壓縮、切換模型等等 —— 我們判斷不了，所以不歸因，
-- 只呈現數量讓使用者自己對照當時在做什麼。
CREATE VIEW v_cache_daily AS
SELECT d.cwd,
       d.day_local,
       COUNT(*)                          AS requests,
       SUM(d.cache_read_tokens)          AS read_tokens,
       SUM(d.cache_creation_tokens)      AS created_tokens,
       SUM(CASE WHEN d.gap_seconds > c.idle THEN d.cache_creation_tokens ELSE 0 END)
                                         AS created_after_idle,
       SUM(CASE WHEN d.gap_seconds > c.idle THEN 1 ELSE 0 END)
                                         AS idle_resumes,
       SUM(d.input_tokens)               AS input_tokens,
       SUM(d.output_tokens)              AS output_tokens
FROM v_cache_request d
CROSS JOIN (SELECT CAST(value AS INTEGER) AS idle FROM setting WHERE key = 'cache_idle_seconds') c
GROUP BY d.cwd, d.day_local;
