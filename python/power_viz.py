#!/usr/bin/env python3
"""Animate the power episode, and draw its figures.

  python power_viz.py                      # simulator: both GIFs
  python power_viz.py --source sql         # SQL Server's latest runs, plus the figures

power_click.gif   the ratchet and click: wind five teeth, then let go
power_spring.gif  the mainspring wound up and run down, with the power reserve
power_fill.png    how far the barrel turns, by spring length (power.Fill)
power_click_space.png  the click's configuration space, with both runs through it
"""
from __future__ import annotations

import argparse
import math
import os
import sys

import matplotlib

if "--show" not in sys.argv:
    matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.animation import FuncAnimation, PillowWriter
from matplotlib.colors import ListedColormap
from shapely import affinity, wkt
from shapely.geometry import LineString, Polygon

from watch_lab import power as P
from watch_lab.draw import BLUE, CRITICAL, INK, INK_2, SURFACE, YELLOW, plot_geom

GILT = "#e0c46a"
GILT_EDGE = "#8a6d1e"
STEEL = "#a7afb8"
STEEL_EDGE = "#5f6a76"
BLUED = "#2d4f8a"
GOOD = "#0ca30c"

EVENT_COLOUR = {"rest": INK_2, "lift": BLUE, "ride": BLUE, "drop": BLUE, "click": GOOD, "hold": INK_2,
                "back": YELLOW, "locked": CRITICAL}
EVENT_TEXT = {
    "rest":   "The click rests in a gap, pushed in by its spring",
    "lift":   "WINDING - each tooth's long slope lifts the click out of the way",
    "ride":   "WINDING - each tooth's long slope lifts the click out of the way",
    "drop":   "WINDING - each tooth's long slope lifts the click out of the way",
    "click":  "CLICK - past the tip, the spring snaps the click into the next gap",
    "hold":   "Now let go: the mainspring pulls the ratchet back the other way",
    "back":   "The ratchet slips back down the slope, the click sliding with it ...",
    "locked": "LOCKED - the flat face drives the click towards its own pivot; it can't lift, so nothing moves",
}


# ------------------------------------------------------------------ sources
class SqlSource:
    def __init__(self):
        from watch_lab.sqlsource import _conn
        self.cur = _conn().cursor()

    def _parts(self, run_id):
        self.cur.execute("SELECT FrameNo, Part, Geom.STAsText() FROM power.FramePart WHERE RunId = ?", run_id)
        out = {}
        for f, p, g in self.cur.fetchall():
            out.setdefault(f, {})[p] = wkt.loads(g)
        return out

    def click(self):
        c = self.cur
        c.execute("SELECT MIN(r.RunId) FROM power.Run r WHERE r.Kind = 'click' "
                  "AND EXISTS (SELECT 1 FROM power.FramePart p WHERE p.RunId = r.RunId)")
        run_id = c.fetchone()[0]
        c.execute("SELECT FrameNo, RatchetDeg, PawlDeg, Event FROM power.ClickFrame WHERE RunId = ? ORDER BY FrameNo",
                  run_id)
        frames = [dict(zip(("FrameNo", "RatchetDeg", "PawlDeg", "Event"), r)) for r in c.fetchall()]
        return frames, self._parts(run_id)

    def spring(self):
        c = self.cur
        c.execute("SELECT MAX(r.RunId) FROM power.Run r WHERE r.Kind = 'spring' "
                  "AND EXISTS (SELECT 1 FROM power.FramePart p WHERE p.RunId = r.RunId)")
        run_id = c.fetchone()[0]
        c.execute("SELECT FrameNo, Phase, Wound, ArborDeg, BarrelDeg, InnerTurns, OuterTurns, LengthMm, Hours "
                  "FROM power.SpringFrame WHERE RunId = ? ORDER BY FrameNo", run_id)
        cols = ("FrameNo", "Phase", "Wound", "ArborDeg", "BarrelDeg", "InnerTurns", "OuterTurns", "Length", "Hours")
        frames = [dict(zip(cols, r)) for r in c.fetchall()]
        return frames, self._parts(run_id)

    def click_space(self):
        self.cur.execute("SELECT I, J, Clear FROM power.ClickMap")
        clear = np.zeros((P.NR, P.NC), dtype=bool)
        for i, j, v in self.cur.fetchall():
            clear[i, j] = bool(v)
        return clear

    def fill(self):
        self.cur.execute("SELECT LengthMm, WoundTurns, LetDownTurns, BarrelTurns, Fits, FilledPct FROM power.Fill "
                         "ORDER BY LengthMm")
        return self.cur.fetchall()


