"""The going train: centre wheel -> third -> fourth -> escape pinion.

Python mirror of sql/04_train.sql. Same tooth shapes, same grids, same
edge search, so the SQL Server run can be checked against it.

Units are millimetres. Each wheel drives the next arbor's pinion:

    centre wheel  80 teeth, m 0.13   ->  third pinion  10 leaves
    third wheel   75 teeth, m 0.11   ->  fourth pinion 10 leaves
    fourth wheel  80 teeth, m 0.08   ->  escape pinion  8 leaves

Nothing below says 8, 7.5, 10 or 60. A pinion turns because a wheel tooth
would otherwise be inside one of its leaves: for each wheel angle the
database finds the least the pinion must have turned to be clear. Those
"push edges" are the gearing law; the ratios come out of them.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
import shapely
from shapely import affinity
from shapely.geometry import LineString, Point, Polygon

# ---------------------------------------------------------------- tooth form (in modules)
WHEEL_S = 1.50        # wheel tooth thickness on the pitch circle
WHEEL_HA = 1.40       # wheel addendum (the ogive)
WHEEL_HF = 1.60       # wheel dedendum
LEAF_S = 1.20         # pinion leaf thickness on the pitch circle
LEAF_HF = 1.65        # pinion dedendum (wheel addendum + clearance)
FLANK_PTS = 40        # points per addendum flank (fewer and the facets show up as ratio wobble)
TIP_STEP = 5          # deg between points on a pinion leaf's round tip
DISPLAY_FLANK_PTS = 10
DISPLAY_TIP_STEP = 20
PINION_WEDGE = 78.0   # contact: only the pinion's leaves within this of the wheel are kept

# ---------------------------------------------------------------- the train
ARBORS = {            # name: spin (+1 anticlockwise seen from here)
    "centre": -1, "third": +1, "fourth": -1, "escape": +1}


@dataclass(frozen=True)
class Mesh:
    no: int
    wheel_arbor: str
    pinion_arbor: str
    teeth: int
    leaves: int
    module: float
    direction: float          # bearing from the wheel's arbor to the pinion's arbor, deg


MESHES = [
    Mesh(1, "centre", "third", 80, 10, 0.13, -30.0),
    Mesh(2, "third", "fourth", 75, 10, 0.11, -80.0),
    Mesh(3, "fourth", "escape", 80, 8, 0.08, -150.0),
]

NU = 60               # wheel grid, steps per tooth pitch
NV = 120              # pinion grid, steps per leaf pitch
REFINE = 16           # each refinement splits the edge cell this many ways
ROUNDS = 2


def polar(deg, r, c=(0.0, 0.0)):
    a = math.radians(deg)
    return (c[0] + r * math.cos(a), c[1] + r * math.sin(a))


def circle(c, r, n=48):
    return Polygon([(c[0] + r * math.cos(2 * math.pi * k / n), c[1] + r * math.sin(2 * math.pi * k / n))
                    for k in range(n)])


def arbor_positions():
    """Centre distances are the sum of the pitch radii: m (z + n) / 2."""
    pos = {"centre": (0.0, 0.0)}
    for m in MESHES:
        d = m.module * (m.teeth + m.leaves) / 2
        pos[m.pinion_arbor] = polar(m.direction, d, pos[m.wheel_arbor])
    return pos


# ---------------------------------------------------------------- wheel teeth
def _epi(t, A, rho):
    """Epicycloid: a circle of radius rho rolling round the outside of radius A, from (A, 0)."""
    k = (A + rho) / rho
    return ((A + rho) * math.cos(t) - rho * math.cos(k * t), (A + rho) * math.sin(t) - rho * math.sin(k * t))


def _r(x, y):
    return math.sqrt(x * x + y * y)


def _bisect(f, lo, hi, n=60):
    """Smallest t in [lo, hi] with f(t) >= 0, for f rising through zero."""
    for _ in range(n):
        mid = (lo + hi) / 2
        if f(mid) >= 0:
            hi = mid
        else:
            lo = mid
    return hi


def wheel_flank(z, m, rho, profile, pts=FLANK_PTS):
    """The trailing addendum flank of a tooth centred on 0 deg, as (deg, r), from the pitch circle up.
    Returns (points, pointed) - pointed means the two flanks meet before the addendum circle."""
    A = m * z / 2
    Ra = A + WHEEL_HA * m
    g = math.degrees(WHEEL_S * m / 2 / A)               # half tooth on the pitch circle, deg
    if profile == "straight":
        tip = g * 0.45
        return [(-g + (g - tip) * k / pts, A + (Ra - A) * k / pts) for k in range(pts + 1)], False

    t_max = math.pi * rho / A                            # rolling circle half way round: well past the tip
    t_r = _bisect(lambda t: _r(*_epi(t, A, rho)) - Ra, 0.0, t_max)
    t_a = _bisect(lambda t: math.degrees(math.atan2(_epi(t, A, rho)[1], _epi(t, A, rho)[0])) - g, 0.0, t_max)
    t_end = min(t_r, t_a)
    out = []
    for k in range(pts + 1):
        x, y = _epi(t_end * k / pts, A, rho)
        out.append((-g + math.degrees(math.atan2(y, x)), _r(x, y)))
    return out, t_a <= t_r


def wheel_outline(z, m, rho, profile="cycloidal", pts=FLANK_PTS):
    A = m * z / 2
    Ra, Rr = A + WHEEL_HA * m, A - WHEEL_HF * m
    g = math.degrees(WHEEL_S * m / 2 / A)
    flank, pointed = wheel_flank(z, m, rho, profile, pts)
    lead = [(-d, r) for d, r in reversed(flank)]         # mirror image, tip down to the pitch circle
    if pointed:
        lead = lead[1:]                                  # the two flanks share the tip point
    tip = []
    if not pointed:
        a0, a1 = flank[-1][0], lead[0][0]
        tip = [(a0 + (a1 - a0) * k / 4, Ra) for k in range(1, 4)]
    pitch = 360.0 / z
    tooth = [(-g, Rr)] + flank + tip + lead + [(g, Rr)]
    root = [(g + (pitch - 2 * g) * k / 4, Rr) for k in range(1, 4)]   # root arc to the next tooth
    pts = []
    for k in range(z):
        pts += [polar(k * pitch + d, r) for d, r in tooth + root]
    return Polygon(pts)


def leaf_outline(n, m, tip_step=TIP_STEP):
    """Pinion: radial flanks (what makes cycloidal gearing work) and a round tip."""
    rp = m * n / 2
    rr = rp - LEAF_HF * m
    g = math.degrees(LEAF_S * m / 2 / rp)
    cx, half = rp * math.cos(math.radians(g)), rp * math.sin(math.radians(g))
    tip = [(cx + half * math.cos(math.radians(a)), half * math.sin(math.radians(a))) for a in range(-90, 91, tip_step)]
    tip_polar = [(math.degrees(math.atan2(y, x)), _r(x, y)) for x, y in tip]
    pitch = 360.0 / n
    leaf = [(-g, rr), (-g, rp)] + tip_polar[1:-1] + [(g, rp), (g, rr)]
    root = [(g + (pitch - 2 * g) * k / 4, rr) for k in range(1, 4)]
    pts = []
    for k in range(n):
        pts += [polar(k * pitch + d, r) for d, r in leaf + root]
    return Polygon(pts)


# ---------------------------------------------------------------- one mesh
def place(g, deg, at, scale=1.0):
    """Turn a shape built about the origin by deg, scale it, and move it to `at`: one affine, like dbo.fn_Affine."""
    c, s = scale * math.cos(math.radians(deg)), scale * math.sin(math.radians(deg))
    return affinity.affine_transform(g, [c, -s, s, c, at[0], at[1]])


def mesh_shapes(mesh, profile="cycloidal"):
    pos = arbor_positions()
    rho = mesh.module * mesh.leaves / 4               # half the pinion's pitch radius: radial pinion flanks
    wheel = wheel_outline(mesh.teeth, mesh.module, rho, profile)
    # the pinion's leaves facing the wheel, for any turn of 0..1 leaf (so the wedge starts half a leaf back)
    rp = mesh.module * mesh.leaves / 2
    b0 = mesh.direction + 180.0 - ARBORS[mesh.pinion_arbor] * 180.0 / mesh.leaves
    wedge = Polygon([(0, 0), polar(b0 - PINION_WEDGE, 2 * rp), polar(b0, 2 * rp), polar(b0 + PINION_WEDGE, 2 * rp)])
    pinion = leaf_outline(mesh.leaves, mesh.module).intersection(wedge)
    zone = circle(pos[mesh.pinion_arbor], mesh.module * mesh.leaves / 2 + 3.0 * mesh.module, 64)
    return wheel, pinion, zone


def mesh_map(mesh, profile="cycloidal"):
    """Clear[i, j]: wheel turned i/NU of a tooth, pinion j/NV of a leaf (both 'forwards')."""
    pos = arbor_positions()
    wheel, pinion, zone = mesh_shapes(mesh, profile)
    sw, sp = ARBORS[mesh.wheel_arbor], ARBORS[mesh.pinion_arbor]
    pu, pv = 360.0 / mesh.teeth, 360.0 / mesh.leaves
    wheels = np.array([place(wheel, sw * pu * i / NU, pos[mesh.wheel_arbor]).intersection(zone) for i in range(NU)])
    pinions = np.array([place(pinion, sp * pv * j / NV, pos[mesh.pinion_arbor]) for j in range(NV)])
    clear = ~shapely.intersects(wheels[:, None], pinions[None, :])
    return clear, wheels, pinion


def push_edges(mesh, profile="cycloidal"):
    """For each wheel step, the least the pinion must have turned (deg, within a leaf) to be clear of it:
    the start of the clear run, refined between the last blocked and first clear cell."""
    pos = arbor_positions()
    clear, wheels, pinion = mesh_map(mesh, profile)
    sp = ARBORS[mesh.pinion_arbor]
    pv = 360.0 / mesh.leaves
    edges = []
    for i in range(NU):
        row = clear[i]
        starts = [j for j in range(NV) if row[j] and not row[j - 1]]
        if len(starts) != 1:
            raise RuntimeError(f"mesh {mesh.no}, wheel step {i}: {len(starts)} clear runs - the mesh jams")
        lo, hi = (starts[0] - 1) * pv / NV, starts[0] * pv / NV     # blocked at lo, clear at hi
        for _ in range(ROUNDS):
            step = (hi - lo) / REFINE
            for k in range(1, REFINE + 1):
                v = lo + k * step
                if not wheels[i].intersects(place(pinion, sp * v, pos[mesh.pinion_arbor])):
                    lo, hi = v - step, v
                    break
        edges.append(hi % pv)
    return clear, edges


def unwrap(edges, pv):
    """Make the push edge continuous across one wheel tooth; it must end one leaf further on."""
    out = [edges[0]]
    for e in edges[1:]:
        d = (e - out[-1] + pv / 2) % pv - pv / 2
        out.append(out[-1] + d)
    return out


def transmit(table, pu, pv, u):
    """Pinion progress for wheel progress u (both deg, forwards), by linear interpolation."""
    k = math.floor(u / pu)
    r = u - k * pu
    x = r / (pu / NU)
    i = min(int(x), NU - 1)
    t = x - i
    nxt = table[i + 1] if i + 1 < NU else table[0] + pv
    return table[i] + t * (nxt - table[i]) + k * pv


def train_tables(profile="cycloidal"):
    tables = {}
    for m in MESHES:
        _, e = push_edges(m, profile)
        tables[m.no] = unwrap(e, 360.0 / m.leaves)
    return tables


def run(tables, seconds=60.0, frames=361):
    """Turn the centre arbor at its real rate (0.1 deg a second) and let the train follow."""
    out = []
    for f in range(frames):
        t = seconds * f / (frames - 1)
        prog = {"centre": 0.1 * t}
        for m in MESHES:
            prog[m.pinion_arbor] = transmit(tables[m.no], 360.0 / m.teeth, 360.0 / m.leaves, prog[m.wheel_arbor])
        out.append({"FrameNo": f, "Seconds": t, **{a: ARBORS[a] * prog[a] for a in ARBORS}})
    return out
