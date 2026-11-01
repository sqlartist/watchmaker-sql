"""The motion works: minute hand to hour hand.

Python mirror of sql/06_motion.sql. Same teeth, same grids, same push edges.

Units are millimetres; the centre arbor is at the origin.

    cannon pinion 12 leaves (on the centre arbor, carries the minute hand)
        drives the minute wheel  36 teeth          (m 0.125)
    minute pinion 10 leaves (same arbor as the minute wheel)
        drives the hour wheel    40 teeth          (m 0.12; carries the hour hand)

Here pinions drive wheels, so every gear gets the full cycloidal form: its
addendum is the epicycloid rolled by a circle half its partner's pitch
radius, its dedendum is radial. And because the hour wheel rides on the
cannon pinion, both meshes must be exactly the same length:
0.125 x (12 + 36) / 2 = 0.12 x (10 + 40) / 2 = 3 mm.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
import shapely
from shapely import affinity
from shapely.geometry import Polygon

from .train import circle, polar, place, _epi, _r

# ---------------------------------------------------------------- tooth form (in modules)
TOOTH_S = 1.40        # thickness on the pitch circle (generous backlash: motion works carry no load)
TOOTH_HA = 1.40       # addendum
TOOTH_HF = 1.65       # dedendum
FLANK_PTS = 40
DISPLAY_FLANK_PTS = 6
ZONE_M = 6.0          # the gears can only touch within this many modules of the pitch point

NU = 60               # driver grid, steps per tooth
NV = 120              # driven grid, steps per tooth
REFINE = 16
ROUNDS = 2

ARBORS = {"centre": -1, "minute": +1, "hour": -1}     # seen from the dial: the hands go clockwise


@dataclass(frozen=True)
class Mesh:
    no: int
    driver_arbor: str
    driver_teeth: int
    driven_arbor: str
    driven_teeth: int
    module: float
    direction: float          # bearing from the driver's arbor to the driven's


MESHES = [
    Mesh(1, "centre", 12, "minute", 36, 0.125, -135.0),     # cannon pinion -> minute wheel
    Mesh(2, "minute", 10, "hour", 40, 0.12, 45.0),          # minute pinion -> hour wheel
]


def arbor_positions():
    pos = {"centre": (0.0, 0.0)}
    for m in MESHES:
        d = m.module * (m.driver_teeth + m.driven_teeth) / 2
        pos[m.driven_arbor] = polar(m.direction, d, pos[m.driver_arbor])
    return pos


def _bisect(f, lo, hi, n=60):
    for _ in range(n):
        mid = (lo + hi) / 2
        if f(mid) >= 0:
            hi = mid
        else:
            lo = mid
    return hi


def gear_outline(z, m, rho, pts=FLANK_PTS):
    """A gear of z teeth centred on the origin, tooth 0 on 0 deg: epicycloid addendum rolled by rho,
    radial dedendum. Pointed if the two flanks meet before the addendum circle."""
    A = m * z / 2
    Ra, Rr = A + TOOTH_HA * m, A - TOOTH_HF * m
    g = math.degrees(TOOTH_S * m / 2 / A)
    # roll no further than a quarter turn of the base circle: past that the curve's angle wraps round
    t_max = min(math.pi * rho / A, math.pi / 2)
    t_r = _bisect(lambda t: _r(*_epi(t, A, rho)) - Ra, 0.0, t_max)
    t_a = _bisect(lambda t: math.degrees(math.atan2(_epi(t, A, rho)[1], _epi(t, A, rho)[0])) - g, 0.0, t_max)
    t_end = min(t_r, t_a)
    pointed = t_a <= t_r
    flank = []
    for k in range(pts + 1):
        x, y = _epi(t_end * k / pts, A, rho)
        flank.append((-g + math.degrees(math.atan2(y, x)), _r(x, y)))
    lead = [(-d, r) for d, r in reversed(flank)]
    if pointed:
        lead = lead[1:]
    tip = []
    if not pointed:
        a0, a1 = flank[-1][0], lead[0][0]
        tip = [(a0 + (a1 - a0) * k / 4, Ra) for k in range(1, 4)]
    pitch = 360.0 / z
    tooth = [(-g, Rr)] + flank + tip + lead + [(g, Rr)]
    root = [(g + (pitch - 2 * g) * k / 4, Rr) for k in range(1, 4)]
    out = []
    for k in range(z):
        out += [polar(k * pitch + d, r) for d, r in tooth + root]
    return Polygon(out)


def _wedge(bearing, half, radius):
    """A fan from the origin, bearing +/- half deg: the part of a gear that can reach its partner."""
    if half >= 180:
        return None
    n = max(2, math.ceil(2 * half / 30))
    return Polygon([(0.0, 0.0)] + [polar(bearing - half + 2 * half * k / n, radius) for k in range(n + 1)])


def mesh_shapes(mesh):
    """(driver, driven, zone): each gear cut down at rest to the teeth that can ever meet the other."""
    pos = arbor_positions()
    m = mesh.module
    a_d, a_n = m * mesh.driver_teeth / 2, m * mesh.driven_teeth / 2
    driver = gear_outline(mesh.driver_teeth, m, a_n / 2)          # rolled by half the partner's pitch radius
    driven = gear_outline(mesh.driven_teeth, m, a_d / 2)
    zone_r = ZONE_M * m
    pitch_point = polar(mesh.direction, a_d, pos[mesh.driver_arbor])
    zone = circle(pitch_point, zone_r, 64)
    sd, sn = ARBORS[mesh.driver_arbor], ARBORS[mesh.driven_arbor]
    pu, pv = 360.0 / mesh.driver_teeth, 360.0 / mesh.driven_teeth
    for_driver = _wedge(mesh.direction - sd * pu / 2,
                        math.degrees(math.asin(min(1.0, zone_r / a_d))) + pu + 5, 2 * (a_d + TOOTH_HA * m))
    for_driven = _wedge(mesh.direction + 180 - sn * pv / 2,
                        math.degrees(math.asin(min(1.0, zone_r / a_n))) + pv + 5, 2 * (a_n + TOOTH_HA * m))
    if for_driver is not None:
        driver = driver.intersection(for_driver)
    if for_driven is not None:
        driven = driven.intersection(for_driven)
    return driver, driven, zone


def mesh_map(mesh):
    """Clear[i, j]: driver turned i/NU of a tooth, driven j/NV of a tooth (both forwards)."""
    pos = arbor_positions()
    driver, driven, zone = mesh_shapes(mesh)
    sd, sn = ARBORS[mesh.driver_arbor], ARBORS[mesh.driven_arbor]
    pu, pv = 360.0 / mesh.driver_teeth, 360.0 / mesh.driven_teeth
    drivers = np.array([place(driver, sd * pu * i / NU, pos[mesh.driver_arbor]).intersection(zone) for i in range(NU)])
    drivens = np.array([place(driven, sn * pv * j / NV, pos[mesh.driven_arbor]) for j in range(NV)])
    return ~shapely.intersects(drivers[:, None], drivens[None, :]), drivers, driven


def push_edges(mesh):
    pos = arbor_positions()
    clear, drivers, driven = mesh_map(mesh)
    sn = ARBORS[mesh.driven_arbor]
    pv = 360.0 / mesh.driven_teeth
    edges = []
    for i in range(NU):
        row = clear[i]
        starts = [j for j in range(NV) if row[j] and not row[j - 1]]
        if len(starts) != 1:
            raise RuntimeError(f"mesh {mesh.no}, driver step {i}: {len(starts)} clear runs - the mesh jams")
        lo, hi = (starts[0] - 1) * pv / NV, starts[0] * pv / NV
        for _ in range(ROUNDS):
            step = (hi - lo) / REFINE
            for k in range(1, REFINE + 1):
                v = lo + k * step
                if not drivers[i].intersects(place(driven, sn * v, pos[mesh.driven_arbor])):
                    lo, hi = v - step, v
                    break
        edges.append(hi % pv)
    return clear, edges


def unwrap(edges, pv):
    out = [edges[0]]
    for e in edges[1:]:
        d = (e - out[-1] + pv / 2) % pv - pv / 2
        out.append(out[-1] + d)
    return out


def transmit(table, pu, pv, u):
    k = math.floor(u / pu)
    r = u - k * pu
    x = r / (pu / NU)
    i = min(int(x), NU - 1)
    t = x - i
    nxt = table[i + 1] if i + 1 < NU else table[0] + pv
    return table[i] + t * (nxt - table[i]) + k * pv


def tables():
    return {m.no: unwrap(push_edges(m)[1], 360.0 / m.driven_teeth) for m in MESHES}


def run(tabs, hours=12.0, frames=361):
    """Turn the cannon pinion at the minute hand's rate (360 deg an hour) and let the motion works follow."""
    out = []
    for f in range(frames):
        h = hours * f / (frames - 1)
        prog = {"centre": 360.0 * h}
        for m in MESHES:
            prog[m.driven_arbor] = transmit(tabs[m.no], 360.0 / m.driver_teeth, 360.0 / m.driven_teeth,
                                            prog[m.driver_arbor])
        out.append({"FrameNo": f, "Hours": h, **{a: ARBORS[a] * prog[a] for a in ARBORS}})
    return out
