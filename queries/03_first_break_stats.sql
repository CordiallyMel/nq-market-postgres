-- First-break behaviour by year and side.
-- The denominator is all London sessions in nq.london_ranges, so break_rate_pct
-- is a real session rate, not a share of trades.

WITH breaks AS (
    SELECT
        extract(year FROM session_date)::int AS year,
        side,
        count(*) AS breaks,
        round(avg(range_pct), 3) AS avg_range_at_break_pct,
        round(avg(risk_points), 2) AS avg_stop_points,
        count(*) FILTER (WHERE range_cap_ok) AS cap_eligible
    FROM nq.first_breaks
    GROUP BY 1, 2
),
sessions AS (
    SELECT
        extract(year FROM session_date)::int AS year,
        count(*) AS london_sessions
    FROM nq.london_ranges
    GROUP BY 1
)
SELECT
    b.year,
    b.side,
    b.breaks,
    round(100.0 * b.breaks / s.london_sessions, 2) AS break_rate_pct,
    b.avg_range_at_break_pct,
    b.avg_stop_points,
    b.cap_eligible,
    round(100.0 * b.cap_eligible / b.breaks, 2) AS cap_eligible_pct,
    rank() OVER (PARTITION BY b.year ORDER BY b.breaks DESC) AS side_rank
FROM breaks b
JOIN sessions s USING (year)
ORDER BY b.year, b.side;
