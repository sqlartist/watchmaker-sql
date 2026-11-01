#!/usr/bin/env python3
"""Animate the motion works over twelve hours, and draw the steadiness figure.

  python motion_viz.py                   # simulator
  python motion_viz.py --source sql      # SQL Server's latest run, plus motion_ratio.png

Panels: the dial | the lower level (cannon pinion -> minute wheel) | the
upper level (minute pinion -> hour wheel) | what the database measured.
"""
from __future__ import annotations

import argparse
import os
import sys

import matplotlib

if "--show" not in sys.argv:
    matplotlib.use("Agg")
import matplotlib.pyplot as plt
import shapely
from matplotlib.animation import FuncAnimation, PillowWriter
from shapely import wkt
from shapely.geometry import LineString, MultiLineString

from watch_lab import motion as M
from watch_lab.draw import BLUE, CRITICAL, INK, INK_2, SURFACE, plot_geom

GILT = "#dcbc62"
GILT_EDGE = "#8a6d1e"
STEEL = "#a7afb8"
STEEL_EDGE = "#5f6a76"
BLUED = "#2d4f8a"
GOOD = "#0ca30c"

MINUTE = wkt.loads("POLYGON((-0.22 -1.4, 0.22 -1.4, 0.14 8.6, 0 9.3, -0.14 8.6, -0.22 -1.4))")
HOUR = wkt.loads("POLYGON((-0.32 -1.2, 0.32 -1.2, 0.26 5.4, 0 6.2, -0.26 5.4, -0.32 -1.2))")


# ------------------------------------------------------------------ sources
class SqlSource:
    def __init__(self):
        from watch_lab.sqlsource import _conn
        c = self.cur = _conn().cursor()
        c.execute("SELECT MAX(r.RunId) FROM motion.Run r WHERE EXISTS (SELECT 1 FROM motion.FramePart p WHERE p.RunId = r.RunId)")
        run_id = c.fetchone()[0]
        c.execute("SELECT FrameNo, Hours, CentreDeg, MinuteDeg, HourDeg FROM motion.Frame WHERE RunId = ? ORDER BY FrameNo",
                  run_id)
        self._frames = [dict(zip(("FrameNo", "Hours", "centre", "minute", "hour"), r)) for r in c.fetchall()]
        c.execute("SELECT FrameNo, Part, Geom.STAsText() FROM motion.FramePart WHERE RunId = ?", run_id)
        self._parts = {}
        for f, p, g in c.fetchall():
            self._parts.setdefault(f, {})[p] = wkt.loads(g)
        c.execute("SELECT Arbor, X, Y FROM motion.Arbor")
        self.arbors = {a: (x, y) for a, x, y in c.fetchall()}
        c.execute("SELECT Geom.STAsText() FROM motion.Shape WHERE MeshNo = 0 AND Part = 'Dial'")
        self.dial = wkt.loads(c.fetchone()[0])

    def frames(self):
        return self._frames

    def parts_for(self, fr):
        return self._parts[fr["FrameNo"]]

    def ratios(self):
        """{label: [(fraction of a driver tooth, % off mean)]} - the motion works next to episode 2's going train."""
        c = self.cur
        out = {}
        c.execute("SELECT MeshNo, I, Ratio FROM motion.vRatio ORDER BY MeshNo, I")
        rows = c.fetchall()
        for m in M.MESHES:
            pts = [(i, r) for no, i, r in rows if no == m.no]
            mean = sum(r for _, r in pts) / len(pts)
            out[f"motion works: {m.driver_arbor} {m.driver_teeth} -> {m.driven_arbor} {m.driven_teeth}, both cycloidal"] = \
                [(i / M.NU, 100 * (r / mean - 1)) for i, r in pts]
        c.execute("SELECT I, Ratio FROM train.vRatio WHERE MeshNo = 1 AND Profile = 'cycloidal' ORDER BY I")
        pts = c.fetchall()
        if pts:
            mean = sum(r for _, r in pts) / len(pts)
            out["going train: centre 80 -> third pinion 10, round-tipped leaves"] = \
                [(i / 60, 100 * (r / mean - 1)) for i, r in pts]
        return out


