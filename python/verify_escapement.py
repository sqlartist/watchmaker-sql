#!/usr/bin/env python3
"""Check SQL Server's escapement against the Python mirror.

  python verify_escapement.py

Compares, cell by cell, the three maps (esc.WheelFork Clear and Face,
esc.JewelFork, esc.ForkPos.PinClear), then the latest run frame by frame
(fork, wheel, phase, face) and the per-beat measurements.
"""
from __future__ import annotations

import numpy as np

from watch_lab import escapement as E
from watch_lab.sqlsource import SqlEscapement


def main():
    db = SqlEscapement()
    wf, fj, pin, cf = E.clearance_maps()
    s_clear, s_face = db.wheel_fork()
    s_fj = db.jewel_fork()
    s_pin = db.pin_clear()

    print("maps (cells that differ / total):")
    for name, a, b in (("WheelFork.Clear", wf, s_clear), ("WheelFork.Face", cf, s_face),
                       ("JewelFork.Clear", fj, s_fj), ("ForkPos.PinClear", pin, s_pin)):
        diff = np.argwhere(a != b)
        print(f"  {name:17s} {len(diff):5d} / {a.size}")
        for idx in diff[:5]:
            print("      e.g. at", tuple(int(v) for v in idx), "python", a[tuple(idx)], "sql", b[tuple(idx)])

    run_id = db.latest_run()
    sql = db.frames(run_id)
    py = E.run(maps=(wf, fj, pin, cf))
    print(f"\nrun {run_id}: {len(sql)} SQL frames, {len(py)} Python frames")
    bad = [(a, b) for a, b in zip(sql, py)
           if abs(a["Phi"] - b.phi) > 1e-9 or abs(a["Theta"] - b.theta) > 1e-9
           or a["Phase"] != b.phase or (a["Face"] or None) != b.face]
    print(f"  frames that differ: {len(bad)}")
    for a, b in bad[:5]:
        print("   ", a, "|", b)

    print("\nbeats (SQL Server):")
    for bt in db.beats(run_id):
        print("  ", {k: (float(v) if hasattr(v, "as_tuple") else v) for k, v in bt.items() if k != "RunId"})


if __name__ == "__main__":
    main()