class SimSource:
    """The Python mirror: same rules, shapes placed the same way."""

    def __init__(self):
        self.clear = P.click_map()

    def click(self):
        run = P.click_run(self.clear, back_steps=160)
        frames = [{"FrameNo": f, "RatchetDeg": r, "PawlDeg": c, "Event": e} for f, r, c, e in run]
        ratchet = P.ratchet_outline().difference(Polygon([(-.65, -.65), (.65, -.65), (.65, .65), (-.65, .65)]))
        pawl = P.pawl_outline()
        parts = {}
        for fr in frames:
            tip = affinity.rotate(LineString([P.polar(-1.5, 5.05), P.polar(-1.5, 5.05)]), fr["PawlDeg"],
                                  origin=P.PAWL_PIVOT).coords[0]
            us = [k / 24 for k in range(25)]
            leaf = LineString([((1 - u) ** 2 * 7.6 + 2 * (1 - u) * u * 7.4 + u * u * tip[0],
                                (1 - u) ** 2 * 1.9 + 2 * (1 - u) * u * 0.2 + u * u * tip[1]) for u in us]).buffer(0.07)
            parts[fr["FrameNo"]] = {"Ratchet": affinity.rotate(ratchet, fr["RatchetDeg"], origin=(0, 0)),
                                    "Pawl": affinity.rotate(pawl, fr["PawlDeg"], origin=P.PAWL_PIVOT),
                                    "ClickSpring": leaf}
        return frames, parts

    def spring(self):
        frames = P.spring_run()
        w0, _ = P.wound_limits()
        hook = -360.0 * w0
        barrel = Polygon(P.circle((0, 0), P.RB + 0.75, 240).exterior).difference(P.circle((0, 0), P.RB, 180))
        barrel = barrel.difference(Polygon([P.polar(hook - 5, P.RB - .05), P.polar(hook, P.RB + .12),
                                            P.polar(hook + 1, P.RB - .05)]))
        arbor = P.circle((0, 0), P.RA, 96).union(Polygon([P.polar(-10, P.RA - .02), P.polar(0, P.RA + .13),
                                                          P.polar(6, P.RA - .02)])).difference(P.circle((0, 0), .45, 24))
        parts = {fr["FrameNo"]: {"Barrel": affinity.rotate(barrel, fr["BarrelDeg"], origin=(0, 0)),
                                 "Arbor": affinity.rotate(arbor, fr["ArborDeg"], origin=(0, 0)),
                                 "Spring": P.spring_line(fr["ArborDeg"], fr["Wound"])} for fr in frames}
        return frames, parts

    def click_space(self):
        return self.clear

    def fill(self):
        rows = []
        for k in range(25):
            length = 50 + 25 * k
            n_in, n_out, turns, fits = P.barrel_turns(length)
            rows.append((length, n_in, n_out, turns, fits, 100 * length * P.T / (math.pi * (P.RB ** 2 - P.RA ** 2))))
        return rows


# ------------------------------------------------------------------ the click
SPACE_CMAP = ListedColormap(["#c9ced4", SURFACE])
PITCH = 360.0 / P.RATCHET_TEETH


def draw_click_space(ax, clear):
    ax.imshow(clear.T.astype(int), origin="lower", cmap=SPACE_CMAP, vmin=0, vmax=1, aspect="auto",
              extent=(0, PITCH, P.PAWL_MIN - P.PAWL_STEP / 2, P.PAWL_MAX + P.PAWL_STEP / 2), interpolation="nearest")
    ax.set_xlim(0, PITCH)
    ax.set_ylim(-9, 2.5)
    ax.set_xlabel("ratchet, degrees within one tooth", fontsize=8, color=INK_2)
    ax.set_ylabel("click, degrees (up = pushed in)", fontsize=8, color=INK_2)
    ax.tick_params(labelsize=7, colors=INK_2)


