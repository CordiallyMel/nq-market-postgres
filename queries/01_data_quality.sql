-- Data-quality profile for the 1-minute tape.
-- The gaps are expected outside RTH/weekends; the point is to make them visible
-- rather than pretending the continuous futures series is a clean calendar.

WITH bounds AS (
    SELECT
        count(*) AS rows,
        count(DISTINCT session_date) AS sessions,
        count(*) FILTER (WHERE is_rth) AS rth_bars,
        min(ts) AS first_ts,
        max(ts) AS last_ts
    FROM nq.bars_1m
),
gaps AS (
    SELECT
        ts,
        lag(ts) OVER (ORDER BY ts) AS prior_ts,
        extract(epoch FROM (ts - lag(ts) OVER (ORDER BY ts))) / 60.0 AS gap_minutes
    FROM nq.bars_1m
),
gap_summary AS (
    SELECT
        count(*) FILTER (WHERE gap_minutes > 1) AS gaps_over_1m,
        count(*) FILTER (WHERE gap_minutes > 5) AS gaps_over_5m,
        max(gap_minutes) AS max_gap_minutes,
        avg(gap_minutes) FILTER (WHERE gap_minutes > 1) AS avg_gap_minutes
    FROM gaps
),
duplicates AS (
    SELECT count(*) AS duplicate_keys
    FROM (
        SELECT symbol, ts
        FROM nq.bars_1m
        GROUP BY symbol, ts
        HAVING count(*) > 1
    ) d
)
SELECT
    b.rows,
    b.sessions,
    b.rth_bars,
    b.first_ts,
    b.last_ts,
    g.gaps_over_1m,
    g.gaps_over_5m,
    round(g.max_gap_minutes, 1) AS max_gap_minutes,
    round(g.avg_gap_minutes, 2) AS avg_gap_minutes,
    d.duplicate_keys
FROM bounds b
CROSS JOIN gap_summary g
CROSS JOIN duplicates d;
