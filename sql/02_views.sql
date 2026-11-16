-- Analytical models, built once after the 1-minute load.
-- The definitions use CTEs and window functions; materialization keeps the
-- downstream portfolio queries fast on a 3.35-million-row tape.

DROP MATERIALIZED VIEW IF EXISTS nq.trade_outcomes CASCADE;
DROP MATERIALIZED VIEW IF EXISTS nq.first_breaks CASCADE;
DROP MATERIALIZED VIEW IF EXISTS nq.london_ranges CASCADE;
DROP MATERIALIZED VIEW IF EXISTS nq.bars_5m CASCADE;

-- Five-minute OHLCV from the 1-minute source.
CREATE MATERIALIZED VIEW nq.bars_5m AS
WITH tagged AS (
    SELECT
        symbol,
        date_bin('5 minutes', ts, TIMESTAMPTZ '2000-01-01 00:00:00+00') AS bucket_start,
        ts,
        open,
        high,
        low,
        close,
        volume,
        session_date
    FROM nq.bars_1m
),
rolled AS (
    SELECT
        *,
        first_value(open) OVER w AS open_5m,
        max(high)        OVER w AS high_5m,
        min(low)         OVER w AS low_5m,
        last_value(close) OVER w AS close_5m,
        sum(volume)      OVER w AS volume_5m,
        row_number() OVER (
            PARTITION BY symbol, bucket_start
            ORDER BY ts DESC
        ) AS rn
    FROM tagged
    WINDOW w AS (
        PARTITION BY symbol, bucket_start
        ORDER BY ts
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    )
)
SELECT
    symbol,
    bucket_start,
    session_date,
    open_5m  AS open,
    high_5m  AS high,
    low_5m   AS low,
    close_5m AS close,
    volume_5m AS volume
FROM rolled
WHERE rn = 1
WITH DATA;

CREATE UNIQUE INDEX bars_5m_pk
    ON nq.bars_5m (symbol, bucket_start);
CREATE INDEX bars_5m_session_idx
    ON nq.bars_5m (session_date, bucket_start);

-- London range: 04:00-08:59 New York local time.
CREATE MATERIALIZED VIEW nq.london_ranges AS
WITH london AS (
    SELECT
        symbol,
        session_date,
        bucket_start,
        open,
        high,
        low,
        close,
        volume
    FROM nq.bars_5m
    WHERE (bucket_start AT TIME ZONE 'America/New_York')::time >= TIME '04:00'
      AND (bucket_start AT TIME ZONE 'America/New_York')::time <  TIME '09:00'
),
agg AS (
    SELECT
        symbol,
        session_date,
        min(low)  AS london_low,
        max(high) AS london_high,
        count(*)  AS london_bars,
        min(bucket_start) AS first_bucket,
        max(bucket_start) AS last_bucket
    FROM london
    GROUP BY symbol, session_date
)
SELECT
    symbol,
    session_date,
    london_low,
    london_high,
    london_high - london_low AS range_points,
    london_bars,
    first_bucket,
    last_bucket,
    round(100.0 * (london_high - london_low) / NULLIF(london_high, 0), 4) AS range_pct_of_high
FROM agg
WHERE london_bars >= 24
WITH DATA;

CREATE UNIQUE INDEX london_ranges_pk
    ON nq.london_ranges (symbol, session_date);
CREATE INDEX london_ranges_month_idx
    ON nq.london_ranges (session_date);

-- First break of the London range, 09:30-10:59 ET.
CREATE MATERIALIZED VIEW nq.first_breaks AS
WITH classified AS (
    SELECT
        b.symbol,
        b.session_date,
        b.ts AS entry_ts,
        b.open,
        b.high,
        b.low,
        b.close,
        l.london_high,
        l.london_low,
        l.range_points,
        CASE
            WHEN b.high >= l.london_high AND b.low <= l.london_low THEN
                CASE
                    WHEN abs(b.open - l.london_low) <= abs(l.london_high - b.open)
                    THEN 'short'
                    ELSE 'long'
                END
            WHEN b.high >= l.london_high THEN 'long'
            ELSE 'short'
        END AS side
    FROM nq.bars_1m b
    JOIN nq.london_ranges l
      ON l.symbol = b.symbol
     AND l.session_date = b.session_date
    WHERE b.is_rth
      AND (b.ts AT TIME ZONE 'America/New_York')::time >= TIME '09:30'
      AND (b.ts AT TIME ZONE 'America/New_York')::time <  TIME '11:00'
      AND (b.high >= l.london_high OR b.low <= l.london_low)
),
ranked AS (
    SELECT
        *,
        row_number() OVER (
            PARTITION BY symbol, session_date
            ORDER BY entry_ts, side
        ) AS rn
    FROM classified
),
priced AS (
    SELECT
        symbol,
        session_date,
        entry_ts,
        side,
        open,
        high,
        low,
        close,
        london_high,
        london_low,
        range_points,
        CASE
            WHEN side = 'long' THEN greatest(open, london_high)
            ELSE least(open, london_low)
        END AS raw_entry,
        CASE
            WHEN side = 'long' THEN greatest(open, london_high) + 0.25
            ELSE least(open, london_low) - 0.25
        END AS entry_price
    FROM ranked
    WHERE rn = 1
),
with_prior AS (
    SELECT
        p.*,
        prior.prior_high,
        prior.prior_low,
        prior.prior_bucket
    FROM priced p
    LEFT JOIN LATERAL (
        SELECT
            b5.high AS prior_high,
            b5.low  AS prior_low,
            b5.bucket_start AS prior_bucket
        FROM nq.bars_5m b5
        WHERE b5.symbol = p.symbol
          AND b5.bucket_start < date_bin(
              '5 minutes', p.entry_ts, TIMESTAMPTZ '2000-01-01 00:00:00+00'
          )
        ORDER BY b5.bucket_start DESC
        LIMIT 1
    ) prior ON true
),
with_stop AS (
    SELECT
        *,
        CASE
            WHEN side = 'long'  THEN prior_low - 0.25
            ELSE prior_high + 0.25
        END AS stop_price
    FROM with_prior
),
with_risk AS (
    SELECT
        *,
        CASE
            WHEN side = 'long'  THEN entry_price - stop_price
            ELSE stop_price - entry_price
        END AS risk_points,
        100.0 * (london_high - london_low) / NULLIF(entry_price, 0) AS range_pct
    FROM with_stop
)
SELECT
    symbol,
    session_date,
    entry_ts,
    side,
    open,
    high,
    low,
    close,
    london_high,
    london_low,
    range_points,
    prior_high,
    prior_low,
    prior_bucket,
    raw_entry,
    entry_price,
    stop_price,
    risk_points,
    range_pct,
    (risk_points > 0) AS valid_stop,
    (range_pct <= 0.90) AS range_cap_ok,
    round((entry_price + CASE WHEN side = 'long' THEN 2 ELSE -2 END
           * risk_points) / 0.25) * 0.25 AS target_price
