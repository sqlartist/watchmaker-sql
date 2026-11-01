#!/usr/bin/env python3
"""Check SQL Server's power episode against the Python mirror.

  python verify_power.py

Compares every cell of power.ClickMap, the 200-step click run frame by
frame, every row of power.Fill, and the latest spring run frame by frame.
"""
from __future__ import annotations

import numpy as np

from watch_lab import power as P
from watch_lab.sqlsource import _conn


def main():
    cur = _conn().cursor()

    clear = P.click_map()
    cur.execute("SELECT I, J, Clear FROM power.ClickMap")
    sql = np.zeros_like(clear)
    for i, j, c in cur.fetchall():
        sql[i, j] = bool(c)
    diff = np.argwhere(sql != clear)
    print(f"power.ClickMap: cells that differ {len(diff)} / {clear.size}")
    for idx in diff[:3]:
        print("    e.g.", tuple(int(v) for v in idx), "python", clear[tuple(idx)], "sql", sql[tuple(idx)])

    cur.execute("SELECT MIN(RunId) FROM power.Run WHERE Kind = 'click'")
    run_id = cur.fetchone()[0]
    cur.execute("SELECT FrameNo, RatchetDeg, PawlDeg, Event FROM power.ClickFrame WHERE RunId = ? ORDER BY FrameNo", run_id)
    s_run = cur.fetchall()
    p_run = P.click_run(clear, back_steps=160)
    bad = [(a, b) for a, b in zip(s_run, p_run)
           if abs(a[1] - b[1]) > 1e-9 or abs(a[2] - b[2]) > 1e-9 or a[3] != b[3]]
    print(f"click run {run_id}: {len(s_run)} SQL frames, {len(p_run)} Python frames, differ: {len(bad)}")
    for a, b in bad[:3]:
        print("   ", tuple(a), "|", b)

    cur.execute("SELECT LengthMm, WoundTurns, LetDownTurns, BarrelTurns, Fits FROM power.Fill ORDER BY LengthMm")
    worst = 0.0
    fits_bad = 0
    for length, n_in, n_out, turns, fits in cur.fetchall():
        p_in, p_out, p_turns, p_fits = P.barrel_turns(length)
        worst = max(worst, abs(n_in - p_in), abs(n_out - p_out))
        fits_bad += bool(fits) != p_fits
    print(f"power.Fill: worst gap in turns {worst:.6f}, 'fits' disagreements {fits_bad}")

    cur.execute("SELECT MAX(RunId) FROM power.Run WHERE Kind = 'spring'")
    run_id = cur.fetchone()[0]
    cur.execute("SELECT FrameNo, Wound, ArborDeg, BarrelDeg, InnerTurns, OuterTurns, LengthMm, Hours "
                "FROM power.SpringFrame WHERE RunId = ? ORDER BY FrameNo", run_id)
    s_spr = cur.fetchall()
    p_spr = P.spring_run(frames=(len(s_spr) - 2) // 2)
    gaps = {k: 0.0 for k in ("Wound", "ArborDeg", "BarrelDeg", "InnerTurns", "OuterTurns", "Length", "Hours")}
    for a, b in zip(s_spr, p_spr):
        for k, v in zip(gaps, a[1:]):
            gaps[k] = max(gaps[k], abs(v - b[k]))
    print(f"spring run {run_id}: {len(s_spr)} frames; worst gaps:", {k: f"{v:.2e}" for k, v in gaps.items()})


if __name__ == "__main__":
    main()
