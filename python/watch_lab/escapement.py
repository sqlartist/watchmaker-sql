"""Swiss lever escapement: geometry and kinematics.

Python mirror of sql/02_geometry.sql + sql/03_escapement.sql. Same shapes,
same grids, same solver, so the SQL Server run can be checked against it.

Layout of the drawing plane (units: escape wheel tip radius = 10):
    escape wheel     centred at O = (0, 0), turns anticlockwise
    pallet arbor     P = (0, R / cos 30)  - where the tangents at +/-30 deg meet
    balance staff    B = P + (0, 13)
The pallet stones sit at 56.5-63.5 deg (entry) and 116.5-123.5 deg (exit):
their locking faces are 2.5 teeth apart, and stone + club + drop = half a
pitch (7 + 3 + 2 = 12 deg), which is what makes the escapement tick.

Nothing below says "lock", "impulse" or "drop". The solver only ever asks
"does this shape touch that one?" - the phases fall out of the metal.
"""
from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np
import shapely
from shapely import affinity
from shapely.geometry import LineString, Point, Polygon

# ---------------------------------------------------------------- dimensions
R = 10.0                                 # escape wheel tip radius
RR = 7.2                                 # root radius
TEETH = 15
PITCH = 360.0 / TEETH                    # 24 deg
D = R / math.cos(math.radians(30))       # O -> pallet arbor
P = (0.0, D)
LEVER = 13.0                             # pallet arbor -> balance staff
B = (0.0, D + LEVER)
RJ = 3.0                                 # roller jewel (impulse pin) radius from the staff
JEWEL_R = 0.35
ROLLER_R = 2.0
K = math.radians(1.0) * R * math.tan(math.radians(30))   # radial travel of a stone per deg of fork

CLUB_RISE = 0.2                          # club slopes up from the locking corner (R - 0.2) to the heel (R)
LOCK_DEG = 1.0                           # stone's locking corner sits LOCK_DEG of fork above R at neutral
LIFT_DEG = 6.0                           # rise of the stone's impulse face, in deg of fork
# designed budget, in deg of fork: lock 3 + stone lift 6 + club lift 2 + run 1 = 12 = 2 x BANK_DEG
DRAW_DEG = 12.0                          # locking face leans back so the tooth pulls the stone in
BANK_DEG = 6.0                           # banking pins stop the fork here
STONE_W = 7.0                            # stone width, deg of wheel
CLUB_W = 3.0                             # club width, deg of wheel (the drop is what's left: 12 - 7 - 3)

# ---------------------------------------------------------------- grids
THETA_STEP = 0.1                         # wheel, over one pitch (the wheel repeats every 24 deg)
PHI_STEP = 0.1                           # fork, -8 .. +8
PHI_MIN, PHI_MAX = -8.0, 8.0
BETA_STEP = 0.25                         # balance, -45 .. +45 (outside that the jewel can't reach the fork)
BETA_MAX = 45.0

N_THETA = round(PITCH / THETA_STEP)                       # 240
N_PHI = round((PHI_MAX - PHI_MIN) / PHI_STEP) + 1         # 161
N_BETA = round(2 * BETA_MAX / BETA_STEP) + 1              # 361


def polar(deg, r, c=(0.0, 0.0)):
    a = math.radians(deg)
    return (c[0] + r * math.cos(a), c[1] + r * math.sin(a))


def circle(c, r, n=48):
    """An explicit n-gon (the SQL side builds the same one, so the two agree vertex for vertex)."""
    return Polygon([(c[0] + r * math.cos(2 * math.pi * k / n), c[1] + r * math.sin(2 * math.pi * k / n))
                    for k in range(n)])


def _unit(deg):
    a = math.radians(deg)
    return (math.cos(a), math.sin(a)), (-math.sin(a), math.cos(a))   # radial, anticlockwise tangent


# ---------------------------------------------------------------- escape wheel
# One club tooth, as (deg relative to its locking corner, radius), walked
# anticlockwise round the outline: back face up to the heel, down the club's
# impulse face to the locking corner, down the forward-leaning front face,
# then the root arc to the next tooth.
TOOTH = (
    [(-11.0, RR), (-8.5, 7.9), (-6.5, 8.8), (-4.5, 9.55), (-3.0, R),
     (-2.0, R - CLUB_RISE / 3), (-1.0, R - 2 * CLUB_RISE / 3), (0.0, R - CLUB_RISE),
     (-1.2, 9.05), (-2.6, 8.2), (-4.2, 7.45), (-5.0, RR)]
    + [(-5.0 + 18.0 * s / 8, RR) for s in range(1, 8)]     # root arc to +13 (next tooth's back root)
)


