#!/usr/bin/env python3
"""Check Episode 6 (the movement running) against the Python mirror, and
against SQL Server's Part 1 escapement run.

  python verify_run.py

1. Gearing laws: every map cell and push edge of the six meshes, rebuilt
   with shapely from the mirror's teeth at the arbor positions PostGIS
   used, the same lens clipping, the same refinement.
2. Escapement maps: PostGIS's wheel/fork, jewel/fork, pin and face maps
   against the mirror's clearance_maps().
3. Escapement run: all 30,901 frames of the minute against the mirror's
   solver on the same balance schedule; the first four beats against
   SQL Server's esc.Frame (Part 1).
4. The train: every 50th frame's fourth, third, centre and barrel angles,
   worked back from the escape wheel through the mirror's own laws.
"""
from __future__ import annotations

import math

import numpy as np
import shapely
from shapely import affinity

from movement_export import DSN
from watch_lab import escapement as E
from watch_lab import motion as M
from watch_lab import train as T
from watch_lab.sqlsource import _conn as sql_server

import psycopg

NU, NV, REFINE, ROUNDS = 60, 120, 16, 2


def place(g, deg, at):
    return affinity.affine_transform(affinity.rotate(g, deg, origin=(0, 0)), [1, 0, 0, 1, at[0], at[1]])


def contact_shape(kind, teeth, module, partner):
    if kind == "leaf":
        return T.leaf_outline(teeth, module, 5)
    rho = module * partner / 4.0
    return T.wheel_outline(teeth, module, rho, "cycloidal", 40) if kind == "wheel" else M.gear_outline(teeth, module, rho, 40)


def fmod(x, p):
    return x - p * math.floor(x / p)


def laws(cur):
    print("1. gearing laws (PostGIS / mirror)")
    cur.execute("""SELECT m.mesh_no, m.driver_kind, m.driver_teeth, m.driven_kind, m.driven_teeth, m.module,
                          a.x, a.y, b.x, b.y, sa.spin, sb.spin
                   FROM movement.mesh AS m
                   JOIN movement.arbor AS a ON a.arbor = m.driver_arbor JOIN movement.spin AS sa ON sa.arbor = m.driver_arbor
                   JOIN movement.arbor AS b ON b.arbor = m.driven_arbor JOIN movement.spin AS sb ON sb.arbor = m.driven_arbor
                   ORDER BY m.mesh_no""")
    tables = {}
    for no, dk, dz, nk, nz, mod, dx, dy, nx, ny, sd, sn in cur.fetchall():
        drv, dvn = contact_shape(dk, dz, mod, nz), contact_shape(nk, nz, mod, dz)
        pu, pv = 360.0 / dz, 360.0 / nz
        r_d = max(math.hypot(x, y) for x, y in drv.exterior.coords) + 0.02
        r_n = max(math.hypot(x, y) for x, y in dvn.exterior.coords) + 0.02
        lens = T.circle((dx, dy), r_d, 128).intersection(T.circle((nx, ny), r_n, 128))
        drivers = np.array([place(drv, sd * pu * i / NU, (dx, dy)).intersection(lens) for i in range(NU)])
        drivens = np.array([place(dvn, sn * pv * j / NV, (nx, ny)).intersection(lens) for j in range(NV)])
        clear = ~shapely.intersects(drivers[:, None], drivens[None, :])

        cur.execute("SELECT i, j, clear FROM movement.mesh_map WHERE mesh_no = %s", (no,))
        db = np.zeros((NU, NV), dtype=bool)
        for i, j, c in cur.fetchall():
            db[i, j] = c

        edges = []
        for i in range(NU):
            row = clear[i]
            starts = [j for j in range(NV) if row[j] and not row[j - 1]]
            lo, hi = (starts[0] - 1) * pv / NV, starts[0] * pv / NV
            for _ in range(ROUNDS):
                step = (hi - lo) / REFINE
                for k in range(1, REFINE + 1):
                    v = lo + k * step
                    if not drivers[i].intersects(place(dvn, sn * v, (nx, ny))):
                        lo, hi = v - step, v
                        break
            edges.append(fmod(hi, pv))
        prog = [edges[0]]
        for e in edges[1:]:
            prog.append(prog[-1] + fmod(e - prog[-1] + pv / 2, pv) - pv / 2)
        tables[no] = (pu, pv, prog)

        cur.execute("SELECT prog FROM movement.law WHERE mesh_no = %s", (no,))
        dbprog = cur.fetchone()[0]
        gap = max(abs(a - b) for a, b in zip(prog, dbprog))
        print(f"  mesh {no}: map cells differ {int((clear != db).sum())} / {clear.size}; law worst gap {gap:.2e} deg")
    return tables


def untransmit(table, v):
    pu, pv, p = table
    k = math.floor((v - p[0]) / pv)
    r = v - k * pv
    ext = p + [p[0] + pv]
    i = max(n for n in range(NU) if ext[n] <= r)
    return (i + (r - ext[i]) / (ext[i + 1] - ext[i])) * pu / NU + k * pu


