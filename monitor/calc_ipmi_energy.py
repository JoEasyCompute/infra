#!/usr/bin/env python3
"""
calc_ipmi_energy.py

Compute total energy consumption (kWh) from 1-minute IPMI power readings in Watts.

Key behaviours:
- Uses only the time window covered by the file: [first_valid_minute .. last_valid_minute]
- Normalises timestamps to minute buckets (floor to minute)
- If multiple samples land in the same minute, it averages them
- Builds a complete minute timeline inside that window and reports gaps
- Fills only INTERNAL gaps (between start and end) using a chosen policy

Fill policies:
  - locf   : forward-fill last known power (default)
  - interp : time interpolation, then forward-fill leading NaNs
  - none   : drop missing minutes (will undercount by construction)

Examples:
  python3 calc_ipmi_energy.py /mnt/data/power_212.csv
  python3 calc_ipmi_energy.py /mnt/data/power_212.csv --fill interp
  python3 calc_ipmi_energy.py /mnt/data/power_212.csv --powercol power
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from typing import Optional, Dict, List, Tuple

import pandas as pd


PREFERRED_POWER_COLS = [
    "watt", "watts", "power", "pwr", "power_w", "ipmi_watts",
    # some exporters mislabel watts as kwh/kw; we still prefer these over random numerics
    "kwh", "kw",
]

EXCLUDE_COLS = {
    "ipmi_ip", "host", "hostname", "node", "machine", "serial", "model",
    "site", "rack", "row",
}


@dataclass
class GapReport:
    gap_count: int
    minutes_missing: int
    missing_pct: float
    bucket_counts: Dict[str, int]
    bucket_minutes: Dict[str, int]
    largest_gaps: List[Tuple[pd.Timestamp, pd.Timestamp, int]]  # (start, end, minutes)


@dataclass
class Result:
    start: pd.Timestamp
    end: pd.Timestamp
    minutes_total: int
    powercol: str
    avg_watts: float
    total_kwh: float
    gap_report: GapReport


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Calculate total kWh from 1-minute IPMI power readings.")
    p.add_argument("csv", help="Input CSV path.")
    p.add_argument("--timecol", default="_time", help="Timestamp column name (default: _time).")
    p.add_argument(
        "--powercol",
        default=None,
        help="Power column name in Watts. If omitted, the script will auto-detect.",
    )
    p.add_argument(
        "--fill",
        choices=["locf", "interp", "none"],
        default="locf",
        help="How to handle missing minutes: locf (forward-fill), interp (time interpolation), none (drop). Default: locf",
    )
    p.add_argument("--tz", default="UTC", help="Timezone to convert timestamps to (default: UTC).")
    p.add_argument(
        "--top-gaps",
        type=int,
        default=10,
        help="How many largest gaps to print (default: 10).",
    )
    return p.parse_args()


def detect_power_col(df: pd.DataFrame, timecol: str) -> str:
    cols = [c for c in df.columns if c != timecol]
    if not cols:
        raise ValueError("No columns available besides the time column; cannot detect power column.")

    # 1) Exact match on preferred names (case-insensitive)
    lc = {c: c.lower() for c in cols}
    for pref in PREFERRED_POWER_COLS:
        for c in cols:
            if lc[c] == pref:
                return c

    # 2) Heuristic: first "mostly numeric" column excluding obvious metadata
    candidates = []
    for c in cols:
        if lc[c] in EXCLUDE_COLS:
            continue
        s = pd.to_numeric(df[c], errors="coerce")
        non_na = int(s.notna().sum())
        if non_na == 0:
            continue
        candidates.append((non_na, c))

    if not candidates:
        raise ValueError(
            "Unable to auto-detect a numeric power column. "
            "Specify --powercol explicitly."
        )

    # choose the column with the most numeric values
    candidates.sort(reverse=True)
    return candidates[0][1]


def build_gap_report(full_idx: pd.DatetimeIndex, series: pd.Series, top_n: int) -> GapReport:
    missing_mask = series.isna()
    minutes_total = len(full_idx)
    minutes_missing = int(missing_mask.sum())
    missing_pct = (minutes_missing / minutes_total * 100.0) if minutes_total else 0.0

    # Identify missing runs (gaps)
    gaps: List[Tuple[pd.Timestamp, pd.Timestamp, int]] = []
    mm = missing_mask.to_numpy()
    i = 0
    while i < len(mm):
        if mm[i]:
            j = i
            while j < len(mm) and mm[j]:
                j += 1
            gaps.append((full_idx[i], full_idx[j - 1], j - i))
            i = j
        else:
            i += 1

    buckets = [
        ("1-2", 1, 2),
        ("3-15", 3, 15),
        ("16-120", 16, 120),
        (">120", 121, 10**9),
    ]
    bucket_counts = {k: 0 for k, _, _ in buckets}
    bucket_minutes = {k: 0 for k, _, _ in buckets}

    for _, __, length in gaps:
        for k, a, b in buckets:
            if a <= length <= b:
                bucket_counts[k] += 1
                bucket_minutes[k] += length
                break

    gaps_sorted = sorted(gaps, key=lambda x: x[2], reverse=True)[:top_n]

    return GapReport(
        gap_count=len(gaps),
        minutes_missing=minutes_missing,
        missing_pct=missing_pct,
        bucket_counts=bucket_counts,
        bucket_minutes=bucket_minutes,
        largest_gaps=gaps_sorted,
    )


def compute_energy(df: pd.DataFrame, timecol: str, powercol: Optional[str], fill: str, tz: str, top_gaps: int) -> Result:
    if timecol not in df.columns:
        raise ValueError(f"Missing time column '{timecol}'. Columns: {list(df.columns)}")

    if powercol is None:
        powercol = detect_power_col(df, timecol)
    else:
        if powercol not in df.columns:
            raise ValueError(f"Missing power column '{powercol}'. Columns: {list(df.columns)}")

    # Parse timestamps (handles 'Z'), convert to requested tz
    t = pd.to_datetime(df[timecol], utc=True, errors="coerce")
    if t.isna().all():
        raise ValueError("All timestamps failed to parse. Check the timestamp format and --timecol.")

    df = df.copy()
    df["_ts"] = t.dt.tz_convert(tz)

    # Parse power values
    df["_p"] = pd.to_numeric(df[powercol], errors="coerce")
    df = df.dropna(subset=["_ts", "_p"]).sort_values("_ts")
    if df.empty:
        raise ValueError("No valid rows after parsing timestamps and power values.")

    # Normalise to minute buckets. If multiple readings per minute, average them.
    df["_minute"] = df["_ts"].dt.floor("min")
    per_min = df.groupby("_minute")["_p"].mean().sort_index()

    start = per_min.index.min()
    end = per_min.index.max()

    # Complete minute timeline INSIDE [start..end]
    full_idx = pd.date_range(start=start, end=end, freq="1min", tz=tz)
    series = per_min.reindex(full_idx)

    gap_report = build_gap_report(full_idx, series, top_n=top_gaps)

    # Fill policy (internal gaps only)
    if fill == "locf":
        filled = series.ffill()
    elif fill == "interp":
        filled = series.interpolate(method="time").ffill()
    else:  # "none"
        filled = series.dropna()

    if filled.empty:
        raise ValueError("No data left after applying the selected fill policy.")

    # Energy: sum(W)/60000 = kWh, because each sample represents 1 minute
    total_kwh = float((filled / 60000.0).sum())
    avg_watts = float(filled.mean())

    return Result(
        start=start,
        end=end,
        minutes_total=len(full_idx),
        powercol=powercol,
        avg_watts=avg_watts,
        total_kwh=total_kwh,
        gap_report=gap_report,
    )


def main() -> int:
    args = parse_args()

    try:
        df = pd.read_csv(args.csv)
        res = compute_energy(df, args.timecol, args.powercol, args.fill, args.tz, args.top_gaps)
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2

    duration_hours = res.minutes_total / 60.0

    print("IPMI Energy Summary")
    print("-------------------")
    print(f"File:               {args.csv}")
    print(f"Detected power col:  {res.powercol}  (assumed Watts)")
    print(f"Period:             {res.start.isoformat()}  ->  {res.end.isoformat()}")
    print(f"Duration:           {duration_hours:.2f} hours ({res.minutes_total} minutes)")
    print(f"Fill policy:        {args.fill}")
    print("")
    print("Data Quality (gaps inside measured window)")
    print("-----------------------------------------")
    gr = res.gap_report
    print(f"Missing minutes:    {gr.minutes_missing} / {res.minutes_total} ({gr.missing_pct:.2f}%)")
    print(f"Gap count:          {gr.gap_count}")
    print("Gap buckets (count / minutes):")
    for k in ["1-2", "3-15", "16-120", ">120"]:
        print(f"  {k:>6}:          {gr.bucket_counts[k]:>6} / {gr.bucket_minutes[k]:>6}")

    if gr.largest_gaps:
        print("")
        print(f"Largest gaps (top {len(gr.largest_gaps)}):")
        for s, e, m in gr.largest_gaps:
            print(f"  {s.isoformat()} -> {e.isoformat()}   ({m} min)")

    print("")
    print("Energy Result")
    print("-------------")
    print(f"Average power:      {res.avg_watts:.2f} W")
    print(f"Total energy:       {res.total_kwh:.6f} kWh")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
