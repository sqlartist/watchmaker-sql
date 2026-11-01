#!/usr/bin/env python3
"""Check SQL Server's going train against the Python mirror.

  python verify_train.py

Compares every cell of train.MeshMap, every push edge in train.Edge, and
the latest cycloidal run frame by frame.
"""
from __future__ import annotations

import numpy as np

from watch_lab import train as T
from watch_lab.sqlsource import _conn


def main():
    cur = _conn().cursor()
    worst_edge = 0.0
    for m in T.MESHES:
        pv = 360.0 / m.leaves
        for prof in ("cycloidal", "straight"):
            cur.execute("SELECT I, J, Clear FROM train.MeshMap WHERE MeshNo = ? AND Profile = ?", m.no, prof)
            sql = np.zeros((T.NU, T.NV), dtype=bool)
            for i, j, c in cur.fetchall():
                sql[i, j] = bool(c)
            py, _, _ = T.mesh_map(m, prof)
            diff = np.argwhere(sql != py)
            line = f"mesh {m.no} {prof:9s} map cells differ: {len(diff):4d} / {sql.size}"
            try:
                _, e = T.push_edges(m, prof)
                cur.execute("SELECT I, EdgeDeg FROM train.Edge WHERE MeshNo = ? AND Profile = ? ORDER BY I", m.no, prof)
                se = [r[1] for r in cur.fetchall()]
                d = [min(abs(a - b), pv - abs(a - b)) for a, b in zip(e, se)]
                worst_edge = max(worst_edge, max(d))
                line += f"   push edge: worst gap {max(d):.6f} deg, rows off by > 0.002 deg: {sum(x > 0.002 for x in d)}"
            except RuntimeError as ex:
                cur.execute("SELECT COUNT(*) FROM train.Edge WHERE MeshNo = ? AND Profile = ? AND Runs <> 1", m.no, prof)
                line += f"   python: jams; sql: {cur.fetchone()[0]} jammed rows"
            print(line)
            for idx in diff[:3]:
                print("      e.g. cell", tuple(int(v) for v in idx), "python", py[tuple(idx)], "sql", sql[tuple(idx)])

    cur.execute("SELECT MAX(RunId) FROM train.Run WHERE Profile = 'cycloidal'")
    run_id = cur.fetchone()[0]
    cur.execute("SELECT FrameNo, CentreDeg, ThirdDeg, FourthDeg, EscapeDeg FROM train.Frame WHERE RunId = ? ORDER BY FrameNo",
                run_id)
    sql = cur.fetchall()
    py = T.run(T.train_tables("cycloidal"), frames=len(sql))
    gaps = {a: max(abs(s[k + 1] - p[a]) for s, p in zip(sql, py)) for k, a in enumerate(("centre", "third", "fourth", "escape"))}
    print(f"\nrun {run_id}: {len(sql)} frames; worst gap per arbor (deg):",
          {a: round(g, 5) for a, g in gaps.items()})


if __name__ == "__main__":
    main()