def escapement(cur):
    print("2. escapement maps (PostGIS / mirror)")
    wf, fj, pin, cf = E.clearance_maps()
    cur.execute("SELECT i, j, clear, face FROM movement.esc_wheel_fork")
    db_wf, db_cf = np.zeros_like(wf), np.zeros_like(cf)
    for i, j, c, f in cur.fetchall():
        db_wf[i, j], db_cf[i, j] = c, f
    cur.execute("SELECT b, j, clear FROM movement.esc_jewel_fork")
    db_fj = np.zeros_like(fj)
    for b, j, c in cur.fetchall():
        db_fj[b, j] = c
    cur.execute("SELECT j, clear FROM movement.esc_pin")
    db_pin = np.zeros_like(pin)
    for j, c in cur.fetchall():
        db_pin[j] = c
    for name, a, b in (("wheel x fork", wf, db_wf), ("faces", cf, db_cf), ("jewel x fork", fj, db_fj), ("fork x pins", pin, db_pin)):
        print(f"  {name:<13} cells differ {int((a != b).sum())} / {a.size}")

    print("3. escapement run")
    cur.execute("SELECT count(*) FROM movement.v_beat")
    beats = cur.fetchone()[0]
    frames = E.run(E.beta_schedule(beats=beats), maps=(wf, fj, pin, cf))
    cur.execute("SELECT frame_no, beta, phi, theta, phase FROM movement.esc_frame ORDER BY frame_no")
    db = cur.fetchall()
    same = len(db) == len(frames) and all(
        abs(f.beta - b) < 1e-9 and abs(f.phi - p) < 1e-9 and abs(f.theta - t) < 1e-9 and f.phase == ph
        for f, (_, b, p, t, ph) in zip(frames, db))
    print(f"  {len(db)} frames in PostGIS, {len(frames)} from the mirror: {'identical' if same else 'DIFFERENT'}")

    ss = sql_server().cursor()
    ss.execute("SELECT FrameNo, Beta, Phi, Theta, Phase FROM esc.Frame "
               "WHERE RunId = (SELECT MAX(RunId) FROM esc.Run) ORDER BY FrameNo")
    part1 = ss.fetchall()
    same = all(abs(b - r.Beta) < 1e-9 and abs(p - r.Phi) < 1e-9 and abs(t - r.Theta) < 1e-9 and ph == r.Phase
               for (_, b, p, t, ph), r in zip(db, part1))
    print(f"  first {len(part1)} frames against SQL Server's Part 1 run: {'identical' if same else 'DIFFERENT'}")


def train(cur, tables):
    print("4. the train, worked back from the escape wheel")
    cur.execute("SELECT arbor, spin FROM movement.spin")
    spin = dict(cur.fetchall())
    cur.execute("SELECT frame_no, escape, fourth, third, centre, barrel FROM movement.frame "
                "WHERE frame_no % 50 = 0 ORDER BY frame_no")
    worst = {"fourth": 0.0, "third": 0.0, "centre": 0.0, "barrel": 0.0}
    rows = cur.fetchall()
    for _, esc, fourth, third, centre, barrel in rows:
        p4 = untransmit(tables[4], spin["escape"] * esc)
        p3 = untransmit(tables[3], p4)
        pc = untransmit(tables[2], p3)
        pb = untransmit(tables[1], pc)
        for name, mine, theirs in (("fourth", spin["fourth"] * p4, fourth), ("third", spin["third"] * p3, third),
                                   ("centre", spin["centre"] * pc, centre), ("barrel", spin["barrel"] * pb, barrel)):
            worst[name] = max(worst[name], abs(mine - theirs))
    print(f"  {len(rows)} frames; worst gap (deg): " + ", ".join(f"{k} {v:.1e}" for k, v in worst.items()))
    cur.execute("SELECT f1.escape - f0.escape, f1.fourth - f0.fourth, f1.third - f0.third, f1.centre - f0.centre, "
                "f1.barrel - f0.barrel, f1.minute - f0.minute, f1.hour - f0.hour, f1.t "
                "FROM movement.frame AS f0, movement.frame AS f1 "
                "WHERE f0.frame_no = 0 AND f1.frame_no = (SELECT max(frame_no) FROM movement.frame)")
    e, f, t3, c, b, m, h, secs = cur.fetchone()
    print(f"  after {secs:.0f} s: escape {e:+.6f}, fourth {f:+.6f}, third {t3:+.6f}, centre {c:+.6f}, "
          f"barrel {b:+.6f}, minute wheel {m:+.6f}, hour {h:+.6f} deg")


def main():
    with psycopg.connect(DSN) as conn, conn.cursor() as cur:
        tables = laws(cur)
        escapement(cur)
        train(cur, tables)


if __name__ == "__main__":
    main()
