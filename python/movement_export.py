#!/usr/bin/env python3
"""Carry the PostGIS movement to the 3D viewer.

  python movement_export.py

Everything in the file was computed by the database: every solid (as
triangles), where each part sits, the order the watch comes apart in and
how far out each part goes in the exploded view. This script only moves it
from PostgreSQL to viewer/movement_data.js.

Connection: WATCH_PG, or localhost:5432/watchmaker as postgres (the
password comes from pgpass.conf).
"""
from __future__ import annotations

import json
import os
import time
from pathlib import Path

import psycopg

DSN = os.environ.get("WATCH_PG", "host=localhost port=5432 dbname=watchmaker user=postgres")
OUT = Path(__file__).resolve().parents[1] / "viewer" / "movement_data.js"


def main():
    t0 = time.time()
    with psycopg.connect(DSN) as conn:
        data = conn.execute("SELECT movement.export_json()::text").fetchone()[0]
    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text("window.MOVEMENT = " + data + ";\n", encoding="utf-8")

    d = json.loads(data)
    triangles = sum(len(pc["pos"]) // 9 for p in d["parts"] for pc in p["pieces"])
    print(f"{len(d['parts'])} parts, {triangles:,} triangles -> {OUT} "
          f"({OUT.stat().st_size / 1e6:.1f} MB, {time.time() - t0:.1f} s)")


if __name__ == "__main__":
    main()