def wheel_outline() -> Polygon:
    pts = []
    for k in range(TEETH):
        a = k * PITCH
        pts += [polar(a + d, r) for d, r in TOOTH]
    return Polygon(pts)


def wheel_display() -> Polygon:
    """Full wheel: teeth, five crossings, hub and arbor hole."""
    o = (0.0, 0.0)
    arms = shapely.union_all([
        LineString([o, polar(90 + 72 * k, 6.6)]).buffer(0.45) for k in range(5)])
    windows = circle(o, 6.4, 128).difference(circle(o, 2.0, 64)).difference(arms)
    return wheel_outline().difference(windows).difference(circle(o, 0.5, 24))


# the only part of the wheel that can ever reach the pallets, for any turn of
# 0..24 deg (clipped at 0 deg, then rotated - so it starts 24 deg early)
CONTACT_ZONE = Polygon([(0, 0)] + [polar(a, 14.0) for a in range(10, 151, 5)])


def wheel_contact() -> Polygon:
    return wheel_outline().intersection(CONTACT_ZONE.difference(circle((0.0, 0.0), 6.0, 128)))


# ---------------------------------------------------------------- pallet fork
def _stone(lock_deg):
    """Quadrilateral stone. lock_deg = angle (about O) of its locking corner."""
    u, t = _unit(lock_deg)
    c_lock = polar(lock_deg, R + LOCK_DEG * K)
    c_exit = polar(lock_deg + STONE_W, R + (LOCK_DEG - LIFT_DEG) * K)
    dr = math.radians(DRAW_DEG)
    # the face leans forward going outwards, so a tooth pushing on it pulls the stone in (draw)
    face = (u[0] * math.cos(dr) + t[0] * math.sin(dr), u[1] * math.cos(dr) + t[1] * math.sin(dr))
    lock_outer = (c_lock[0] + 2.2 * face[0], c_lock[1] + 2.2 * face[1])
    u2, _ = _unit(lock_deg + STONE_W)
    back_outer = (c_exit[0] + 2.9 * u2[0], c_exit[1] + 2.9 * u2[1])
    return Polygon([lock_outer, c_lock, c_exit, back_outer])


ENTRY_LOCK_DEG, EXIT_LOCK_DEG = 56.5, 116.5


def stones():
    return _stone(ENTRY_LOCK_DEG), _stone(EXIT_LOCK_DEG)


def pallet_body() -> Polygon:
    e, x = stones()
    e_top = polar(ENTRY_LOCK_DEG + STONE_W / 2, R + 2.4)
    x_top = polar(EXIT_LOCK_DEG + STONE_W / 2, R + 2.4)
    bar = LineString([e_top, P, x_top]).buffer(0.6, 16)
    return shapely.union_all([bar, circle(P, 1.3, 64)]).difference(circle(P, 0.35, 24))


# lever outline in its own frame: x across, y along from the pallet arbor
# The jewel only dips about its own radius into the slot (it is 10.0 from the
# arbor at the centre of its swing, 10.25 at +/-20 deg), so the horns stop at 9.95.
LEVER_LOCAL = [(-0.45, 0.0), (-0.35, 8.0), (-1.0, 8.6), (-1.0, 9.6), (-0.75, 9.95), (-0.4, 9.95),
               (-0.4, 9.25), (0.4, 9.25), (0.4, 9.95), (0.75, 9.95), (1.0, 9.6), (1.0, 8.6),
               (0.35, 8.0), (0.45, 0.0)]


def lever() -> Polygon:
    return Polygon([(P[0] + x, P[1] + y) for x, y in LEVER_LOCAL])


def fork_at(phi):
    """(body+lever, entry stone, exit stone) rotated phi deg about the pallet arbor."""
    e, x = stones()
    steel = pallet_body().union(lever())
    return tuple(affinity.rotate(g, phi, origin=P) for g in (steel, e, x))


def fork_solid_at(phi):
    return shapely.union_all(fork_at(phi))


# banking pins: touch the lever's edge 4.5 along it when the fork is at +/- BANK_DEG
_HW = 0.45 - 0.10 * 4.5 / 8.0
PIN_R = 0.3


def banking_pins():
    left = affinity.rotate(Point(P[0] - (_HW + PIN_R), P[1] + 4.5), BANK_DEG, origin=P)
    right = affinity.rotate(Point(P[0] + (_HW + PIN_R), P[1] + 4.5), -BANK_DEG, origin=P)
    return circle((left.x, left.y), PIN_R, 48), circle((right.x, right.y), PIN_R, 48)


