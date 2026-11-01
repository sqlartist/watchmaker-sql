"""Power: the mainspring in its barrel, and the ratchet and click that hold it.

Python mirror of sql/05_power.sql. Same shapes, same grids, same rules.

Units are millimetres; the barrel arbor is at the origin.

Ratchet and click
    A 36-tooth sawtooth ratchet on the barrel arbor, wound anticlockwise.
    The click is a pawl on a pivot, pushed into the teeth by its spring.
    For every ratchet angle (within one tooth) and click angle, one spatial
    question: do they overlap? Then the ratchet is turned a step at a time:
    the click drops as far in as it can (its spring), and if the ratchet
    would hit it, it must be lifted clear - which is only possible if the
    click can rise where it is. Nothing says "one way". The teeth decide.

Mainspring
    A strip L long and T thick between the arbor (radius RA) and the drum
    wall (radius RB). Wound tight round the arbor it makes so many turns;
    lying against the wall, fewer. How many - measured with the length of
    the drawn spiral - and the difference is how far the barrel can turn.
"""
from __future__ import annotations

import math

import numpy as np
import shapely
from shapely import affinity
from shapely.geometry import LineString, Polygon

# ---------------------------------------------------------------- ratchet and click
RATCHET_TEETH = 36
RATCHET_TIP = 4.40
RATCHET_ROOT = 3.95
PAWL_PIVOT = (5.7, -3.4)

NR = 100              # ratchet grid, steps per tooth (0.1 deg)
PAWL_MIN, PAWL_MAX, PAWL_STEP = -14.0, 4.0, 0.05
NC = round((PAWL_MAX - PAWL_MIN) / PAWL_STEP) + 1      # 361


def polar(deg, r, c=(0.0, 0.0)):
    a = math.radians(deg)
    return (c[0] + r * math.cos(a), c[1] + r * math.sin(a))


def circle(c, r, n=48):
    return Polygon([(c[0] + r * math.cos(2 * math.pi * k / n), c[1] + r * math.sin(2 * math.pi * k / n))
                    for k in range(n)])


def ratchet_outline():
    """Sawtooth, walked anticlockwise: up the radial (locking) face, down the long slope."""
    pitch = 360.0 / RATCHET_TEETH
    pts = []
    for k in range(RATCHET_TEETH):
        pts += [polar(k * pitch, RATCHET_ROOT), polar(k * pitch + 0.4, RATCHET_TIP)]
    return Polygon(pts)


def pawl_outline():
    """The click at rest: a head whose tip sits in the gap against a tooth's radial face, an arm, a boss."""
    head = Polygon([polar(-0.6, 4.00), polar(-0.6, 4.62), polar(-1.5, 5.05), polar(-4.6, 4.75), polar(-4.0, 4.30)])
    a, b = polar(-3.0, 4.72), PAWL_PIVOT                # the arm: a bar 0.6 wide, rounded at the head end
    ux, uy = (b[0] - a[0]), (b[1] - a[1])
    n = math.sqrt(ux * ux + uy * uy)
    nx, ny = -uy / n * 0.3, ux / n * 0.3
    arm = Polygon([(a[0] + nx, a[1] + ny), (b[0] + nx, b[1] + ny), (b[0] - nx, b[1] - ny), (a[0] - nx, a[1] - ny)])
    return shapely.union_all([head, arm, circle(a, 0.3, 32), circle(PAWL_PIVOT, 0.6, 32)]).difference(
        circle(PAWL_PIVOT, 0.18, 16))


def ratchet_of(i):
    return 360.0 / RATCHET_TEETH * i / NR


def pawl_of(j):
    return PAWL_MIN + j * PAWL_STEP


