# NQ Market Data — PostgreSQL Portfolio

A reproducible SQL portfolio project built from **3.35 million NQ 1-minute bars**.
It models a London-session range, finds the first U.S.-open breakout, applies a
wide-range filter, and evaluates first-touch trade outcomes with PostgreSQL
**CTEs, window functions, `FILTER`, `LATERAL`, and materialized views**.

This is the SQL/work-sample project. It is deliberately separate from the
Python research engine in `SkyQ_NewLondon`.

---

## What this demonstrates

| Skill | Where it appears |
|---|---|
| Relational schema and constraints | `sql/01_schema.sql` |
| Time-zone and session logic | `london_ranges`, `first_breaks` |
| 1-minute → 5-minute aggregation | `bars_5m` materialized view |
| Window functions | `first_value`, `last_value`, `row_number`, `rank`, `ntile`, `percent_rank`, `lag` |
| CTE-heavy analytical SQL | every file in `queries/` |
| Conditional aggregates | `count(*) FILTER`, `sum(...) FILTER` |
| Correlated first-touch logic | `LEFT JOIN LATERAL` in `trade_outcomes` |
| Materialization and indexing | `sql/02_views.sql` |
| Data-quality checks | `queries/01_data_quality.sql` |
| Reproducible loading | `scripts/load_data.py` |

The point is not to hide a trading strategy inside a notebook. Every modeling
choice is visible in SQL and can be inspected, tested, and changed.

---

## Data model

```text
nq.bars_1m                 one row per NQ minute
  symbol, ts, open, high, low, close, volume, trades,
  session_date (New York local date), is_rth

nq.bars_5m                 materialized 5-minute OHLCV
nq.london_ranges           materialized 04:00-08:59 ET range
nq.first_breaks            materialized first 09:30-10:59 ET break
nq.trade_outcomes          materialized range-capped, first-touch outcomes
```

### Rules encoded in the SQL model

- London range: 04:00–08:59 ET, built from 5-minute bars.
- Entry window: 09:30–10:59 ET.
- First break only; if one minute crosses both levels, the level closer to that
  minute's open is treated as first.
- Prior completed 5-minute bar supplies the stop.
- Target: 2R from the actual entry and stop.
- **Range cap:** skip sessions where `(London high − London low) / entry price >
  0.90%`.
- Time exit: 16:00 ET.
- If stop and target share a minute, stop wins.
- One NQ contract, $20/point, $1.24 round-turn commission, one tick of adverse
  slippage on entry and stop/time exits.

### Important scope note

This SQL model uses the **base prior-bar stop + 0.90% range cap**. It does not
implement the Python project's prior-month MAE q50 stop. The SQL result is an
independent analytics model, not an exact reproduction of the Python default.
That difference is intentional and called out again under “Limitations.”

---

## Results snapshot

From the full 2017-04-02 through 2026-10-23 load:

| Metric | SQL model |
|---|---:|
| Raw 1-minute rows | 3,350,033 |
| Sessions | 2,974 |
| London ranges | 2,462 |
| First breaks | 2,347 |
| Range-capped trades | 1,869 |
| Win rate | 36.92% |
| Net P&L | **+$85,592.40** |
| Gross P&L | +$87,905.00 |
| Profit factor | 1.137 |
| Expectancy per trade | $45.80 |
| Average R | 0.0882 |
| Average risk | $548.44 |
| Average hold | 44.9 minutes |
| Long / short trades | 1,003 / 866 |
| Target / stop / time exits | 650 / 1,155 / 64 |

These are **backtest dollars on one contract**, not live results. The full
result set is in [`results/`](results/).

The SQL model is profitable over the full sample, but the year-by-year and
monthly files show material drawdowns and regime dependence. It is a portfolio
artifact and a SQL demonstration, not a recommendation to trade.

---

## Quick start

### 1. Create an isolated local PostgreSQL cluster

Do not use an existing 5432 server. This project uses **port 55433** and stores
its cluster in `.pgdata/` (ignored by git).

From this folder on Windows:

```powershell
& "C:\Program Files\PostgreSQL\18\bin\initdb.exe" `
  -D .pgdata -U postgres -A trust --encoding=UTF8 --locale=C

& "C:\Program Files\PostgreSQL\18\bin\pg_ctl.exe" `
  -D .pgdata -o "-p 55433 -h 127.0.0.1" -l .pgdata/server.log start

& "C:\Program Files\PostgreSQL\18\bin\createdb.exe" `
  -h 127.0.0.1 -p 55433 -U postgres nq_research
```

Git Bash equivalents are in the shell history used to build this project.
The connection string is:

```text
postgresql://postgres@127.0.0.1:55433/nq_research
```

### 2. Load the committed four-session sample

The sample contains 2019-02-01 through 2019-02-05, including three
range-eligible trades, so every query returns rows immediately.

```powershell
python -m pip install -r requirements.txt
python scripts/load_data.py --data data/sample_nq_1m.csv
```

`psql` must be on `PATH`, or pass:

```powershell
python scripts/load_data.py `
  --data data/sample_nq_1m.csv `
  --psql "C:\Program Files\PostgreSQL\18\bin\psql.exe"
```

### 3. Load the full tape (optional)

The 56 MB parquet is not committed. Use the copy from the research project:

```powershell
python scripts/load_data.py `
  --data ..\..\SkyQ_NewLondon\data\nq_1m.parquet
```