FROM with_risk
WITH DATA;

CREATE UNIQUE INDEX first_breaks_pk
    ON nq.first_breaks (symbol, session_date);
CREATE INDEX first_breaks_cap_idx
    ON nq.first_breaks (session_date)
    WHERE valid_stop AND range_cap_ok;

-- First-touch outcomes.  If stop and target share a minute, stop wins.
CREATE MATERIALIZED VIEW nq.trade_outcomes AS
WITH candidates AS (
    SELECT *
    FROM nq.first_breaks
    WHERE valid_stop
      AND range_cap_ok
),
exits AS (
    SELECT
        c.*,
        e.stop_ts,
        e.target_ts,
        e.time_ts
    FROM candidates c
    LEFT JOIN LATERAL (
        SELECT
            min(b.ts) FILTER (
                WHERE (c.side = 'long'  AND b.low  <= c.stop_price)
                   OR (c.side = 'short' AND b.high >= c.stop_price)
            ) AS stop_ts,
            min(b.ts) FILTER (
                WHERE (c.side = 'long'  AND b.high >= c.target_price)
                   OR (c.side = 'short' AND b.low  <= c.target_price)
            ) AS target_ts,
            min(b.ts) FILTER (
                WHERE (b.ts AT TIME ZONE 'America/New_York')::time >= TIME '16:00'
            ) AS time_ts
        FROM nq.bars_1m b
        WHERE b.symbol = c.symbol
          AND b.session_date = c.session_date
          AND b.ts > c.entry_ts
          AND (b.ts AT TIME ZONE 'America/New_York')::time <= TIME '16:00'
    ) e ON true
),
joined AS (
    SELECT
        x.*,
        t.open AS time_open
    FROM exits x
    LEFT JOIN nq.bars_1m t
      ON t.symbol = x.symbol
     AND t.ts = x.time_ts
),
decided AS (
    SELECT
        *,
        CASE
            WHEN stop_ts IS NOT NULL
             AND (target_ts IS NULL OR stop_ts <= target_ts) THEN 'stop'
            WHEN target_ts IS NOT NULL THEN 'target'
            ELSE 'time'
        END AS exit_reason,
        CASE
            WHEN stop_ts IS NOT NULL
             AND (target_ts IS NULL OR stop_ts <= target_ts) THEN stop_ts
            WHEN target_ts IS NOT NULL THEN target_ts
            ELSE time_ts
        END AS exit_ts
    FROM joined
),
filled AS (
    SELECT
        *,
        CASE
            WHEN exit_reason = 'target' THEN target_price
            WHEN exit_reason = 'stop'   THEN stop_price
            ELSE time_open + CASE WHEN side = 'long' THEN -0.25 ELSE 0.25 END
        END AS exit_price
    FROM decided
),
calculated AS (
    SELECT
        *,
        round(
            CASE
                WHEN side = 'long' THEN exit_price - entry_price
                ELSE entry_price - exit_price
            END, 2
        ) AS gross_points
    FROM filled
)
SELECT
    symbol,
    session_date,
    entry_ts,
    side,
    entry_price,
    stop_price,
    target_price,
    risk_points,
    range_pct,
    exit_reason,
    exit_ts,
    exit_price,
    gross_points,
    round(gross_points * 20, 2) AS gross_pnl,
    round(gross_points * 20 - 1.24, 2) AS net_pnl,
    round(gross_points / NULLIF(risk_points, 0), 4) AS r_multiple,
    round(risk_points * 20, 2) AS risk_dollars,
    round(extract(epoch FROM (exit_ts - entry_ts)) / 60.0, 1) AS hold_minutes
FROM calculated
WITH DATA;

CREATE UNIQUE INDEX trade_outcomes_pk
    ON nq.trade_outcomes (symbol, session_date);
CREATE INDEX trade_outcomes_month_idx
    ON nq.trade_outcomes (session_date, side);

ANALYZE nq.bars_5m;
ANALYZE nq.london_ranges;
ANALYZE nq.first_breaks;
ANALYZE nq.trade_outcomes;