def _trail(ax, frames, upto, n=400):
    arts = []
    seg = frames[max(0, upto - n):upto + 1]
    for a, b in zip(seg, seg[1:]):
        x0, x1 = a["RatchetDeg"] % PITCH, b["RatchetDeg"] % PITCH
        if abs(x1 - x0) < PITCH / 2:
            arts += ax.plot([x0, x1], [a["PawlDeg"], b["PawlDeg"]], color=EVENT_COLOUR[b["Event"]], lw=1.8)
    last = frames[upto]
    arts.append(ax.scatter([last["RatchetDeg"] % PITCH], [last["PawlDeg"]], s=40, color=EVENT_COLOUR[last["Event"]],
                           edgecolor=INK, lw=0.6, zorder=5))
    return arts


def render_click(frames, parts, clear, out_gif, fps=24):
    fig = plt.figure(figsize=(12.8, 7.2), facecolor=SURFACE)
    gs = fig.add_gridspec(2, 2, width_ratios=[1.1, 1.0], left=0.02, right=0.98, top=0.86, bottom=0.12,
                          wspace=0.10, hspace=0.25)
    ax_main = fig.add_subplot(gs[:, 0])
    ax_zoom = fig.add_subplot(gs[0, 1])
    ax_space = fig.add_subplot(gs[1, 1])
    fig.text(0.02, 0.955, "The ratchet and click", fontsize=15, fontweight="bold", color=INK)
    fig.text(0.02, 0.92, "Every step, SQL Server asks one question of power.ClickMap: can the ratchet move without "
             "the metal overlapping? The click's spring does the rest.", fontsize=9, color=INK_2)
    caption = fig.text(0.02, 0.06, "", fontsize=10.5, fontweight="bold")
    status = fig.text(0.02, 0.025, "", fontsize=8.5, color=INK_2, family="monospace")
    draw_click_space(ax_space, clear)
    ax_space.set_title("configuration space: grey = ratchet and click overlap", fontsize=9, color=INK, loc="left")
    trail = []
    clicks = [0]

    def mech(ax, p, lim, detail):
        ax.clear()
        ax.set_facecolor(SURFACE)
        plot_geom(ax, p["Ratchet"], facecolor=GILT, edgecolor=GILT_EDGE, lw=0.4, zorder=2)
        plot_geom(ax, p["ClickSpring"], facecolor=STEEL, edgecolor=STEEL_EDGE, lw=0.3, zorder=3)
        plot_geom(ax, p["Pawl"], facecolor=STEEL, edgecolor=STEEL_EDGE, lw=0.4, zorder=4)
        ax.add_patch(plt.Circle(P.PAWL_PIVOT, 0.16, color=BLUED, zorder=5))
        ax.add_patch(plt.Circle((7.6, 1.9), 0.25, color=BLUED, zorder=5))
        ax.add_patch(plt.Circle((0, 0), 0.9, color=BLUED, zorder=5))
        ax.plot([-0.75, 0.75], [0, 0], color=SURFACE, lw=2.2, zorder=6)
        ax.set_xlim(*lim[:2])
        ax.set_ylim(*lim[2:])
        ax.set_aspect("equal")
        ax.set_xticks([])
        ax.set_yticks([])
        for sp in ax.spines.values():
            sp.set_visible(detail)
            sp.set_color("#d8d6d0")

    def update(k):
        nonlocal trail
        fr = frames[k]
        p = parts[fr["FrameNo"]]
        mech(ax_main, p, (-5.0, 8.4, -5.2, 5.2), False)
        mech(ax_zoom, p, (3.3, 5.6, -1.25, 0.85), True)
        ax_main.add_patch(plt.Rectangle((3.3, -1.25), 2.3, 2.1, fill=False, ec=INK_2, lw=0.6, ls=":", zorder=9))
        ax_zoom.set_title("where they meet", fontsize=9, color=INK, loc="left")
        for a in trail:
            a.remove()
        trail = _trail(ax_space, frames, k)
        if fr["Event"] == "click" and k > 0:
            clicks[0] += 1
        ev = fr["Event"]
        caption.set_text(EVENT_TEXT[ev])
        caption.set_color(EVENT_COLOUR[ev] if ev not in ("rest", "hold") else INK)
        status.set_text(f"frame {fr['FrameNo']:3d}   ratchet {fr['RatchetDeg']:6.2f} deg   click {fr['PawlDeg']:6.2f} deg"
                        f"   step: {ev}")
        return []

    anim = FuncAnimation(fig, update, frames=len(frames), blit=False)
    anim.save(out_gif, writer=PillowWriter(fps=fps), dpi=80, savefig_kwargs={"facecolor": SURFACE})
    print(f"wrote {out_gif} ({len(frames)} frames)")