# ---------------------------------------------------------------- balance
def jewel_at(beta):
    a = math.radians(beta)
    return circle((B[0] + RJ * math.sin(a), B[1] - RJ * math.cos(a)), JEWEL_R, 48)


def balance_at(beta):
    """Balance wheel: rim, three arms, timing screws. Rotated beta deg about the staff."""
    rim = circle(B, 8.0, 192).difference(circle(B, 7.2, 192))
    arms = shapely.union_all([LineString([B, polar(-90 + 120 * k, 7.6, B)]).buffer(0.35) for k in range(3)])
    screws = shapely.union_all([circle(polar(15 + 30 * k, 8.15, B), 0.32, 16) for k in range(12)])
    g = shapely.union_all([rim, arms, screws, circle(B, 0.9, 32)])
    return affinity.rotate(g, beta, origin=B)


def roller_at(beta):
    return circle(B, ROLLER_R, 96)


def hairspring_at(beta, turns=9, r0=1.0, r1=4.6, n=900):
    """Archimedean spiral: inner end turns with the balance, outer end held by the stud."""
    s = np.linspace(0, 1, n)
    ang = np.radians(-90 + 360 * turns * s + beta * (1 - s))
    r = r0 + (r1 - r0) * s
    return LineString(np.column_stack([B[0] + r * np.cos(ang), B[1] + r * np.sin(ang)]))


# ---------------------------------------------------------------- the clearance maps
def theta_of(i):
    return i * THETA_STEP


def phi_of(j):
    return PHI_MIN + j * PHI_STEP


def beta_of(b):
    return -BETA_MAX + b * BETA_STEP


def clearance_maps():
    """The physics, asked once: which (wheel, fork) and (balance, fork) pairs are clear."""
    wc = wheel_contact()
    wheels = np.array([affinity.rotate(wc, theta_of(i), origin=(0, 0)) for i in range(N_THETA)])
    forks = np.array([fork_solid_at(phi_of(j)) for j in range(N_PHI)])
    levers = np.array([affinity.rotate(lever(), phi_of(j), origin=P) for j in range(N_PHI)])
    jewels = np.array([jewel_at(beta_of(b)) for b in range(N_BETA)])
    pins = shapely.union_all(banking_pins())

    wf = ~shapely.intersects(wheels[:, None], forks[None, :])        # [theta, phi]
    fj = ~shapely.intersects(jewels[:, None], levers[None, :])       # [beta, phi]
    pin = ~shapely.intersects(forks, pins)                            # [phi]

    # which face would the wheel hit one step further on? 0 none, else FACES index + 1
    nxt = np.roll(wheels, -1)
    nxt[-1] = affinity.rotate(wc, PITCH, origin=(0, 0))
    cf = np.zeros(wf.shape, dtype=np.int8)
    for code in range(len(FACES), 0, -1):                             # lock faces win at a shared corner
        lines = np.array([stone_faces(phi_of(j))[FACES[code - 1][0]][FACES[code - 1][1]] for j in range(N_PHI)])
        cf[shapely.intersects(nxt[:, None], lines[None, :])] = code
    return wf, fj, pin, cf


FACES = [("entry", "lock"), ("entry", "impulse"), ("exit", "lock"), ("exit", "impulse")]
DRAW_DIR = {"entry": -1, "exit": +1}            # draw pulls a locked stone deeper: towards its banking


# ---------------------------------------------------------------- the solver
@dataclass
class Frame:
    no: int
    beta: float
    phi: float
    theta: float
    phase: str                 # locked | unlocking | impulse | drop
    stone: str | None          # entry | exit | None (wheel free)
    face: str | None           # lock | impulse | None


def stone_faces(phi):
    """The two working faces of each stone as lines: locking face and impulse face."""
    _, e, x = fork_at(phi)
    out = {}
    for name, g in (("entry", e), ("exit", x)):
        lock_outer, c_lock, c_exit, _ = list(g.exterior.coords)[:4]
        out[name] = {"lock": LineString([lock_outer, c_lock]), "impulse": LineString([c_lock, c_exit])}
    return out


def beta_schedule(beats=4, amplitude=110.0, slow=30.0, fine=0.75, coarse=6.0):
    """Balance angles, frame by frame: a sine swing, filmed in slow motion while
    |beta| < slow (steps of `fine` deg) and at normal speed outside (`coarse`)."""
    out, beta, direction = [], amplitude, -1
    for _ in range(beats):
        while True:
            out.append(round(beta, 4))
            step = fine if abs(beta) < slow else coarse
            beta += direction * step
            if abs(beta) >= amplitude:
                beta = direction * amplitude
                direction = -direction
                break
    out.append(round(beta, 4))
    return out