def click_map():
    """Clear[i, j]: ratchet turned i/NR of a tooth (anticlockwise), click turned pawl_of(j) deg about its pivot."""
    ratchet = ratchet_outline()
    zone = circle((4.2, -0.5), 2.2, 64)                  # where the two can ever meet
    rats = np.array([affinity.rotate(ratchet, ratchet_of(i), origin=(0, 0)).intersection(zone) for i in range(NR)])
    pawls = np.array([affinity.rotate(pawl_outline(), pawl_of(j), origin=PAWL_PIVOT) for j in range(NC)])
    return ~shapely.intersects(rats[:, None], pawls[None, :])


def _run_top(col, j):
    """Top of the clear run containing j (the click spring pushes the click in, towards higher j)."""
    while j + 1 < NC and col[j + 1]:
        j += 1
    return j


def step(clear, i, j, d):
    """Turn the ratchet one grid step (d = +1 winding, -1 back). Returns (i', j', event) or None if blocked."""
    i2 = (i + d) % NR
    if clear[i2, j]:                                   # the ratchet moves under the click: it drops in
        j2 = _run_top(clear[i2], j)
        return i2, j2, "click" if (j2 - j) * PAWL_STEP > 1.0 else ("drop" if j2 > j else "ride")
    for j2 in range(j - 1, -1, -1):                    # it must be lifted: to the nearest clear angle ...
        if clear[i2, j2]:
            if all(clear[i, k] for k in range(j2, j + 1)):     # ... reachable by rising where it is now
                return i2, _run_top(clear[i2], j2), "lift"
            return None
    return None


def click_run(clear, forward_steps=200, hold=30, back_steps=60):
    """Wind 200 steps (five teeth), hold, then let the spring pull back until the click stops it."""
    i = 0
    j = _run_top(clear[0], round((0.0 - PAWL_MIN) / PAWL_STEP))
    teeth = 0
    out = [(0, 0.0, pawl_of(j), "rest")]
    for _ in range(forward_steps):
        i2, j2, ev = step(clear, i, j, +1)
        teeth += 1 if i2 < i else 0
        i, j = i2, j2
        out.append((len(out), teeth * 360.0 / RATCHET_TEETH + ratchet_of(i), pawl_of(j), ev))
    for _ in range(hold):
        out.append((len(out), out[-1][1], out[-1][2], "hold"))
    for _ in range(back_steps):
        s = step(clear, i, j, -1)
        if s is None:
            out.append((len(out), out[-1][1], out[-1][2], "locked"))
            continue
        i2, j2, ev = s
        teeth -= 1 if i2 > i else 0
        i, j = i2, j2
        out.append((len(out), teeth * 360.0 / RATCHET_TEETH + ratchet_of(i), pawl_of(j), "back"))
    return out


# ---------------------------------------------------------------- mainspring
RB = 5.0              # drum, inner radius
RA = 1.6              # arbor core radius
T = 0.10              # strip thickness
L = 350.0             # strip length
PTS_PER_TURN = 48
FREE_TURNS = 1.25     # the free coil between the two packs spans this many turns
MIN_PACK = 1.0        # turns that always stay on the arbor, and on the wall


def spiral_points(c, r0, dr, a0, turns, direction):
    """Archimedean spiral: radius r0 + dr * s after s turns, angle a0 + direction * 360 s (deg)."""
    n = max(2, math.ceil(turns * PTS_PER_TURN) + 1)
    pts = []
    for k in range(n):
        s = turns * k / (n - 1)
        pts.append(polar(a0 + direction * 360.0 * s, r0 + dr * s, c))
    return pts


def pack_turns(length, inner):
    """How many turns a strip of this length makes, packed coil on coil round the arbor (inner) or
    against the wall: found by measuring the drawn spiral, forty halvings."""
    r0, dr = (RA + T / 2, T) if inner else (RB - T / 2, -T)
    lo, hi = 0.0, length / (2 * math.pi * RA)          # more turns than it could ever make
    for _ in range(40):
        mid = (lo + hi) / 2
        if LineString(spiral_points((0, 0), r0, dr, 0.0, mid, 1)).length >= length:
            hi = mid
        else:
            lo = mid
    return hi


