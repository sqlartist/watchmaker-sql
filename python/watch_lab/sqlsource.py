"""Talk to the real thing: SQL Server 2025, database Watchmaker.

Connection string comes from the WATCH_SQL environment variable, defaulting to
  Driver={ODBC Driver 18 for SQL Server};Server=localhost;Database=Watchmaker;
  Trusted_Connection=yes;TrustServerCertificate=yes;

Geometry crosses the wire as WKT (STAsText) and is parsed with shapely,
so the drawing code receives exactly what the database computed.
"""
from __future__ import annotations

import os
from collections import defaultdict

import numpy as np
from shapely import wkt

try:
    import pyodbc
except ImportError:  # pragma: no cover
    pyodbc = None

DEFAULT_CS = ("Driver={ODBC Driver 18 for SQL Server};Server=localhost;Database=Watchmaker;"
              "Trusted_Connection=yes;TrustServerCertificate=yes;")


def _conn(autocommit=True):
    if pyodbc is None:
        raise RuntimeError("pip install pyodbc  (and an ODBC Driver 18 for SQL Server)")
    return pyodbc.connect(os.environ.get("WATCH_SQL", DEFAULT_CS), autocommit=autocommit)


def _rows(cur):
    cols = [c[0] for c in cur.description]
    return [dict(zip(cols, r)) for r in cur.fetchall()]


def _exec_out(cn, sql, *params):
    """Run a batch whose LAST result set is SELECT @out; skip any earlier ones."""
    cur = cn.cursor()
    cur.execute(sql, *params)
    last = None
    while True:
        if cur.description:
            last = cur.fetchall()
        if not cur.nextset():
            break
    return last[0][0] if last else None


class SqlEscapement:
    """The escapement as SQL Server computed it."""

    def __init__(self):
        self.cn = _conn()

    def run(self, amplitude=110.0, beats=4):
        return _exec_out(self.cn, "SET NOCOUNT ON; DECLARE @r int; "
                                  "EXEC esc.usp_Run @Amplitude=?, @Beats=?, @RunId=@r OUTPUT; SELECT @r;",
                         amplitude, beats)

    def latest_run(self):
        cur = self.cn.cursor()
        cur.execute("SELECT MAX(RunId) FROM esc.Run")
        return cur.fetchone()[0]

    def frames(self, run_id):
        cur = self.cn.cursor()
        cur.execute("SELECT FrameNo, Beta, Phi, Theta, Phase, Stone, Face FROM esc.Frame "
                    "WHERE RunId = ? ORDER BY FrameNo", run_id)
        return _rows(cur)

    def parts(self, run_id):
        """{frame_no: {part: shapely geometry}}"""
        cur = self.cn.cursor()
        cur.execute("SELECT FrameNo, Part, Geom.STAsText() AS G FROM esc.FramePart WHERE RunId = ?", run_id)
        out = defaultdict(dict)
        for f, part, g in cur.fetchall():
            out[f][part] = wkt.loads(g)
        return out

    def static(self):
        cur = self.cn.cursor()
        cur.execute("SELECT Part, Geom.STAsText() FROM esc.Shape WHERE Part IN ('BankingPins', 'Roller')")
        return {p: wkt.loads(g) for p, g in cur.fetchall()}

    def wheel_fork(self):
        """The configuration space: Clear and Face as [I, J] arrays."""
        cur = self.cn.cursor()
        cur.execute("SELECT MAX(I) + 1, MAX(J) + 1 FROM esc.WheelFork")
        ni, nj = cur.fetchone()
        clear = np.zeros((ni, nj), dtype=bool)
        face = np.zeros((ni, nj), dtype=np.int8)
        cur.execute("SELECT I, J, Clear, Face FROM esc.WheelFork")
        for i, j, c, fc in cur.fetchall():
            clear[i, j], face[i, j] = bool(c), fc
        return clear, face

    def jewel_fork(self):
        cur = self.cn.cursor()
        cur.execute("SELECT MAX(B) + 1, MAX(J) + 1 FROM esc.JewelFork")
        nb, nj = cur.fetchone()
        clear = np.zeros((nb, nj), dtype=bool)
        cur.execute("SELECT B, J, Clear FROM esc.JewelFork")
        for b, j, c in cur.fetchall():
            clear[b, j] = bool(c)
        return clear

    def pin_clear(self):
        cur = self.cn.cursor()
        cur.execute("SELECT J, PinClear FROM esc.ForkPos ORDER BY J")
        return np.array([bool(c) for _, c in cur.fetchall()])

    def beats(self, run_id):
        cur = self.cn.cursor()
        cur.execute("SELECT * FROM esc.vBeat WHERE RunId = ? ORDER BY BeatNo", run_id)
        return _rows(cur)
