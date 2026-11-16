-- Headline outcome profile for the SQL implementation of the range-capped
-- first-touch model.  GROUPING SETS gives a side split plus an ALL row.

WITH grouped AS (
    SELECT
        COALESCE(side, 'ALL') AS side,
        count(*) AS trades,
        count(*) FILTER (WHERE net_pnl > 0) AS wins,
        count(*) FILTER (WHERE exit_reason = 'target') AS targets,
        count(*) FILTER (WHERE exit_reason = 'stop') AS stops,
        count(*) FILTER (WHERE exit_reason = 'time') AS time_exits,
        sum(net_pnl) AS net_pnl,
        sum(gross_pnl) AS gross_pnl,
        avg(r_multiple) AS avg_r,
        avg(risk_dollars) AS avg_risk_dollars,
        avg(hold_minutes) AS avg_hold_minutes,
        sum(net_pnl) FILTER (WHERE net_pnl > 0) AS gross_profit,
        -sum(net_pnl) FILTER (WHERE net_pnl < 0) AS gross_loss
    FROM nq.trade_outcomes
    GROUP BY GROUPING SETS ((side), ())
)
SELECT
    side,
    trades,
    wins,
    round(100.0 * wins / NULLIF(trades, 0), 2) AS win_rate_pct,
    targets,
    stops,
    time_exits,
    round(net_pnl, 2) AS net_pnl,
    round(gross_pnl, 2) AS gross_pnl,
    round(net_pnl / NULLIF(trades, 0), 2) AS expectancy_per_trade,
    round(avg_r, 4) AS avg_r,
    round(avg_risk_dollars, 2) AS avg_risk_dollars,
    round(avg_hold_minutes, 1) AS avg_hold_minutes,
    round(gross_profit / NULLIF(gross_loss, 0), 3) AS profit_factor,
    rank() OVER (ORDER BY net_pnl DESC) AS net_rank
FROM grouped
ORDER BY CASE WHEN side = 'ALL' THEN 1 ELSE 0 END, net_pnl DESC;
