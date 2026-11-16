-- Minimal data-contract assertions.  Run after 01_schema.sql + 02_views.sql.
-- These are intentionally small checks that catch the failures most likely to
-- invalidate a market-data analysis: impossible OHLC, duplicate keys, empty
-- derived models, non-positive risk, and unknown exit reasons.

DO $$
DECLARE
    bad_rows integer;
BEGIN
    SELECT count(*) INTO bad_rows
    FROM nq.bars_1m
    WHERE high < low
       OR open < low OR open > high
       OR close < low OR close > high;

    IF bad_rows > 0 THEN
        RAISE EXCEPTION 'OHLC contract failed on % rows', bad_rows;
    END IF;

    SELECT count(*) INTO bad_rows
    FROM (
        SELECT symbol, ts
        FROM nq.bars_1m
        GROUP BY symbol, ts
        HAVING count(*) > 1
    ) duplicates;

    IF bad_rows > 0 THEN
        RAISE EXCEPTION 'duplicate timestamp keys: %', bad_rows;
    END IF;

    IF (SELECT count(*) FROM nq.london_ranges) = 0 THEN
        RAISE EXCEPTION 'london_ranges is empty';
    END IF;

    IF (SELECT count(*) FROM nq.first_breaks) = 0 THEN
        RAISE EXCEPTION 'first_breaks is empty';
    END IF;

    SELECT count(*) INTO bad_rows
    FROM nq.first_breaks
    WHERE risk_points <= 0;

    IF bad_rows > 0 THEN
        RAISE EXCEPTION 'non-positive risk on % first breaks', bad_rows;
    END IF;

    SELECT count(*) INTO bad_rows
    FROM nq.trade_outcomes
    WHERE exit_reason NOT IN ('target', 'stop', 'time')
       OR exit_ts IS NULL;

    IF bad_rows > 0 THEN
        RAISE EXCEPTION 'invalid exit outcome on % rows', bad_rows;
    END IF;
END $$;

SELECT 'assertions passed' AS status;
