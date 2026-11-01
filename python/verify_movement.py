#!/usr/bin/env python3
"""Check the PostGIS movement (Part 2).

  python verify_movement.py

1. Outlines: every toothed part, the escapement and the click, rebuilt by
   the Python mirror (which matches SQL Server, Part 1) and compared with
   what PostGIS built: vertex counts and the worst distance between them.
2. Layout: the arbor positions, recomputed from the same bearings.
3. Solids: watertight, and volume = area x height, for every piece.
4. Take-apart: the database's rounds, recomputed here without its help.
   Same-axis pieces: the 2D overlap and an interval test, with shapely.
   The stem across the vertical parts: a prism along x crossing a prism
   along z overlaps it exactly where the stem's cross-section, cut to the
   other part's height band, spans a y range that the other part's
   profile covers beyond the stem's end. A different route to the answer
   PostGIS got from ST_3DIntersects.
"""
from __future__ import annotations

import math
from collections import defaultdict

import psycopg
import shapely
from shapely.geometry import box

from movement_export import DSN
from watch_lab import escapement as E
from watch_lab import motion as M
from watch_lab import power as W
from watch_lab import train as T


def geom(cur, sql, *args):
    cur.execute(f"SELECT ST_AsBinary(({sql}))", args)
    return shapely.from_wkb(bytes(cur.fetchone()[0]))


def compare(name, py, pg):
    n_py, n_pg = shapely.get_num_coordinates(py), shapely.get_num_coordinates(pg)
    gap = shapely.hausdorff_distance(py, pg)
    print(f"  {name:<34} vertices {n_pg:>5} / {n_py:<5} worst gap {gap:.2e} mm")
    return gap


def outlines(cur):
    print("1. outlines (PostGIS / Python mirror)")
    worst = 0.0
    for z, m, rho in [(80, 0.14, 0.35), (80, 0.13, 0.325), (75, 0.11, 0.275), (80, 0.08, 0.16)]:
        worst = max(worst, compare(f"wheel {z} m{m}", T.wheel_outline(z, m, rho, "cycloidal", 6),
                                   geom(cur, "movement.gear(%s, %s, %s, 'wheel', 6)", z, m, rho)))
    for n, m in [(10, 0.14), (10, 0.13), (10, 0.11), (8, 0.08)]:
        worst = max(worst, compare(f"pinion {n} m{m}", T.leaf_outline(n, m, 20),
                                   geom(cur, "movement.pinion(%s, %s, 20)", n, m)))
    for z, m, rho in [(12, 0.125, 1.125), (36, 0.125, 0.375), (10, 0.12, 1.2), (40, 0.12, 0.3)]:
        worst = max(worst, compare(f"motion gear {z} m{m}", M.gear_outline(z, m, rho, 6),
                                   geom(cur, "movement.gear(%s, %s, %s, 'motion', 6)", z, m, rho)))
    worst = max(worst, compare("escape wheel", E.wheel_outline(), geom(cur, "movement.escape_wheel()")))
    worst = max(worst, compare("entry stone", E.stones()[0], geom(cur, "movement.stone(56.5)")))
    worst = max(worst, compare("exit stone", E.stones()[1], geom(cur, "movement.stone(116.5)")))
    worst = max(worst, compare("lever", E.lever(), geom(cur, "movement.lever()")))
    worst = max(worst, compare("pallet body", E.pallet_body(), geom(cur, "movement.pallet_body()")))
    worst = max(worst, compare("ratchet", W.ratchet_outline(), geom(cur, "movement.ratchet()")))
    worst = max(worst, compare("click", W.pawl_outline(), geom(cur, "movement.click()")))
    w0, w1 = W.wound_limits()
    cur.execute("SELECT let_down, wound FROM movement.spring_limits()")
    p0, p1 = cur.fetchone()
    print(f"  {'mainspring limits (turns)':<34} {p0:.9f}, {p1:.9f} / {w0:.9f}, {w1:.9f}")
    worst = max(worst, compare("mainspring, half wound", W.spring_line(0.0, (w0 + w1) / 2),
                               geom(cur, "movement.spring_line(0, %s)", (p0 + p1) / 2)))
    print(f"  worst of all: {worst:.2e} mm")


