-- Monthly equity curve, rolling three-month average and drawdown.
-- The drawdown uses the running peak of cumulative net P&L, so it is a
-- trade-sequenced curve, not a daily mark-to-market account statement.

WITH monthly AS (
    SELECT
        date_trunc('month', session_date)::date AS month,
        count(*) AS trades,
        count(*) FILTER (WHERE net_pnl > 0) AS wins,
        sum(net_pnl) AS net_pnl,
        sum(gross_pnl) AS gross_pnl
    FROM nq.trade_outcomes
    GROUP BY 1
),
running AS (
    SELECT
        *,
        sum(net_pnl) OVER (ORDER BY month) AS cumulative_net,
        avg(net_pnl) OVER (
            ORDER BY month
            ROWS BETWEEN 2 PRECEDING AND CURRENT ROW
        ) AS rolling_3m_avg
    FROM monthly
),
drawdown AS (
    SELECT
        *,
        cumulative_net - max(cumulative_net) OVER (ORDER BY month) AS drawdown
    FROM running
)
SELECT
    month,
    trades,
    wins,
    round(100.0 * wins / NULLIF(trades, 0), 2) AS win_rate_pct,
    round(net_pnl, 2) AS net_pnl,
    round(cumulative_net, 2) AS cumulative_net,
    round(rolling_3m_avg, 2) AS rolling_3m_avg,
    round(drawdown, 2) AS drawdown,
    CASE WHEN net_pnl > 0 THEN 'positive' ELSE 'negative' END AS month_result
FROM drawdown
ORDER BY month;
