# Data

## Committed sample

`sample_nq_1m.csv` contains four NQ sessions:

- 2019-02-01 through 2019-02-05
- 4,095 one-minute rows
- Timestamps in `America/New_York` with numeric UTC offsets
- Columns: `ts, open, high, low, close, volume, trades`

It includes three range-eligible first breaks and is intentionally small enough
to clone and load in seconds. The loader derives `symbol`, `session_date`, and
`is_rth`.

## Full data

The full source is the 56 MB NQ continuous 1-minute parquet in the research
workspace:

```text
../../SkyQ_NewLondon/data/nq_1m.parquet
```

That file is excluded from git. It contains 3,350,033 rows from 2017-04-02
through 2026-10-23. Load it with:

```powershell
python scripts/load_data.py `
  --data ..\..\SkyQ_NewLondon\data\nq_1m.parquet
```

## Expected input

Parquet or CSV with:

- a `ts` / `time` column or a datetime index
- `open`, `high`, `low`, `close`
- optional `volume`, `trades`

The loader casts prices to the numeric schema, derives New York local session
dates, marks 09:30–15:59 ET as RTH, and streams the result through `psql \copy`.

## Scope

NQ continuous futures data is not a contract-by-contract roll model. The SQL
project uses it for analytical demonstrations; it does not claim executable
fills or a live edge.