def run(betas=None, wheel_cap=15, maps=None):
    """Drive the balance; let the fork and wheel go wherever the metal allows.

    Each frame:
      1. the jewel shoves the fork to the nearest angle clear of it, and a
         stone that ends up in a tooth drives the wheel back (recoil);
      2. the fork drifts the way the tooth is pushing it - back towards its
         banking while the tooth sits on a locking face (draw), onwards while
         it rides an impulse face - until the jewel, a pin or the wheel stops it;
      3. the wheel turns forward until it touches a stone (at most wheel_cap
         steps a frame). 2 and 3 repeat until nothing moves.
    Positions are grid indices; theta is unbounded.
    """
    if betas is None:
        betas = beta_schedule()
    wf, fj, pin, cf = maps if maps is not None else clearance_maps()

    def fj_ok(b, j):
        return True if b is None else bool(fj[b, j])

    def wf_ok(n, j):
        return bool(wf[n % N_THETA, j])

    def fork_ok(b, j, n):
        return 0 <= j < N_PHI and pin[j] and fj_ok(b, j) and wf_ok(n, j)

    def touching(n, j):
        code = int(cf[n % N_THETA, j])
        return FACES[code - 1] if code else (None, None)

    j = round((-BANK_DEG - PHI_MIN) / PHI_STEP)     # entry locked, fork on the right-hand banking
    n = round(2.0 / THETA_STEP)                     # a tooth at 50 deg, on its way to the entry stone
    while wf_ok(n + 1, j):
        n += 1
    push = -1
    prev_face = "lock"
    out = []

    for f, beta in enumerate(betas):
        b = round((beta + BETA_MAX) / BETA_STEP)
        b = b if 0 <= b < N_BETA else None
        n0 = n
        shoved = False

        # 1. the jewel shoves the fork out of its way
        if not fj_ok(b, j):
            for d in range(1, N_PHI):
                cand = [jj for jj in (j - d, j + d) if 0 <= jj < N_PHI and pin[jj] and fj_ok(b, jj)]
                if cand:
                    jj = cand[0]
                    push = 1 if jj > j else -1
                    j = jj
                    shoved = True
                    break
            back = 0
            while not wf_ok(n, j) and back < 200:
                n -= 1
                back += 1

        # 2./3. fork drifts the way the wheel pushes it, wheel follows
        for _ in range(200):
            moved = False
            stone, face = touching(n, j)
            drift = DRAW_DIR[stone] if face == "lock" else push
            if fork_ok(b, j + drift, n):
                j += drift
                push = drift
                moved = True
            while n - n0 < wheel_cap and wf_ok(n + 1, j):
                n += 1
                moved = True
            if not moved:
                break

        stone, face = touching(n, j)
        if n < n0 or (shoved and n == n0):
            phase = "unlocking"
        elif n == n0:
            phase = "locked"
        elif face == "impulse":
            phase = "impulse"
        elif face == "lock" and prev_face == "lock":
            phase = "locked"                            # drawn in to the banking
        else:
            phase = "drop"
        prev_face = face
        out.append(Frame(f, beta, phi_of(j), n * THETA_STEP, phase, stone, face))
    return out


def measure(frames):
    """What the run says about the escapement, beat by beat (all in degrees)."""
    beats, cur = [], None
    for prev, fr in zip(frames, frames[1:]):
        if fr.phase == "unlocking" and prev.phase == "locked":
            cur = {"stone": prev.stone, "phi_locked": prev.phi, "theta0": prev.theta,
                   "recoil": 0.0, "impulse_wheel": 0.0, "drop_wheel": 0.0}
            beats.append(cur)
        if cur is None:
            continue
        d = fr.theta - prev.theta
        if fr.phase == "unlocking":
            cur["recoil"] = min(cur["recoil"], fr.theta - cur["theta0"])
            cur["phi_unlocked"] = fr.phi
        elif fr.phase == "impulse":
            cur["impulse_wheel"] += d
            cur["phi_impulse_end"] = fr.phi
        elif fr.phase == "drop":
            cur["drop_wheel"] += d
        if fr.phase == "locked" and prev.phase != "locked":
            cur["advance"] = fr.theta - cur["theta0"]
    for bt in beats:
        bt["lock"] = abs(bt.get("phi_unlocked", bt["phi_locked"]) - bt["phi_locked"])
        bt["lift"] = abs(bt.get("phi_impulse_end", bt["phi_locked"]) - bt.get("phi_unlocked", bt["phi_locked"]))
    return beats