The loader:

1. reads parquet or CSV with pandas;
2. derives New York `session_date` and RTH flags;
3. creates the schema;
4. streams CSV through `psql \copy`;
5. builds and indexes the four materialized views;
6. runs `ANALYZE`.

A full load took about a minute on the local Windows machine. The 5-minute
materialized view is built once; subsequent queries do not rescan 3.3 million
rows through a window function.

### 4. Run the portfolio queries

```powershell
$psql = "C:\Program Files\PostgreSQL\18\bin\psql.exe"
& $psql -h 127.0.0.1 -p 55433 -U postgres -d nq_research `
  --csv -f queries/01_data_quality.sql
```

Or run all six and write CSV results:

```bash
for q in queries/*.sql; do
  name=$(basename "$q" .sql)
  psql "postgresql://postgres@127.0.0.1:55433/nq_research" \
    --csv -v ON_ERROR_STOP=1 -f "$q" > "results/${name}.csv"
done
```

---

## Query map

| File | Question it answers |
|---|---|
| `queries/01_data_quality.sql` | Are the timestamps unique? How many sessions and RTH bars? Where are the gaps? |
| `queries/02_london_range_stats.sql` | How wide is the London range by month? Which months are widest? |
| `queries/03_first_break_stats.sql` | How often does the first break happen, by year and side? |
| `queries/04_trade_outcomes.sql` | What are win rate, P&L, PF, average R and exit mix, by side and overall? |
| `queries/05_monthly_performance.sql` | What does the monthly equity curve, rolling average and drawdown look like? |
| `queries/06_session_ranking.sql` | Which sessions had the widest ranges within a month? How did the range change day over day? |

The query files intentionally end in a single `SELECT` so they can be run
directly with `psql --csv`.

### SQL techniques in context

- `date_bin` makes 5-minute buckets from the 1-minute tape.
- `first_value` / `last_value` with a full window frame build OHLC bars.
- `row_number` picks exactly one first break per session.
- `LATERAL` finds the prior completed 5-minute bar and the first stop/target
  touch without a self-join explosion.
- `FILTER` computes targets, stops, and time exits in one pass.
- `GROUPING SETS` produces the side split plus the `ALL` row.
- `RANK`, `NTILE`, `PERCENT_RANK`, `LAG` rank sessions and measure changes.
- Materialized views keep the 3.35M-row source from being recomputed per query.

---

## Repository layout

```text
nq_market_postgres/
  data/
    sample_nq_1m.csv       # four committed sessions; loader-ready
    README.md              # data provenance and full-data instructions
  results/
    01_data_quality.csv
    02_london_range_stats.csv
    03_first_break_stats.csv
    04_trade_outcomes.csv
    05_monthly_performance.csv
    06_session_ranking.csv
  scripts/
    load_data.py           # pandas + psql \copy loader
  sql/
    01_schema.sql          # base table, constraints, indexes
    02_views.sql           # materialized analytical views
  queries/
    01_data_quality.sql
    02_london_range_stats.sql
    03_first_break_stats.sql
    04_trade_outcomes.sql
    05_monthly_performance.sql
    06_session_ranking.sql
  .gitignore
  requirements.txt
  README.md
```

---

## Why this is a good interview artifact

For **implementation / technical support** roles, it shows that you can:

- debug time-zone/session boundaries rather than hand-wave them;
- turn a messy 1-minute feed into a tested, queryable model;
- explain a join, a window frame, and a correlated subquery;
- keep a reproducible local environment and separate raw data from derived data.

For **data analyst / data engineer** roles, it shows:

- schema design with primary keys and check constraints;
- incremental thinking about materialization and indexes;
- SQL that answers product questions, not just `SELECT *`;
- explicit data-quality and limitations sections;
- a loader that can be rerun and reasoned about.

For **QA / SDET** roles, the project provides concrete examples of deterministic
checks and conservative failure handling (stop-first, duplicate-key check,
time-zone assertions).

---

## Limitations

- **Not the Python default.** This is the base-stop + 0.90% cap model. The
  Python default additionally uses a prior-month MAE q50 stop; see the
  `SkyQ_NewLondon` README and `FAILED_VERSIONS.md`.
- **Backtest only.** No broker, order router, live fills, margin, or risk engine.
- **First-touch approximation.** 1-minute OHLC cannot reveal intrabar ordering;
  stop-first is conservative but not a fill simulator.
- **No roll model.** NQ continuous data ignores quarterly roll gaps.
- **Fixed one contract.** No compounding or account-level drawdown control.
- **Costs are assumptions.** $1.24 round turn plus one tick on selected exits.
- **Materialized views are static.** After adding data, rebuild them in order:
  `bars_5m`, `london_ranges`, `first_breaks`, `trade_outcomes`.
- **In-sample model selection.** The 0.90% threshold comes from the research
  project and is not an out-of-sample proof.

---

## Data provenance

- Source: NQ continuous 1-minute parquet from the local research workspace.
- Full file: 3,350,033 rows, 2017-04-02 through 2026-10-23, `America/New_York`.
- Committed sample: 2019-02-01 through 2019-02-05, 4,095 rows.
- The parquet is intentionally excluded from git; the loader and sample are
  enough to run the project without a 56 MB binary in the repository.
