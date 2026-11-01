#!/usr/bin/env python3
"""Animate the going train, and draw the mesh figures.

  python train_viz.py                          # simulator: one minute of the train
  python train_viz.py --source sql             # draw SQL Server's latest cycloidal run
  python train_viz.py --source sql --figures   # also the mesh-space and velocity-ratio figures

Panels: the train (seen from the dial side) | the hands it drives | the
centre wheel and third pinion close up | what the database measured.
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
from shapely import wkt
from shapely.geometry import LineString, MultiLineString

from watch_lab import escapement as E
from watch_lab import train as T
from watch_lab.draw import BLUE, CRITICAL, INK, INK_2, SURFACE, plot_geom

GILT = "#dcbc62"
GILT_EDGE = "#8a6d1e"
STEEL = "#a7afb8"
STEEL_EDGE = "#5f6a76"
BLUED = "#2d4f8a"

WHEELS = ["EscapeWheel", "FourthWheel", "ThirdWheel", "CentreWheel"]       # bottom to top
SHADE = {"EscapeWheel": ("#8f99a4", STEEL_EDGE), "FourthWheel": ("#b39342", GILT_EDGE),   # lower = darker
         "ThirdWheel": ("#cdae55", GILT_EDGE), "CentreWheel": ("#e6ca72", GILT_EDGE)}
PINIONS = ["EscapePinion", "FourthPinion", "ThirdPinion"]
LABELS = {"centre": "centre wheel\n80 teeth", "third": "third\n75 / 10",
          "fourth": "fourth\n80 / 10", "escape": "escape\n15 / 8"}


# ------------------------------------------------------------------ sources
class SqlSource:
    def __init__(self):
        from watch_lab.sqlsource import _conn
        self.cur = _conn().cursor()
        c = self.cur
        c.execute("SELECT Arbor, X, Y FROM train.Arbor")
        self.arbors = {a: (x, y) for a, x, y in c.fetchall()}
        c.execute("SELECT Part, Geom.STAsText() FROM train.Shape WHERE MeshNo = 0")
        self.dial = {p: wkt.loads(g) for p, g in c.fetchall()}
        self._frames = None

    def _load(self):
        c = self.cur
        c.execute("SELECT MAX(RunId) FROM train.Run WHERE Profile = 'cycloidal' "
                  "AND EXISTS (SELECT 1 FROM train.FramePart p WHERE p.RunId = train.Run.RunId)")
        self.run_id = c.fetchone()[0]
        c.execute("SELECT FrameNo, Seconds, CentreDeg, ThirdDeg, FourthDeg, EscapeDeg FROM train.Frame "
                  "WHERE RunId = ? ORDER BY FrameNo", self.run_id)
        self._frames = [dict(zip(("FrameNo", "Seconds", "centre", "third", "fourth", "escape"), r))
                        for r in c.fetchall()]
        c.execute("SELECT FrameNo, Part, Geom.STAsText() FROM train.FramePart WHERE RunId = ?", self.run_id)
        self._parts = {}
        for f, p, g in c.fetchall():
            self._parts.setdefault(f, {})[p] = wkt.loads(g)

    def frames(self):
        if self._frames is None:
            self._load()
        return self._frames

    def parts_for(self, fr):
        return self._parts[fr["FrameNo"]]

    def mesh(self, mesh_no, profile):
        """(clear[I, J], edge[I]) for one mesh."""
        c = self.cur
        c.execute("SELECT I, J, Clear FROM train.MeshMap WHERE MeshNo = ? AND Profile = ?", mesh_no, profile)
        clear = np.zeros((T.NU, T.NV), dtype=bool)
        for i, j, v in c.fetchall():
            clear[i, j] = bool(v)
        c.execute("SELECT I, EdgeDeg FROM train.Edge WHERE MeshNo = ? AND Profile = ? ORDER BY I", mesh_no, profile)
        return clear, [e for _, e in c.fetchall()]

    def ratios(self):
        c = self.cur
        c.execute("SELECT MeshNo, Profile, WheelDeg, Ratio FROM train.vRatio ORDER BY MeshNo, Profile, I")
        out = {}
        for m, p, w, r in c.fetchall():
            out.setdefault((m, p), []).append((w, r))
        return out

    def summary(self):
        c = self.cur
        c.execute("SELECT * FROM train.vMesh ORDER BY MeshNo, Profile")
        cols = [d[0] for d in c.description]
        return [dict(zip(cols, r)) for r in c.fetchall()]


class SimSource:
    """The Python mirror: same teeth, same push edges, shapes placed the same way."""

    def __init__(self):
        self.tables = T.train_tables("cycloidal")
        self._frames = T.run(self.tables)
        self.arbors = T.arbor_positions()
        disp = {}
        for m in T.MESHES:
            rho = m.module * m.leaves / 4
            disp[m.wheel_arbor.capitalize() + "Wheel"] = (m.wheel_arbor, 1.0, _wheel_display(m, rho))
            disp[m.pinion_arbor.capitalize() + "Pinion"] = (m.pinion_arbor, 1.0, T.leaf_outline(m.leaves, m.module))
        disp["EscapeWheel"] = ("escape", 0.22, E.wheel_display())
        self._disp = disp
        self.dial = _dial()
        f0 = self._frames[0]
        self._hand0 = (f0["centre"], f0["fourth"])

    def frames(self):
        return [{"FrameNo": f["FrameNo"], "Seconds": f["Seconds"], **{a: f[a] for a in T.ARBORS}} for f in self._frames]

    def parts_for(self, fr):
        out = {name: T.place(g, fr[arbor], self.arbors[arbor], scale) for name, (arbor, scale, g) in self._disp.items()}
        out["MinuteHand"] = T.place(MINUTE, fr["centre"] - self._hand0[0], (0, 0))
        out["SecondsHand"] = T.place(SECOND, fr["fourth"] - self._hand0[1], (0, -4.6))
        return out


def _wheel_display(m, rho):
    import shapely
    rim = m.module * m.teeth / 2 - T.WHEEL_HF * m.module - 0.35
    arms = shapely.union_all([LineString([(0, 0), T.polar(45 + 90 * k, rim + 0.1)]).buffer(0.17) for k in range(4)])
    windows = T.circle((0, 0), rim, 180).difference(T.circle((0, 0), 0.55, 48)).difference(arms)
    return T.wheel_outline(m.teeth, m.module, rho).difference(windows).difference(T.circle((0, 0), 0.12, 16))


MINUTE = wkt.loads("POLYGON((-0.2 -1.4, 0.2 -1.4, 0.13 8.4, 0 9.2, -0.13 8.4, -0.2 -1.4))")
SECOND = wkt.loads("POLYGON((-0.06 -0.6, 0.06 -0.6, 0.04 2.2, 0 2.4, -0.04 2.2, -0.06 -0.6))")


def _dial():
    out = {}
    for name, y, r, w in (("Dial", 0.0, 9.9, 0.1), ("SubDial", -4.6, 2.75, 0.06)):
        ring = T.circle((0, y), r, 180).difference(T.circle((0, y), r - w, 180))
        ticks = MultiLineString([[T.polar(6 * k, r - w, (0, y)),
                                  T.polar(6 * k, r - w - (0.12 if k % 5 == 0 else 0.05) * r, (0, y))] for k in range(60)])
        out[name] = ring.union(ticks)
    return out


# ------------------------------------------------------------------ the animation
class Figure:
    def __init__(self, src):
        self.src = src
        self.frames = src.frames()
        self.f0 = self.frames[0]
        self.fig = plt.figure(figsize=(12.8, 7.6), facecolor=SURFACE)
        gs = self.fig.add_gridspec(2, 2, width_ratios=[1.15, 1.0], height_ratios=[1.15, 1.0],
                                   left=0.02, right=0.98, top=0.87, bottom=0.04, wspace=0.06, hspace=0.12)
        self.ax_train = self.fig.add_subplot(gs[:, 0])
        right = gs[0, 1].subgridspec(1, 2, wspace=0.08)
        self.ax_dial = self.fig.add_subplot(right[0, 0])
        self.ax_zoom = self.fig.add_subplot(right[0, 1])
        self.ax_text = self.fig.add_subplot(gs[1, 1])
        self.fig.text(0.02, 0.955, "The going train", fontsize=15, fontweight="bold", color=INK)
        self.fig.text(0.02, 0.92, "SQL Server turns the centre wheel at its real speed, 6 degrees a minute, and works out "
                      "every other arbor from where the teeth stop overlapping.", fontsize=9, color=INK_2)

    def _train(self, ax, parts, lim, labels):
        ax.clear()
        ax.set_facecolor(SURFACE)
        for name in WHEELS:
            face, edge = SHADE[name]
            plot_geom(ax, parts[name], facecolor=face, edgecolor=edge, lw=0.35, zorder=2 + WHEELS.index(name))
        for name in PINIONS:
            plot_geom(ax, parts[name], facecolor=STEEL, edgecolor=STEEL_EDGE, lw=0.35, zorder=8)
        for a, (x, y) in self.src.arbors.items():
            ax.add_patch(plt.Circle((x, y), 0.09, color=INK, zorder=9))
            if labels:
                dx, dy = {"centre": (-2.4, 2.9), "third": (2.1, 1.0), "fourth": (2.4, -0.4), "escape": (-3.6, -1.6)}[a]
                ax.annotate(LABELS[a], (x, y), (x + dx, y + dy), fontsize=8, color=INK_2, ha="center",
                            arrowprops=dict(arrowstyle="-", color="#b9b6ae", lw=0.6), zorder=10)
        ax.set_xlim(lim[0], lim[1])
        ax.set_ylim(lim[2], lim[3])
        ax.set_aspect("equal")
        ax.set_xticks([])
        ax.set_yticks([])
        for sp in ax.spines.values():
            sp.set_visible(not labels)
            sp.set_color("#d8d6d0")

    def redraw(self, k):
        fr = self.frames[k]
        parts = self.src.parts_for(fr)
        self._train(self.ax_train, parts, (-6.4, 9.8, -11.9, 6.0), True)
        third = self.src.arbors["third"]
        self._train(self.ax_zoom, parts, (third[0] - 1.6, third[0] + 0.5, third[1] - 0.6, third[1] + 1.5), False)
        self.ax_zoom.set_title("centre wheel driving the third pinion", fontsize=8, color=INK_2, loc="left")
        self.ax_train.add_patch(plt.Rectangle((third[0] - 1.6, third[1] - 0.6), 2.1, 2.1, fill=False, ec=INK_2,
                                              lw=0.6, ls=":", zorder=11))

        ax = self.ax_dial
        ax.clear()
        ax.set_facecolor(SURFACE)
        ax.add_patch(plt.Circle((0, 0), 9.9, color="#f4f1ea", zorder=0))
        for g in self.src.dial.values():
            plot_geom(ax, g, facecolor=INK, edgecolor=INK, lw=0.6, zorder=1)
        plot_geom(ax, parts["MinuteHand"], facecolor=BLUED, edgecolor=BLUED, lw=0.3, zorder=3)
        plot_geom(ax, parts["SecondsHand"], facecolor=BLUED, edgecolor=BLUED, lw=0.3, zorder=3)
        ax.add_patch(plt.Circle((0, 0), 0.35, color=BLUED, zorder=4))
        ax.add_patch(plt.Circle((0, -4.6), 0.15, color=BLUED, zorder=4))
        ax.set_xlim(-10.5, 10.5)
        ax.set_ylim(-10.5, 10.5)
        ax.set_aspect("equal")
        ax.axis("off")
        ax.set_title("minute hand on the centre arbor,\nseconds hand on the fourth", fontsize=8, color=INK_2, loc="left")

        ax = self.ax_text
        ax.clear()
        ax.axis("off")
        t = fr["Seconds"]
        turns = {a: abs(fr[a] - self.f0[a]) / 360 for a in T.ARBORS}
        ax.text(0.0, 0.97, f"elapsed  00:{int(t):02d}.{int((t % 1) * 10)}", fontsize=13, family="monospace",
                color=INK, va="top", fontweight="bold")
        rows = [("centre", "1 turn an hour"), ("third", ""), ("fourth", "carries the seconds hand"),
                ("escape", "15 teeth: 2 ticks a tooth")]
        y = 0.78
        ax.text(0.0, y, f"{'arbor':8s}{'turns so far':>14s}", fontsize=9, family="monospace", color=INK_2, va="top")
        for a, note in rows:
            y -= 0.1
            ax.text(0.0, y, f"{a:8s}{turns[a]:14.4f}   {note}", fontsize=9, family="monospace", color=INK, va="top")
        if turns["centre"] > 0:
            y -= 0.16
            ax.text(0.0, y, "measured, not typed:", fontsize=9, color=INK_2, va="top")
            y -= 0.09
            ax.text(0.0, y, f"fourth / centre = {turns['fourth'] / turns['centre']:8.3f}", fontsize=10.5,
                    family="monospace", color=BLUE, va="top", fontweight="bold")
            y -= 0.09
            ax.text(0.0, y, f"escape / centre = {turns['escape'] / turns['centre']:8.2f}", fontsize=10.5,
                    family="monospace", color=BLUE, va="top", fontweight="bold")


def render(src, out_gif, fps=24, show=False, first=None):
    fig = Figure(src)
    n = len(fig.frames) if first is None else first

    def update(i):
        fig.redraw(i)
        return []

    anim = FuncAnimation(fig.fig, update, frames=n, interval=1000 / fps, blit=False)
    if show:
        plt.show()
        return
    anim.save(out_gif, writer=PillowWriter(fps=fps), dpi=80, savefig_kwargs={"facecolor": SURFACE})
    print(f"wrote {out_gif} ({n} frames)")


# ------------------------------------------------------------------ figures
SPACE_CMAP = ListedColormap(["#c9ced4", SURFACE])


def mesh_space_figure(src, path):
    """Mesh 1's configuration space, cycloidal next to straight, with the push edge."""
    fig, axs = plt.subplots(1, 2, figsize=(11, 5.2), facecolor=SURFACE, sharey=True)
    pu, pv = 360 / 80, 360 / 10
    for ax, prof in zip(axs, ("cycloidal", "straight")):
        clear, edge = src.mesh(1, prof)
        ax.imshow(clear.T.astype(int), origin="lower", cmap=SPACE_CMAP, vmin=0, vmax=1, aspect="auto",
                  extent=(0, pu, 0, pv), interpolation="nearest")
        xs = [pu * i / T.NU for i in range(T.NU)]
        seg_x, seg_y = [xs[0]], [edge[0]]
        for x, e in zip(xs[1:], edge[1:]):
            if abs(e - seg_y[-1]) > pv / 2:
                ax.plot(seg_x, seg_y, color=BLUE, lw=2)
                seg_x, seg_y = [], []
            seg_x.append(x)
            seg_y.append(e)
        ax.plot(seg_x, seg_y, color=BLUE, lw=2, label="push edge: where the pinion is driven to")
        ax.set_title(f"{prof} teeth", fontsize=11, color=INK, loc="left")
        ax.set_xlabel("centre wheel, degrees within one tooth", fontsize=8, color=INK_2)
        ax.tick_params(labelsize=7, colors=INK_2)
    axs[0].set_ylabel("third pinion, degrees within one leaf", fontsize=8, color=INK_2)
    axs[0].legend(loc="upper left", fontsize=8, frameon=False)
    fig.suptitle("Mesh 1 from train.MeshMap: grey = a tooth inside a leaf. The white band's slope is the gear ratio; "
                 "its width is the backlash.", fontsize=9, color=INK, x=0.01, ha="left")
    fig.tight_layout()
    fig.savefig(path, dpi=130, facecolor=SURFACE)
    print(f"wrote {path}")


