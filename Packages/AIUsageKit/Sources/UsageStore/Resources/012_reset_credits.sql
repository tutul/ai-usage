-- 提前重置是誰做的。見 D-021。
--
-- Codex 的用量端點一直帶著
--   "rate_limit_reset_credits": { "available_count": 3, "applicable_available_count": 0 }
-- —— 使用者可以存起來、之後自己兌換的重置額度。兌換會同時清空 session 與 weekly，
-- 並重新定錨 weekly。實測 2026-09-15 17:56→18:01 與 09-28 14:09→14:20 兩次換窗，
-- 額度數都跟著從 3 變 2；08-30／08-31 那兩次則沒變（OpenAI 主動重置）。
-- 兩種在 `ended_early` 上長得一樣，但意義相反：一個是自己選的，一個是被動的。
--
-- 這張表只記**觀測到的數字**，與 sample 同一套規則：每次成功抓取都寫（值沒變也寫）、
-- 只增不改。回應裡沒有這個欄位時不寫列 —— 沒觀測到不等於 0。

CREATE TABLE reset_credit (
  fetch_id        INTEGER PRIMARY KEY REFERENCES fetch(id),
  service         TEXT    NOT NULL,
  observed_at     INTEGER NOT NULL,            -- = fetch.completed_at
  available_count INTEGER NOT NULL
);
CREATE INDEX idx_reset_credit_time ON reset_credit(service, observed_at);

-- 從留存的原始回應補上過去的觀測。**這不是回填合成資料** —— 每一列都是當時端點
-- 真的回過的數字，時間是那次抓取的真實時刻。raw_payload 只在百分比或 resets_at
-- 有變時才留存，所以用量持平的時段沒有列；那些時段就是沒有觀測，不補。
INSERT INTO reset_credit(fetch_id, service, observed_at, available_count)
SELECT f.id, f.service, f.completed_at,
       json_extract(r.body, '$.rate_limit_reset_credits.available_count')
  FROM fetch f
  JOIN raw_payload r ON r.id = f.raw_id
 WHERE f.ok = 1
   AND CASE WHEN json_valid(r.body)
            THEN json_type(r.body, '$.rate_limit_reset_credits.available_count')
       END = 'integer';

-- 換窗前後各看多遠。額度數的更新會比換窗晚一輪取樣（實測 09-15：18:01 已換窗，
-- 18:06 才少一個），所以「之後」不能只看第一筆。
-- 也不能看太遠：額度會到期（發放後 30 天）也會新發，離換窗越遠，
-- 數字的變化越可能與這次重置無關。兩側都超出這個範圍就當作不知道。
INSERT OR IGNORE INTO setting(key, value) VALUES ('reset_cause_window_seconds', '3600');

-- 每個被提前重置的窗一列。
--   redeemed  換窗前後額度數減少   -> 使用者自己兌換
--   external  兩側都有觀測、沒有減少 -> 服務端主動重置
--   NULL      任一側沒有觀測        -> 不知道（Claude 目前恆為此值）
CREATE VIEW v_window_reset_cause AS
WITH cfg AS (
  SELECT CAST(value AS INTEGER) AS span FROM setting WHERE key = 'reset_cause_window_seconds'
),
observed AS (
  SELECT
    w.service, w.window_kind, w.window_seq, w.last_seen_at,
    (SELECT c.available_count FROM reset_credit c
      WHERE c.service = w.service
        AND c.observed_at <= w.last_seen_at
        AND c.observed_at >= w.last_seen_at - cfg.span
      ORDER BY c.observed_at DESC, c.fetch_id DESC LIMIT 1) AS credits_before,
    (SELECT MIN(c.available_count) FROM reset_credit c
      WHERE c.service = w.service
        AND c.observed_at > w.last_seen_at
        AND c.observed_at <= w.last_seen_at + cfg.span) AS credits_after
  FROM v_window_summary w CROSS JOIN cfg
  WHERE w.ended_early = 1
)
SELECT
  o.service, o.window_kind, o.window_seq, o.last_seen_at,
  o.credits_before, o.credits_after,
  CASE
    WHEN o.credits_before IS NULL OR o.credits_after IS NULL THEN NULL
    WHEN o.credits_after < o.credits_before                  THEN 'redeemed'
    ELSE 'external'
  END AS reset_cause
FROM observed o;
