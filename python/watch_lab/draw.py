"""Matplotlib helpers: draw shapely geometry (as returned by SQL Server) directly."""
from __future__ import annotations

import numpy as np
from matplotlib.patches import PathPatch
from matplotlib.path import Path

# reference palette (dataviz skill defaults) + a few material colours
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK_2 = "#52514e"
BLUE = "#2a78d6"
GOOD = "#0ca30c"
CRITICAL = "#d03b3b"
YELLOW = "#eda100"
MAGENTA = "#e87ba4"
STEEL = "#8d98a3"
BRASS = "#c9a227"
NICKEL = "#b8bcc2"
ACRYLIC = "#bcd9f2"


def _ring_path(coords):
    arr = np.asarray(coords)[:, :2]
    codes = [Path.MOVETO] + [Path.LINETO] * (len(arr) - 2) + [Path.CLOSEPOLY]
    return arr, codes


def polygon_path(poly):
    verts, codes = _ring_path(poly.exterior.coords)
    verts, codes = [verts], [codes]
    for ring in poly.interiors:
        v, c = _ring_path(ring.coords)
        verts.append(v)
        codes.append(c)
    return Path(np.concatenate(verts), np.concatenate(codes))


def plot_geom(ax, g, **kw):
    """Draw any shapely geometry. Polygons honour holes (wheel hubs, chambers)."""
    if g is None or g.is_empty:
        return
    t = g.geom_type
    tr = kw.get("transform")
    if t == "Polygon":
        kw2 = dict(kw)
        lw = kw2.pop("lw", kw2.pop("linewidth", 0.8))
        ax.add_patch(PathPatch(polygon_path(g), lw=lw, **kw2))
    elif t in ("MultiPolygon", "MultiLineString", "GeometryCollection", "MultiPoint"):
        for part in g.geoms:
            plot_geom(ax, part, **kw)
    elif t in ("LineString", "LinearRing"):
        x, y = g.xy
        line_kw = dict(color=kw.get("edgecolor", kw.get("color", INK)),
                       lw=kw.get("lw", 1.2), ls=kw.get("ls", "-"), solid_capstyle="round", zorder=kw.get("zorder", 3))
        if tr is not None:
            line_kw["transform"] = tr
        ax.plot(x, y, **line_kw)
    elif t == "Point":
        pt_kw = dict(color=kw.get("edgecolor", INK), zorder=kw.get("zorder", 3))
        if tr is not None:
            pt_kw["transform"] = tr
        ax.plot(g.x, g.y, "o", **pt_kw)


def clean(ax):
    ax.set_aspect("equal")
    ax.set_xticks([])
    ax.set_yticks([])
    for s in ax.spines.values():
        s.set_visible(False)
    ax.set_facecolor(SURFACE)
