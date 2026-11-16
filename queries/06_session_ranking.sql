-- Rank London sessions within their month and compare each day with the prior
-- session.  This is the window-function-heavy query: RANK, NTILE, PERCENT_RANK,
-- LAG and a conditional aggregate.

WITH ranked AS (
    SELECT
        symbol,
        session_date,
        range_points,
        round(100.0 * range_points / NULLIF(london_high, 0), 3) AS range_pct_of_high,
        date_trunc('month', session_date)::date AS month,
        rank() OVER (
            PARTITION BY date_trunc('month', session_date)
            ORDER BY range_points DESC
        ) AS range_rank_in_month,
        ntile(4) OVER (
            PARTITION BY date_trunc('month', session_date)
            ORDER BY range_points
        ) AS range_quartile,
        round(percent_rank() OVER (
            PARTITION BY date_trunc('month', session_date)
            ORDER BY range_points
        )::numeric, 4) AS range_percent_rank,
        lag(range_points) OVER (
            PARTITION BY symbol
            ORDER BY session_date
        ) AS prior_session_range_points
    FROM nq.london_ranges
),
with_change AS (
    SELECT
        *,
        range_points - prior_session_range_points AS range_change_points,
        avg(range_points) OVER (
            PARTITION BY month
        ) AS month_avg_range_points
    FROM ranked
)
SELECT
    month,
    session_date,
    range_points,
    range_pct_of_high,
    range_rank_in_month,
    range_quartile,
    range_percent_rank,
    round(month_avg_range_points, 2) AS month_avg_range_points,
    round(range_change_points, 2) AS range_change_points
FROM with_change
WHERE range_rank_in_month <= 10
ORDER BY month DESC, range_rank_in_month;