class SimSource:
    def __init__(self):
        self.tabs = M.tables()
        self._frames = M.run(self.tabs)
        self.arbors = M.arbor_positions()
        disp = {}
        for m in M.MESHES:
            a_d, a_n = m.module * m.driver_teeth / 2, m.module * m.driven_teeth / 2
            disp[m.no] = (M.gear_outline(m.driver_teeth, m.module, a_n / 2, M.DISPLAY_FLANK_PTS),
                          M.gear_outline(m.driven_teeth, m.module, a_d / 2, M.DISPLAY_FLANK_PTS))
        self._disp = {"CannonPinion": ("centre", disp[1][0].difference(M.circle((0, 0), 0.18, 24))),
                      "MinuteWheel": ("minute", disp[1][1].difference(M.circle((0, 0), 0.15, 24))),
                      "MinutePinion": ("minute", disp[2][0].difference(M.circle((0, 0), 0.15, 24))),
                      "HourWheel": ("hour", disp[2][1].difference(M.circle((0, 0), 0.5, 48)))}
        ticks = MultiLineString([[M.polar(6 * k, 9.8), M.polar(6 * k, 9.35)] for k in range(60)])
        marks = [LineString([M.polar(30 * k, 9.8), M.polar(30 * k, 8.4)]).buffer(0.22) for k in range(12)]
        ring = M.circle((0, 0), 9.9, 180).difference(M.circle((0, 0), 9.8, 180))
        self.dial = shapely.union_all([ring, ticks] + marks)
        self._f0 = self._frames[0]

    def frames(self):
        return self._frames

    def parts_for(self, fr):
        out = {name: M.place(g, fr[arbor], self.arbors[arbor]) for name, (arbor, g) in self._disp.items()}
        out["MinuteHand"] = M.place(MINUTE, fr["centre"] - self._f0["centre"], (0, 0))
        out["HourHand"] = M.place(HOUR, fr["hour"] - self._f0["hour"], (0, 0))
        return out


