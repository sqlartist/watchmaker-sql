#!/usr/bin/env python3
"""Animate the Swiss lever escapement.

  python escapement_viz.py                         # simulator, opens nothing, writes the GIF
  python escapement_viz.py --source sql            # draw SQL Server's latest run
  python escapement_viz.py --source sql --run      # run esc.usp_Run first, then draw it
  python escapement_viz.py --space space.png       # the configuration-space figure on its own

Panels: the mechanism | a close-up of the pallets | the escapement's
configuration space (wheel angle within one tooth x fork angle), with the
run's path through it | what the wheel is touching.
"""
from __future__ import annotations

import argparse
import os
import sys

import matplotlib

if "--show" not in sys.argv:
    matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.animation import FuncAnimation, PillowWriter
from matplotlib.colors import ListedColormap
from shapely import affinity

from watch_lab import escapement as E
from watch_lab.draw import BLUE, CRITICAL, INK, INK_2, SURFACE, YELLOW, plot_geom

STEEL = "#9aa3ad"
STEEL_DARK = "#6f7a86"
RUBY = "#c4314b"
GOLD = "#c9a227"
BLUED = "#2d4f8a"
BRASS = "#b8902a"

PHASE_COLOUR = {"locked": INK_2, "unlocking": YELLOW, "impulse": BLUE, "drop": CRITICAL}
PHASE_TEXT = {
    "locked":    "LOCKED - a tooth rests on a stone's locking face; draw holds the fork on its banking",
    "unlocking": "UNLOCKING - the jewel swings the fork; the stone slides off the tooth, pushing the wheel back",
    "impulse":   "IMPULSE - the tooth slides across the stone's sloping face and kicks the fork (and the balance)",
    "drop":      "DROP - the tooth falls off the stone; the wheel spins free until the other stone catches it",
}


# ------------------------------------------------------------------ sources
class SimSource:
    """The Python mirror: same shapes, same grids, same solver."""

    def __init__(self):
        self.maps = E.clearance_maps()
        self.frames_ = [vars(f) for f in E.run(maps=self.maps)]
        steel, entry, exit_ = E.fork_at(0.0)
        self._base = {"Wheel": E.wheel_display(), "Fork": steel, "EntryStone": entry, "ExitStone": exit_,
                      "Balance": E.balance_at(0.0)}
        self.space = (self.maps[0], self.maps[3])

    def frames(self):
        return [{"FrameNo": f["no"], "Beta": f["beta"], "Phi": f["phi"], "Theta": f["theta"],
                 "Phase": f["phase"], "Stone": f["stone"], "Face": f["face"]} for f in self.frames_]

    def parts_for(self, fr):
        b = self._base
        return {"Wheel": affinity.rotate(b["Wheel"], fr["Theta"], origin=(0, 0)),
                "Fork": affinity.rotate(b["Fork"], fr["Phi"], origin=E.P),
                "EntryStone": affinity.rotate(b["EntryStone"], fr["Phi"], origin=E.P),
                "ExitStone": affinity.rotate(b["ExitStone"], fr["Phi"], origin=E.P),
                "Balance": affinity.rotate(b["Balance"], fr["Beta"], origin=E.B),
                "Jewel": E.jewel_at(fr["Beta"]),
                "Hairspring": E.hairspring_at(fr["Beta"])}

    def static(self):
        return {"BankingPins": E.banking_pins()[0].union(E.banking_pins()[1]), "Roller": E.roller_at(0)}

    def beats(self):
        return E.measure([E.Frame(**f) for f in self.frames_])


class SqlSource:
    def __init__(self, run=False):
        from watch_lab.sqlsource import SqlEscapement
        self.db = SqlEscapement()
        self.run_id = self.db.run() if run else self.db.latest_run()
        self._frames = self.db.frames(self.run_id)
        self._parts = self.db.parts(self.run_id)
        self.space = self.db.wheel_fork()

    def frames(self):
        return self._frames

    def parts_for(self, fr):
        return self._parts[fr["FrameNo"]]

    def static(self):
        return self.db.static()

    def beats(self):
        return self.db.beats(self.run_id)


# ------------------------------------------------------------------ drawing
def space_image(clear, face):
    """0 blocked, 1 clear, 2 touching a locking face, 3 touching an impulse face (rows = fork, cols = wheel)."""
    img = np.where(clear, 1, 0).astype(np.int8)
    img[clear & np.isin(face, (1, 3))] = 2
    img[clear & np.isin(face, (2, 4))] = 3
    return img.T


SPACE_CMAP = ListedColormap(["#c9ced4", SURFACE, "#e9b8c1", "#b9d2ee"])