def barrel_turns(length):
    """(turns wound, turns let down, turns the barrel can make, fits?) for a spring of this length."""
    n_in, n_out = pack_turns(length, True), pack_turns(length, False)
    fits = RA + T * n_in + T <= RB and RB - T * n_out - T >= RA
    return n_in, n_out, n_in - n_out, fits


def _pack_len(n, r0, dr):
    return 2 * math.pi * n * (r0 + dr * n / 2)


def _shape_len(n_in, n_out):
    r1 = RA + T / 2 + T * n_in
    r2 = RB - T / 2 - T * n_out
    return _pack_len(n_in, RA + T / 2, T) + _pack_len(n_out, RB - T / 2, -T) + math.pi * FREE_TURNS * (r1 + r2)


def spring_state(wound):
    """Split `wound` turns of spring (pack turns + free coil) between the two packs so the length is L."""
    s = wound - FREE_TURNS
    lo, hi = 0.0, s
    for _ in range(60):                                # more on the arbor = less length for the same turns
        mid = (lo + hi) / 2
        if _shape_len(mid, s - mid) > L:
            lo = mid
        else:
            hi = mid
    return hi, s - hi


def wound_limits():
    """Total turns of the spring when let down (MIN_PACK on the arbor) and fully wound (MIN_PACK on the wall)."""
    def solve(fixed_inner):
        lo, hi = 0.0, (RB - RA) / T - MIN_PACK - FREE_TURNS      # no more coils than fit across the gap
        for _ in range(60):
            mid = (lo + hi) / 2
            n_in, n_out = (MIN_PACK, mid) if fixed_inner else (mid, MIN_PACK)
            if _shape_len(n_in, n_out) > L:
                hi = mid
            else:
                lo = mid
        return hi
    let_down = MIN_PACK + solve(True) + FREE_TURNS
    wound = solve(False) + MIN_PACK + FREE_TURNS
    return let_down, wound


def spring_line(arbor_deg, wound):
    """The spring as one line: inner pack from the arbor hook, the free coil, the outer pack to the wall.
    It winds outwards clockwise, so winding the arbor anticlockwise tightens it."""
    n_in, n_out = spring_state(wound)
    r1 = RA + T / 2 + T * n_in
    r2 = RB - T / 2 - T * n_out
    a = arbor_deg
    pts = spiral_points((0, 0), RA + T / 2, T, a, n_in, -1)
    a -= 360.0 * n_in
    free = spiral_points((0, 0), r1, (r2 - r1) / FREE_TURNS, a, FREE_TURNS, -1)
    a -= 360.0 * FREE_TURNS
    outer = spiral_points((0, 0), r2, T, a, n_out, -1)
    return LineString(pts + free[1:] + outer[1:])


def spring_run(frames=120, hours_per_turn=80 / 10):
    """Wind it from let down to fully wound (the arbor turns, the barrel is held by the train), then let
    it run down (the barrel turns, the arbor is held by the click). One row per frame."""
    w0, w1 = wound_limits()
    out = []
    for phase in ("winding", "running"):
        for f in range(frames + 1):
            frac = f / frames
            wound = w0 + (w1 - w0) * frac if phase == "winding" else w1 - (w1 - w0) * frac
            arbor = 360.0 * (wound - w0) if phase == "winding" else 360.0 * (w1 - w0)
            barrel = 0.0 if phase == "winding" else 360.0 * (w1 - wound)
            n_in, n_out = spring_state(wound)
            out.append({"Phase": phase, "FrameNo": len(out), "Wound": wound, "ArborDeg": arbor, "BarrelDeg": barrel,
                        "InnerTurns": n_in, "OuterTurns": n_out, "Hours": (wound - w0) * hours_per_turn,
                        "Length": spring_line(arbor, wound).length})
    return out