def click_space_figure(frames, clear, path):
    fig, ax = plt.subplots(figsize=(9, 5.2), facecolor=SURFACE)
    draw_click_space(ax, clear)
    winding = [f for f in frames if f["Event"] in ("rest", "lift", "ride", "drop", "click")]
    letgo = [f for f in frames if f["Event"] in ("hold", "back", "locked")]
    for path_, width in ((winding, 5.0), (letgo, 1.8)):           # letting go retraces the slope: draw it on top
        for a, b in zip(path_, path_[1:]):
            x0, x1 = a["RatchetDeg"] % PITCH, b["RatchetDeg"] % PITCH
            if abs(x1 - x0) < PITCH / 2:
                ax.plot([x0, x1], [a["PawlDeg"], b["PawlDeg"]], color=EVENT_COLOUR[b["Event"]], lw=width,
                        solid_capstyle="round")
    last = frames[-1]
    x, y = last["RatchetDeg"] % PITCH, last["PawlDeg"]
    ax.scatter([x], [y], s=70, color=CRITICAL, edgecolor=INK, zorder=5)
    ax.annotate("locked: the next step back is grey,\nand so is every way up from here", (x, y), (x - 4.6, y + 0.9),
                fontsize=8.5, color=CRITICAL, arrowprops=dict(arrowstyle="-", color=CRITICAL, lw=0.8))
    for name, c in (("winding", BLUE), ("click", GOOD), ("let go", YELLOW), ("locked", CRITICAL)):
        ax.plot([], [], color=c, lw=3, label=name)
    ax.legend(fontsize=8, frameon=False, loc="lower right")
    ax.set_title("The click's configuration space (power.ClickMap): winding climbs the slope and drops;\n"
                 "letting go slides back down it to the wall, and stops.", fontsize=9, color=INK, loc="left")
    fig.tight_layout()
    fig.savefig(path, dpi=130, facecolor=SURFACE)
    print(f"wrote {path}")