# ------------------------------------------------------------------ the animation
def render(src, out_gif, fps=24):
    frames = src.frames()
    f0 = frames[0]
    fig = plt.figure(figsize=(12.8, 7.2), facecolor=SURFACE)
    gs = fig.add_gridspec(2, 3, width_ratios=[1.3, 0.75, 0.8], left=0.02, right=0.98, top=0.86, bottom=0.04,
                          wspace=0.08, hspace=0.18)
    ax_dial = fig.add_subplot(gs[:, 0])
    ax_low = fig.add_subplot(gs[0, 1])
    ax_up = fig.add_subplot(gs[1, 1])
    ax_txt = fig.add_subplot(gs[:, 2])
    fig.text(0.02, 0.955, "The motion works", fontsize=15, fontweight="bold", color=INK)
    fig.text(0.02, 0.92, "Twelve hours. SQL Server turns the cannon pinion with the minute hand and reads the hour "
             "hand through two meshes of teeth. Nothing in it says 12.", fontsize=9, color=INK_2)
    cx, cy = src.arbors["minute"]

    def level(ax, parts, names, title):
        ax.clear()
        ax.set_facecolor(SURFACE)
        for name, face, edge in names:
            plot_geom(ax, parts[name], facecolor=face, edgecolor=edge, lw=0.35, zorder=2)
        for a in ("centre", "minute"):
            ax.add_patch(plt.Circle(src.arbors[a], 0.07, color=INK, zorder=4))
        ax.plot([0, cx], [0, cy], color=CRITICAL, lw=0.7, ls=":", zorder=3)
        ax.text(cx / 2 + 0.25, cy / 2 - 0.05, "3 mm", fontsize=7, color=CRITICAL, rotation=45)
        ax.set_xlim(-4.9, 3.1)
        ax.set_ylim(-4.9, 3.1)
        ax.set_aspect("equal")
        ax.set_xticks([])
        ax.set_yticks([])
        for sp in ax.spines.values():
            sp.set_color("#d8d6d0")
        ax.set_title(title, fontsize=8.5, color=INK, loc="left")

    def update(k):
        fr = frames[k]
        p = src.parts_for(fr)
        ax = ax_dial
        ax.clear()
        ax.set_facecolor(SURFACE)
        ax.add_patch(plt.Circle((0, 0), 9.9, color="#f4f1ea", zorder=0))
        plot_geom(ax, src.dial, facecolor=INK, edgecolor=INK, lw=0.6, zorder=1)
        plot_geom(ax, p["HourHand"], facecolor=BLUED, edgecolor=BLUED, lw=0.3, zorder=3)
        plot_geom(ax, p["MinuteHand"], facecolor=BLUED, edgecolor=BLUED, lw=0.3, zorder=4)
        ax.add_patch(plt.Circle((0, 0), 0.45, color=BLUED, zorder=5))
        ax.set_xlim(-10.4, 10.4)
        ax.set_ylim(-10.4, 10.4)
        ax.set_aspect("equal")
        ax.axis("off")

        level(ax_low, p, [("MinuteWheel", GILT, GILT_EDGE), ("CannonPinion", STEEL, STEEL_EDGE)],
              "lower level: cannon pinion 12 drives minute wheel 36")
        level(ax_up, p, [("HourWheel", GILT, GILT_EDGE), ("MinutePinion", STEEL, STEEL_EDGE)],
              "upper level: minute pinion 10 drives hour wheel 40")

        t = ax_txt
        t.clear()
        t.axis("off")
        t.set_xlim(0, 1)
        t.set_ylim(0, 1)
        h = fr["Hours"]
        hh, mm = int(h) % 12 or 12, int(round((h % 1) * 60)) % 60
        if int(round((h % 1) * 60)) == 60:
            hh = (hh % 12) + 1
        t.text(0.02, 0.97, f"{hh:2d}:{mm:02d}", fontsize=26, family="monospace", fontweight="bold", color=INK, va="top")
        t.text(0.02, 0.82, f"{h:5.2f} hours gone", fontsize=9, color=INK_2, va="top")
        turns = {a: abs(fr[a] - f0[a]) / 360 for a in ("centre", "minute", "hour")}
        y = 0.70
        for label, a in (("minute hand", "centre"), ("minute wheel", "minute"), ("hour hand", "hour")):
            t.text(0.02, y, f"{label:13s}{turns[a]:8.3f} turns", fontsize=9.5, family="monospace", color=INK, va="top")
            y -= 0.07
        if turns["hour"] > 0:
            t.text(0.02, y - 0.06, "measured, not typed:", fontsize=9, color=INK_2, va="top")
            t.text(0.02, y - 0.13, f"minute / hour = {turns['centre'] / turns['hour']:7.3f}", fontsize=11,
                   family="monospace", color=BLUE, fontweight="bold", va="top")
        t.text(0.02, 0.12, "The hour wheel rides on the cannon pinion,\nso both meshes must be the same length:\n"
               "0.125 x 48 / 2 = 0.12 x 50 / 2 = 3 mm.", fontsize=8.5, color=INK_2, va="top")
        return []

    anim = FuncAnimation(fig, update, frames=len(frames), blit=False)
    anim.save(out_gif, writer=PillowWriter(fps=fps), dpi=80, savefig_kwargs={"facecolor": SURFACE})
    print(f"wrote {out_gif} ({len(frames)} frames)")


def ratio_figure(src, path):
    fig, ax = plt.subplots(figsize=(10, 4.4), facecolor=SURFACE)
    colours = [BLUE, GOOD, CRITICAL]
    for (label, pts), c in zip(src.ratios().items(), colours):
        ax.plot([x for x, _ in pts], [y for _, y in pts], color=c, lw=2.2 if "motion" in label else 1.6,
                ls="-" if "motion" in label else "--", label=label)
    ax.axhline(0, color=INK_2, lw=0.6)
    ax.axhspan(-0.2, 0.2, color="#e9e6dd", zorder=0)
    ax.text(0.995, 0.25, "measurement resolution (+/-0.2%)", fontsize=7.5, color=INK_2, ha="right",
            transform=ax.get_yaxis_transform())
    ax.set_xlabel("fraction of one driving tooth", fontsize=8, color=INK_2)
    ax.set_ylabel("velocity ratio, % off its mean", fontsize=8, color=INK_2)
    ax.tick_params(labelsize=7, colors=INK_2)
    ax.legend(fontsize=8, frameon=False, loc="lower left")
    ax.set_title("Proper cycloids on both gears hold the ratio dead steady (motion.vRatio); the going train's "
                 "round-tipped pinions don't (train.vRatio)", fontsize=9, color=INK, loc="left")
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
    if args.source == "sql":
        ratio_figure(src, os.path.join(args.out, "motion_ratio.png"))
    render(src, os.path.join(args.out, "motion.gif"), fps=args.fps)


if __name__ == "__main__":
    main()
