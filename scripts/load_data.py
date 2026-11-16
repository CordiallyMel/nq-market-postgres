"""Load the NQ 1-minute parquet (or the committed sample CSV) into Postgres.

The loader deliberately uses psql's client-side ``\\copy`` instead of a Python
driver.  That keeps the project runnable with only pandas/pyarrow plus a normal
PostgreSQL installation.  The full parquet is not committed; see data/README.md.

Example:
    python scripts/load_data.py --data data/sample_nq_1m.csv
    python scripts/load_data.py --data ../SkyQ_NewLondon/data/nq_1m.parquet
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PSQL = Path(r"C:\Program Files\PostgreSQL\18\bin\psql.exe")
DEFAULT_DSN = "postgresql://postgres@127.0.0.1:55433/nq_research"
COLUMNS = [
    "symbol",
    "ts",
    "open",
    "high",
    "low",
    "close",
    "volume",
    "trades",
    "session_date",
    "is_rth",
]


def normalize(frame: pd.DataFrame, symbol: str) -> pd.DataFrame:
    data = frame.copy()
    if "ts" not in data.columns:
        data = data.reset_index().rename(columns={data.index.name or "index": "ts"})
    data["ts"] = pd.to_datetime(data["ts"], utc=True).dt.tz_convert("America/New_York")
    data["session_date"] = data["ts"].dt.strftime("%Y-%m-%d")
    local_time = data["ts"].dt.time
    data["is_rth"] = [
        (t.hour, t.minute) >= (9, 30) and (t.hour, t.minute) < (16, 0)
        for t in local_time
    ]
    data["symbol"] = symbol
    if "volume" not in data.columns:
        data["volume"] = 0
    data["volume"] = data["volume"].fillna(0).astype("int64")
    if "trades" not in data.columns:
        data["trades"] = 0
    data["trades"] = data["trades"].fillna(0).astype("int64")
    data["is_rth"] = data["is_rth"].map({True: "true", False: "false"})
    return data[COLUMNS]


def run_psql(psql: Path, dsn: str, *args: str) -> None:
    command = [str(psql), dsn, "-v", "ON_ERROR_STOP=1", *args]
    result = subprocess.run(command, text=True, capture_output=True)
    if result.returncode != 0:
        raise SystemExit(
            "psql failed:\n"
            + " ".join(command)
            + "\nstdout:\n"
            + result.stdout
            + "\nstderr:\n"
            + result.stderr
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--data",
        type=Path,
        default=ROOT / "data" / "sample_nq_1m.csv",
        help="Parquet or CSV with a time/ts column and OHLCV columns",
    )
    parser.add_argument(
        "--dsn",
        default=os.environ.get("DATABASE_URL", DEFAULT_DSN),
        help="PostgreSQL connection URI",
    )
    parser.add_argument(
        "--psql",
        type=Path,
        default=Path(os.environ.get("PSQL", DEFAULT_PSQL)),
        help="Path to psql",
    )
    parser.add_argument("--symbol", default="NQ")
    parser.add_argument("--keep-csv", action="store_true")
    args = parser.parse_args()

    if not args.data.exists():
        raise SystemExit(f"data file not found: {args.data}")
    psql = args.psql
    if not psql.exists():
        found = shutil.which("psql")
        if not found:
            raise SystemExit(
                "psql not found. Pass --psql or set PSQL to the PostgreSQL bin path."
            )
        psql = Path(found)

    if args.data.suffix.lower() == ".parquet":
        frame = pd.read_parquet(args.data)
    else:
        frame = pd.read_csv(args.data)
    data = normalize(frame, args.symbol)
    print(f"Prepared {len(data):,} rows from {args.data}")

    temp_path: Path | None = None
    if not args.keep_csv:
        handle = tempfile.NamedTemporaryFile(
            prefix="nq_load_", suffix=".csv", delete=False, dir=ROOT
        )
        temp_path = Path(handle.name)
        handle.close()
    else:
        temp_path = ROOT / "data" / "nq_load.csv"

    try:
        data.to_csv(temp_path, index=False)
        print(f"CSV: {temp_path} ({temp_path.stat().st_size / 1_000_000:.1f} MB)")

        schema = ROOT / "sql" / "01_schema.sql"
        run_psql(psql, args.dsn, "-f", str(schema))
        copy_command = (
            "\\copy nq.bars_1m (symbol, ts, open, high, low, close, volume, "
            "trades, session_date, is_rth) FROM '"
            + temp_path.as_posix()
            + "' WITH (FORMAT csv, HEADER true)"
        )
        run_psql(psql, args.dsn, "-c", copy_command)
        run_psql(psql, args.dsn, "-c", "ANALYZE nq.bars_1m;")
        views = ROOT / "sql" / "02_views.sql"
        print("Building materialized analytical views...")
        run_psql(psql, args.dsn, "-f", str(views))
        run_psql(
            psql,
            args.dsn,
            "-c",
            "SELECT count(*) AS rows, min(session_date) AS first_day, "
            "max(session_date) AS last_day FROM nq.bars_1m;",
        )
    finally:
        if temp_path is not None and not args.keep_csv:
            temp_path.unlink(missing_ok=True)

    print("Load complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