# ------------------------------------------------------------------ the spring
def render_spring(frames, parts, out_gif, fps=24):
    fig = plt.figure(figsize=(12.8, 7.2), facecolor=SURFACE)
    gs = fig.add_gridspec(1, 2, width_ratios=[1.15, 1.0], left=0.02, right=0.98, top=0.86, bottom=0.05, wspace=0.08)
    ax = fig.add_subplot(gs[0, 0])
    ax_g = fig.add_subplot(gs[0, 1])
    fig.text(0.02, 0.955, "The mainspring", fontsize=15, fontweight="bold", color=INK)
    fig.text(0.02, 0.92, "350 mm of steel strip, 0.1 mm thick, in a barrel 10 mm across. "
             "Wound, it wraps the arbor; let down, it lies against the wall.", fontsize=9, color=INK_2)
    hours_max = max(f["Hours"] for f in frames)

    def update(k):
        fr = frames[k]
        p = parts[fr["FrameNo"]]
        ax.clear()
        ax.set_facecolor(SURFACE)
        ax.add_patch(plt.Circle((0, 0), P.RB, color="#f1ede4", zorder=0))
        plot_geom(ax, p["Barrel"], facecolor=GILT, edgecolor=GILT_EDGE, lw=0.4, zorder=2)
        plot_geom(ax, p["Spring"], edgecolor=BLUED, lw=0.55, zorder=3)
        plot_geom(ax, p["Arbor"], facecolor=STEEL, edgecolor=STEEL_EDGE, lw=0.4, zorder=4)
        ax.set_xlim(-6.1, 6.1)
        ax.set_ylim(-6.1, 6.1)
        ax.set_aspect("equal")
        ax.axis("off")

        g = ax_g
        g.clear()
        g.axis("off")
        g.set_xlim(0, 1)
        g.set_ylim(0, 1)
        winding = fr["Phase"] == "winding"
        g.text(0, 0.96, "WINDING: the crown turns the arbor; the click holds it" if winding else
               "RUNNING: the spring turns the barrel, and the barrel the train",
               fontsize=10.5, fontweight="bold", color=BLUE if winding else GOOD, va="top")
        g.text(0, 0.86, "power reserve", fontsize=9, color=INK_2, va="top")
        g.add_patch(plt.Rectangle((0, 0.74), 1.0, 0.07, color="#e4e1d8"))
        g.add_patch(plt.Rectangle((0, 0.74), fr["Hours"] / hours_max, 0.07, color=BLUE if winding else GOOD))
        g.text(0, 0.70, f"{fr['Hours']:5.1f} hours of {hours_max:.1f}", fontsize=12, family="monospace", color=INK,
               va="top", fontweight="bold")
        rows = [("arbor turned", f"{fr['ArborDeg'] / 360:8.3f} turns"),
                ("barrel turned", f"{fr['BarrelDeg'] / 360:8.3f} turns"),
                ("coils on the arbor", f"{fr['InnerTurns']:8.2f}"),
                ("coils on the wall", f"{fr['OuterTurns']:8.2f}"),
                ("spring, by STLength", f"{fr['Length']:8.2f} mm")]
        y = 0.55
        for label, val in rows:
            g.text(0, y, f"{label:22s}{val}", fontsize=9.5, family="monospace", color=INK, va="top")
            y -= 0.07
        g.text(0, 0.12, "Each barrel turn is 80 / 10 = 8 turns of the centre wheel: 8 hours.\n"
               "The barrel can turn 6.36 times before the spring is all on one side.",
               fontsize=8.5, color=INK_2, va="top")
        return []

    anim = FuncAnimation(fig, update, frames=len(frames), blit=False)
    anim.save(out_gif, writer=PillowWriter(fps=fps), dpi=80, savefig_kwargs={"facecolor": SURFACE})
    print(f"wrote {out_gif} ({len(frames)} frames)")


def fill_figure(rows, path):
    fig, ax = plt.subplots(figsize=(9, 4.8), facecolor=SURFACE)
    pct = [r[5] for r in rows]
    turns = [r[3] for r in rows]
    ax.plot(pct, turns, color=BLUE, lw=2.2, marker="o", ms=3.5)
    k = int(np.argmax(turns))
    ax.scatter([pct[k]], [turns[k]], s=70, color=CRITICAL, zorder=5)
    ax.annotate(f"{turns[k]:.2f} turns at {rows[k][0]:.0f} mm\n= {pct[k]:.1f}% full", (pct[k], turns[k]),
                (pct[k] + 6, turns[k] - 2.2), fontsize=9, color=INK, arrowprops=dict(arrowstyle="-", color=INK_2))
    ax.axvline(50, color=INK_2, lw=0.6, ls=":")
    ax.set_xlabel("how much of the space between arbor and wall the strip fills, %", fontsize=8, color=INK_2)
    ax.set_ylabel("turns the barrel can make", fontsize=8, color=INK_2)
    ax.tick_params(labelsize=7, colors=INK_2)
    ax.set_title("From power.Fill: pack the spring on the arbor, then on the wall, and measure both with "
                 "STLength. Best when it fills half the barrel.", fontsize=9, color=INK, loc="left")
    fig.tight_layout()
    fig.savefig(path, dpi=130, facecolor=SURFACE)
    print(f"wrote {path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", choices=["sim", "sql"], default="sim")
    ap.add_argument("--out", default=os.path.join("..", "out"))
    ap.add_argument("--fps", type=int, default=24)
    args = ap.parse_args()

    src = SqlSource() if args.source == "sql" else SimSource()
    clear = src.click_space()
    frames, parts = src.click()
    click_space_figure(frames, clear, os.path.join(args.out, "power_click_space.png"))
    fill_figure(src.fill(), os.path.join(args.out, "power_fill.png"))
    render_click(frames, parts, clear, os.path.join(args.out, "power_click.gif"), fps=args.fps)
    frames, parts = src.spring()
    render_spring(frames, parts, os.path.join(args.out, "power_spring.gif"), fps=args.fps)


if __name__ == "__main__":
    main()