def draw_space(ax, clear, face, title=True):
    ax.imshow(space_image(clear, face), origin="lower", cmap=SPACE_CMAP, vmin=0, vmax=3, aspect="auto",
              extent=(0, E.PITCH, E.PHI_MIN - E.PHI_STEP / 2, E.PHI_MAX + E.PHI_STEP / 2), interpolation="nearest")
    ax.set_xlim(0, E.PITCH)
    ax.set_ylim(-7.5, 7.5)
    ax.set_xlabel("escape wheel, degrees within one tooth", fontsize=8, color=INK_2)
    ax.set_ylabel("pallet fork, degrees", fontsize=8, color=INK_2)
    ax.tick_params(labelsize=7, colors=INK_2)
    for s in ax.spines.values():
        s.set_color("#d8d6d0")
    if title:
        ax.set_title("Configuration space: grey = metal in metal", fontsize=9, color=INK, loc="left")


def _trail(frames, upto, n=90):
    xs, ys, cs = [], [], []
    for fr in frames[max(0, upto - n):upto + 1]:
        xs.append(fr["Theta"] % E.PITCH)
        ys.append(fr["Phi"])
        cs.append(PHASE_COLOUR[fr["Phase"]])
    return xs, ys, cs


class Figure:
    def __init__(self, src, title):
        self.src = src
        self.frames = src.frames()
        self.static = src.static()
        self.fig = plt.figure(figsize=(12.8, 7.6), facecolor=SURFACE)
        gs = self.fig.add_gridspec(2, 3, width_ratios=[1.0, 0.62, 0.62], height_ratios=[1.05, 1],
                                   left=0.03, right=0.98, top=0.86, bottom=0.12, wspace=0.08, hspace=0.30)
        self.ax_main = self.fig.add_subplot(gs[:, 0])
        self.ax_exit = self.fig.add_subplot(gs[0, 1])
        self.ax_entry = self.fig.add_subplot(gs[0, 2])
        self.ax_space = self.fig.add_subplot(gs[1, 1:])
        self.fig.text(0.03, 0.955, title, fontsize=15, fontweight="bold", color=INK)
        self.fig.text(0.03, 0.925, "Every position below came out of SQL Server's spatial maps: "
                      "the balance is driven, the fork and wheel go wherever the metal lets them.",
                      fontsize=9, color=INK_2)
        self.caption = self.fig.text(0.03, 0.055, "", fontsize=10.5, color=INK, fontweight="bold")
        self.status = self.fig.text(0.03, 0.022, "", fontsize=8.5, color=INK_2, family="monospace")
        draw_space(self.ax_space, *src.space)
        self.trail_line = None

    def _mechanism(self, ax, parts, lim, detail):
        ax.clear()
        ax.set_facecolor(SURFACE)
        plot_geom(ax, parts["Balance"], facecolor=GOLD, edgecolor="#7d6416", lw=0.4, alpha=0.35, zorder=1)
        plot_geom(ax, self.static["Roller"], facecolor="#e7e3da", edgecolor="#9b968a", lw=0.4, zorder=2)
        plot_geom(ax, parts["Hairspring"], edgecolor=BLUED, lw=0.6 if detail else 0.45, zorder=2)
        plot_geom(ax, parts["Wheel"], facecolor=STEEL, edgecolor=STEEL_DARK, lw=0.4, zorder=3)
        plot_geom(ax, parts["Fork"], facecolor="#b3bac2", edgecolor=STEEL_DARK, lw=0.4, zorder=4)
        plot_geom(ax, parts["EntryStone"], facecolor=RUBY, edgecolor="#7a1427", lw=0.4, zorder=5)
        plot_geom(ax, parts["ExitStone"], facecolor=RUBY, edgecolor="#7a1427", lw=0.4, zorder=5)
        plot_geom(ax, parts["Jewel"], facecolor=RUBY, edgecolor="#7a1427", lw=0.4, zorder=6)
        plot_geom(ax, self.static["BankingPins"], facecolor=BRASS, edgecolor="#6b5313", lw=0.4, zorder=6)
        ax.set_xlim(lim[0], lim[1])
        ax.set_ylim(lim[2], lim[3])
        ax.set_aspect("equal")
        ax.set_xticks([])
        ax.set_yticks([])
        for sp in ax.spines.values():
            sp.set_visible(detail)
            sp.set_color("#d8d6d0")

    def redraw(self, k):
        fr = self.frames[k]
        parts = self.src.parts_for(fr)
        self._mechanism(self.ax_main, parts, (-11.5, 11.5, -10.8, 33.2), False)
        for ax, cx, name in ((self.ax_exit, -5.3, "Exit stone"), (self.ax_entry, 5.3, "Entry stone")):
            self._mechanism(ax, parts, (cx - 2.9, cx + 2.9, 7.0, 12.8), True)
            active = fr["Stone"] == name.split()[0].lower()
            ax.set_title(name + ("  ●" if active else ""), fontsize=9, loc="left",
                         color=PHASE_COLOUR[fr["Phase"]] if active and fr["Phase"] != "locked" else INK)
            self.ax_main.add_patch(plt.Rectangle((cx - 2.9, 7.0), 5.8, 5.8, fill=False, ec=INK_2, lw=0.6,
                                                 ls=":", zorder=9))

        if self.trail_line is not None:
            for a in self.trail_line:
                a.remove()
        xs, ys, cs = _trail(self.frames, k)
        segs = []
        for (x0, y0, x1, y1, c) in zip(xs, ys, xs[1:], ys[1:], cs[1:]):
            if abs(x1 - x0) < E.PITCH / 2:                 # don't draw the wrap-around
                segs += self.ax_space.plot([x0, x1], [y0, y1], color=c, lw=1.6, solid_capstyle="round")
        segs.append(self.ax_space.scatter([xs[-1]], [ys[-1]], s=46, color=cs[-1], edgecolor=INK, lw=0.6, zorder=5))
        self.trail_line = segs

        phase = fr["Phase"]
        self.caption.set_text(PHASE_TEXT[phase])
        self.caption.set_color(PHASE_COLOUR[phase] if phase != "locked" else INK)
        touch = f"{fr['Stone']} stone, {fr['Face']} face" if fr["Stone"] else "nothing"
        self.status.set_text(f"frame {fr['FrameNo']:3d}   balance {fr['Beta']:7.2f} deg   "
                             f"fork {fr['Phi']:5.1f} deg   wheel {fr['Theta']:6.1f} deg   touching: {touch}")