def ratio_figure(src, path):
    """The velocity ratio across one tooth, as % off its mean, from train.vRatio."""
    ratios = src.ratios()
    fig, ax = plt.subplots(figsize=(10, 4.6), facecolor=SURFACE)
    colours = {1: "#2a78d6", 2: "#0ca30c", 3: "#d03b3b"}
    names = {1: "centre -> third (80/10)", 2: "third -> fourth (75/10)", 3: "fourth -> escape (80/8)"}
    for (m, prof), pts in sorted(ratios.items()):
        pu = 360 / {1: 80, 2: 75, 3: 80}[m]
        mean = sum(r for _, r in pts) / len(pts)
        ax.plot([w / pu for w, _ in pts], [100 * (r / mean - 1) for _, r in pts], color=colours[m],
                lw=2 if prof == "cycloidal" else 1.2, ls="-" if prof == "cycloidal" else "--",
                label=f"{names[m]}, {prof}")
    ax.axhline(0, color=INK_2, lw=0.6)
    ax.text(0.99, 0.03, "fourth -> escape with straight teeth: jams (no clear position at all)",
            transform=ax.transAxes, ha="right", fontsize=8, color=CRITICAL)
    ax.set_xlabel("fraction of one wheel tooth", fontsize=8, color=INK_2)
    ax.set_ylabel("velocity ratio, % off its mean", fontsize=8, color=INK_2)
    ax.tick_params(labelsize=7, colors=INK_2)
    ax.legend(fontsize=7.5, frameon=False, ncol=2, loc="upper center")
    ax.set_title("How steadily each pinion is driven, from train.vRatio", fontsize=10, color=INK, loc="left")
    fig.tight_layout()
    fig.savefig(path, dpi=130, facecolor=SURFACE)
    print(f"wrote {path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", choices=["sim", "sql"], default="sim")
    ap.add_argument("--gif", default=os.path.join("..", "out", "train.gif"))
    ap.add_argument("--figures", action="store_true", help="SQL only: also the mesh-space and ratio figures")
    ap.add_argument("--fps", type=int, default=24)
    ap.add_argument("--first", type=int, default=None)
    ap.add_argument("--show", action="store_true")
    args = ap.parse_args()

    src = SqlSource() if args.source == "sql" else SimSource()
    if args.figures:
        for row in src.summary():
            print({k: (float(v) if hasattr(v, "as_tuple") else v) for k, v in row.items()})
        mesh_space_figure(src, os.path.join(os.path.dirname(args.gif), "train_mesh_space.png"))
        ratio_figure(src, os.path.join(os.path.dirname(args.gif), "train_ratio.png"))
    render(src, args.gif, fps=args.fps, show=args.show, first=args.first)


if __name__ == "__main__":
    main()
