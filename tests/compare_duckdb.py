# /// script
# requires-python = ">=3.11"
# dependencies = ["duckdb"]
# ///
"""Compare what the mdbtools executables read from an Access file with a DuckDB conversion of the same file.

  uv run --no-project --with duckdb python -I tests/compare_duckdb.py <dir with mdb-*.exe> <copy.accdb> <reference.duckdb> [--values]

Always: table list (mdb-tables) and row count of every table (mdb-count).
--values: also every cell of every table (mdb-export CSV), rows matched as a multiset because the
physical row order of mdbtools is not the order of the reference. Exit code 1 on any difference.
Open a COPY of the Access file, never the original.
"""

import csv
import io
import math
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import duckdb

NULL = "\x01NULL\x01"  # cannot occur in real text; tells NULL from the empty string in the CSV
TS = "%Y-%m-%d %H:%M:%S"


def run(exe: Path, *args: str) -> str:
    done = subprocess.run([str(exe), *args], capture_output=True, check=True)
    return done.stdout.decode("utf-8")  # strict: invalid UTF-8 from the tools is a failure


def norm_ref(value):
    if value is None or (isinstance(value, float) and math.isnan(value)):
        return None  # the reference went through pandas, which stores NULL numbers as NaN
    if isinstance(value, bool):
        return float(value)
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, datetime):
        return value.strftime(TS)
    return value


def norm_mdb(text: str, ref_type: str):
    if text == NULL:
        return None
    if ref_type in ("DOUBLE", "BIGINT", "INTEGER", "BOOLEAN"):
        return float(text)
    return text


def key(row):
    # 6 significant digits: Access "single" columns print fewer digits than the reference double
    return tuple("" if v is None else f"{v:.6g}" if isinstance(v, float) else v for v in row)


def same(a, b) -> bool:
    if isinstance(a, float) and isinstance(b, float):
        return math.isclose(a, b, rel_tol=1e-6, abs_tol=1e-9)
    return a == b


def compare_values(bindir: Path, accdb: str, con, table: str) -> list[str]:
    cols = con.execute(
        "select column_name, data_type from information_schema.columns where table_name = ? order by ordinal_position",
        [table],
    ).fetchall()
    text = run(bindir / "mdb-export.exe", "-0", NULL, "-T", TS, "-D", TS, accdb, table)
    rows = list(csv.reader(io.StringIO(text, newline="")))
    header, rows = rows[0], rows[1:]
    if header != [c[0] for c in cols]:
        return [f"{table}: columns differ: mdb={header} ref={[c[0] for c in cols]}"]
    types = [c[1] for c in cols]
    try:
        mdb = sorted(([norm_mdb(v, t) for v, t in zip(r, types, strict=True)] for r in rows), key=key)
    except ValueError as exc:
        return [f"{table}: cannot parse export: {exc}"]
    ref = sorted(([norm_ref(v) for v in r] for r in con.execute(f'select * from "{table}"').fetchall()), key=key)
    if len(mdb) != len(ref):
        return [f"{table}: exported rows {len(mdb)} != reference {len(ref)}"]
    bad = [
        (header[i], a[i], b[i])
        for a, b in zip(mdb, ref)
        for i in range(len(header))
        if not same(a[i], b[i])
    ]
    if bad:
        col, got, want = bad[0]
        return [f"{table}: {len(bad)} cells differ; first: column {col} mdb={got!r} ref={want!r}"]
    return []


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--values"]
    if len(args) != 3:
        print(__doc__)
        return 2
    bindir, accdb, ref_path = Path(args[0]), args[1], args[2]
    con = duckdb.connect(ref_path, read_only=True)
    ref_tables = sorted(r[0] for r in con.execute("select table_name from information_schema.tables").fetchall())
    mdb_tables = sorted(run(bindir / "mdb-tables.exe", "-1", accdb).splitlines())
    problems = []
    if mdb_tables != ref_tables:
        problems.append(
            f"table list differs: only mdb={sorted(set(mdb_tables) - set(ref_tables))} "
            f"only ref={sorted(set(ref_tables) - set(mdb_tables))}"
        )
    rows_total = cells_checked = 0
    for table in sorted(set(mdb_tables) & set(ref_tables)):
        got = int(run(bindir / "mdb-count.exe", accdb, table))
        want = con.execute(f'select count(*) from "{table}"').fetchall()[0][0]
        rows_total += got
        if got != want:
            problems.append(f"{table}: mdb-count={got} reference={want}")
        elif "--values" in sys.argv:
            found = compare_values(bindir, accdb, con, table)
            problems += found
            if not found:
                cells_checked += got * len(con.execute(f'select * from "{table}" limit 0').description)
    print(f"{Path(accdb).name}: {len(mdb_tables)} tables (reference {len(ref_tables)}), {rows_total} rows counted")
    if "--values" in sys.argv:
        print(f"cells compared equal: {cells_checked}")
    for problem in problems:
        print(f"  PROBLEM {problem}")
    print("OK" if not problems else f"{len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