def render(src, out_gif, title, fps=24, show=False, frames=None):
    fig = Figure(src, title)
    idx = list(range(len(fig.frames))) if frames is None else frames

    def update(i):
        fig.redraw(idx[i])
        return []

    if show:
        fig._anim = FuncAnimation(fig.fig, update, frames=len(idx), interval=1000 / fps, blit=False)
        plt.show()
        return
    anim = FuncAnimation(fig.fig, update, frames=len(idx), interval=1000 / fps, blit=False)
    anim.save(out_gif, writer=PillowWriter(fps=fps), dpi=80, savefig_kwargs={"facecolor": SURFACE})
    print(f"wrote {out_gif} ({len(idx)} frames)")


def space_figure(src, path):
    """The article figure: the configuration space with one full cycle traced through it."""
    frames = src.frames()
    fig, ax = plt.subplots(figsize=(10, 5.6), facecolor=SURFACE)
    draw_space(ax, *src.space, title=False)
    for a, b in zip(frames, frames[1:]):
        x0, x1 = a["Theta"] % E.PITCH, b["Theta"] % E.PITCH
        if abs(x1 - x0) < E.PITCH / 2:
            ax.plot([x0, x1], [a["Phi"], b["Phi"]], color=PHASE_COLOUR[b["Phase"]], lw=2.2, solid_capstyle="round")
    for name, c in PHASE_COLOUR.items():
        ax.plot([], [], color=c, lw=3, label=name)
    ax.legend(loc="upper right", fontsize=8, frameon=False)
    ax.set_title("The Swiss lever's configuration space, from esc.WheelFork. Grey: the wheel and fork overlap. "
                 "Pink / blue: touching a locking / impulse face.", fontsize=9, color=INK, loc="left")
    fig.tight_layout()
    fig.savefig(path, dpi=130, facecolor=SURFACE)
    print(f"wrote {path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", choices=["sim", "sql"], default="sim")
    ap.add_argument("--run", action="store_true", help="SQL only: run esc.usp_Run first")
    ap.add_argument("--gif", default=os.path.join("..", "out", "escapement.gif"))
    ap.add_argument("--space", help="also write the configuration-space figure to this PNG")
    ap.add_argument("--fps", type=int, default=24)
    ap.add_argument("--show", action="store_true")
    ap.add_argument("--first", type=int, default=None, help="only the first N frames (quick look)")
    args = ap.parse_args()

    src = SqlSource(run=args.run) if args.source == "sql" else SimSource()
    for b in src.beats():
        print({k: (round(float(v), 2) if isinstance(v, (float,)) or hasattr(v, "as_tuple") else v)
               for k, v in b.items() if k not in ("theta0", "phi_locked", "phi_unlocked", "phi_impulse_end")})
    if args.space:
        space_figure(src, args.space)
    frames = list(range(args.first)) if args.first else None
    render(src, args.gif, "The Swiss lever escapement", fps=args.fps, show=args.show, frames=frames)


if __name__ == "__main__":
    main()
