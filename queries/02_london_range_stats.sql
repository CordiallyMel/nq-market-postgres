-- London-range distribution by month.
-- Shows CTEs, date_trunc, RANK and a three-month moving average.

WITH monthly AS (
    SELECT
        date_trunc('month', session_date)::date AS month,
        count(*) AS sessions,
        avg(range_points) AS avg_range_points,
        max(range_points) AS max_range_points,
        avg(range_pct_of_high) AS avg_range_pct_of_high,
        avg(london_bars) AS avg_london_bars
    FROM nq.london_ranges
    GROUP BY 1
),
ranked AS (
    SELECT
        *,
        rank() OVER (ORDER BY avg_range_points DESC) AS widest_month_rank,
        avg(avg_range_points) OVER (
            ORDER BY month
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ) AS rolling_3m_avg_points
    FROM monthly
)
SELECT
    month,
    sessions,
    round(avg_range_points, 2) AS avg_range_points,
    round(max_range_points, 2) AS max_range_points,
    round(avg_range_pct_of_high, 3) AS avg_range_pct_of_high,
    round(avg_london_bars, 1) AS avg_london_bars,
    round(rolling_3m_avg_points, 2) AS rolling_3m_avg_points,
    widest_month_rank
FROM ranked
ORDER BY month DESC
LIMIT 36;
