#!/usr/bin/env python3
"""Check SQL Server's motion works against the Python mirror.

  python verify_motion.py

Compares where the arbors went, every cell of motion.MeshMap, every push
edge in motion.Edge, and the latest twelve-hour run frame by frame.
"""
from __future__ import annotations

import math

import numpy as np

from watch_lab import motion as M
from watch_lab.sqlsource import _conn


def main():
    cur = _conn().cursor()

    cur.execute("SELECT Arbor, X, Y FROM motion.Arbor")
    pos = M.arbor_positions()
    print("arbors, worst gap (mm):", max(math.dist((x, y), pos[a]) for a, x, y in cur.fetchall()))

    for m in M.MESHES:
        pv = 360.0 / m.driven_teeth
        cur.execute("SELECT I, J, Clear FROM motion.MeshMap WHERE MeshNo = ?", m.no)
        sql = np.zeros((M.NU, M.NV), dtype=bool)
        for i, j, c in cur.fetchall():
            sql[i, j] = bool(c)
        py, e = M.push_edges(m)
        cur.execute("SELECT I, EdgeDeg FROM motion.Edge WHERE MeshNo = ? ORDER BY I", m.no)
        se = [r[1] for r in cur.fetchall()]
        gaps = [min(abs(a - b), pv - abs(a - b)) for a, b in zip(e, se)]
        print(f"mesh {m.no}: map cells differ {int((sql != py).sum())} / {sql.size}; "
              f"push edge worst gap {max(gaps):.6f} deg")

    cur.execute("SELECT MAX(RunId) FROM motion.Run")
    run_id = cur.fetchone()[0]
    cur.execute("SELECT FrameNo, CentreDeg, MinuteDeg, HourDeg FROM motion.Frame WHERE RunId = ? ORDER BY FrameNo",
                run_id)
    sql = cur.fetchall()
    py = M.run(M.tables(), frames=len(sql))
    gaps = {a: max(abs(s[k + 1] - p[a]) for s, p in zip(sql, py)) for k, a in enumerate(("centre", "minute", "hour"))}
    print(f"run {run_id}: {len(sql)} frames; worst gap per arbor (deg):", {a: f"{g:.2e}" for a, g in gaps.items()})


if __name__ == "__main__":
    main()