def layout(cur):
    print("2. arbor positions")
    cur.execute("SELECT arbor, from_arbor, bearing, x, y FROM movement.arbor")
    rows = {a: (f, b, x, y) for a, f, b, x, y in cur.fetchall()}
    pitch = {(m.wheel_arbor, m.pinion_arbor): m.module * (m.teeth + m.leaves) / 2 for m in T.MESHES}
    pitch[("barrel", "centre")] = 0.14 * (80 + 10) / 2
    pitch[("centre", "minute")] = 0.125 * (12 + 36) / 2
    pitch[("minute", "hour")] = 0.12 * (10 + 40) / 2
    pitch[("escape", "pallet")] = 0.22 * E.D
    pitch[("pallet", "balance")] = 0.22 * E.LEVER
    pitch[("barrel", "click")] = math.hypot(*W.PAWL_PIVOT)
    pos = {"centre": (0.0, 0.0)}
    while len(pos) < len(rows):
        for a, (f, b, _, _) in rows.items():
            if a not in pos and f in pos:
                d = pitch.get((f, a)) or pitch.get((a, f))
                pos[a] = (pos[f][0] + d * math.cos(math.radians(b)), pos[f][1] + d * math.sin(math.radians(b)))
    gap = max(math.dist(pos[a], (r[2], r[3])) for a, r in rows.items())
    print(f"  {len(rows)} arbors, worst gap {gap:.2e} mm; hour wheel off centre by {math.dist(pos['hour'], (0, 0)):.2e} mm")


def solids(cur):
    print("3. solids")
    cur.execute("SELECT count(*), sum(triangles), count(*) FILTER (WHERE open_edges > 0), "
                "max(abs(volume_mm3 - area_x_height)), sum(volume_mm3) FROM movement.v_solid")
    n, tri, leaky, err, vol = cur.fetchone()
    print(f"  {n} pieces, {tri:,} triangles, {leaky} not watertight, "
          f"worst |volume - area x height| {err:.1e} mm3, total {vol:.1f} mm3")
    cur.execute("SELECT count(*) FROM movement.clashes()")
    print(f"  pieces sharing space: {cur.fetchone()[0]}")


def take_apart(cur):
    print("4. take-apart, recomputed")
    cur.execute("""SELECT pc.part, p.axis, p.is_base, pc.z0, pc.z1, ST_AsBinary(pc.world)
                   FROM movement.piece AS pc JOIN movement.part AS p ON p.part = pc.part""")
    pieces = defaultdict(list)
    info = {}
    for part, axis, base, z0, z1, wkb in cur.fetchall():
        pieces[part].append((z0, z1, shapely.from_wkb(bytes(wkb))))
        info[part] = (axis, base)
    way = {p: 1 if info[p][0] == "x" else (-1 if (min(a for a, _, _ in ps) + max(b for _, b, _ in ps)) / 2 < 0.6 else 1)
           for p, ps in pieces.items()}

    def hits(mover, other):
        s, ax_m, ax_o = way[mover], info[mover][0], info[other][0]
        for a0, a1, ag in pieces[mover]:
            for q0, q1, qg in pieces[other]:
                if ax_m == ax_o:
                    on_way = q0 < a1 - 1e-9 if s < 0 else q1 > a0 + 1e-9
                    if on_way and ag.intersection(qg).area > 1e-12:
                        return True
                elif ax_m == "x":                       # the stem (profile in y z) sliding out to +x
                    band = ag.intersection(box(-1e3, q0, 1e3, q1))
                    if band.area > 1e-12:
                        y0, _, y1, _ = band.bounds
                        if qg.intersection(box(a0, y0, 1e3, y1)).area > 1e-12:
                            return True
                else:                                   # a vertical part sliding past the stem
                    lo, hi = (a0 - 1e3, a1) if s < 0 else (a0, a1 + 1e3)
                    band = qg.intersection(box(-1e3, lo, 1e3, hi))
                    if band.area > 1e-12:
                        y0, _, y1, _ = band.bounds
                        if ag.intersection(box(q0, y0, q1, y1)).area > 1e-12:
                            return True
        return False

    gone, rounds = set(), []
    while True:
        left = [p for p in pieces if not info[p][1] and p not in gone]
        free = [p for p in left if not any(hits(p, q) for q in pieces if q != p and q not in gone)]
        if not free:
            break
        rounds.append(sorted(free))
        gone.update(free)

    cur.execute("SELECT round, part FROM movement.removal")
    db = defaultdict(list)
    for r, p in cur.fetchall():
        db[r].append(p)
    same = [sorted(db[r]) for r in sorted(db)] == rounds
    print(f"  {len(rounds)} rounds here, {len(db)} in the database: "
          f"{'the same parts in the same rounds' if same else 'DIFFERENT'}")
    stuck = [p for p in pieces if not info[p][1] and p not in gone]
    if stuck:
        print("  stuck:", stuck)


def main():
    with psycopg.connect(DSN) as conn, conn.cursor() as cur:
        outlines(cur)
        layout(cur)
        solids(cur)
        take_apart(cur)


if __name__ == "__main__":
    main()
