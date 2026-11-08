# The Watchmaker

> **Read the full story:** For the full breakdown of how this project came to be and the initial metrics, check out the article on [Medium](https://medium.com/@trevor.dwyer/the-watchmaker-building-a-mechanical-watch-in-a-database-275dae48e0b5). Follow me there for future updates! You can also read it free on [my blog](https://sqlartist.github.io/posts/the-watchmaker-building-a-mechanical-watch-in-a-database/).


A mechanical watch, built from geometry in a database, inspired by Bartosz
Ciechanowski's [Mechanical Watch](https://ciechanow.ski/mechanical-watch/).

Two parts:

1. **SQL Server 2025, in 2D.** The core principles, one episode each, with the
   mechanism modelled in `geometry` and a Python front end drawing what the
   database computed. All four episodes are done: 1, the **Swiss lever
   escapement**; 2, the **going train**; 3, **power** (mainspring, barrel,
   ratchet and click); 4, the **motion works** (minute hand to hour hand).
2. **PostgreSQL + PostGIS, in 3D.** Two episodes are done:
   - Episode 5, the **explodable movement**: every part is a solid that the
     database builds, places, checks for clashes and takes apart. A three.js
     viewer lets you turn it and pull it apart.
   - Episode 6, **it runs**: Part 1's kinematics, ported to PostGIS, drive a
     minute of the watch's life, frame by frame.

The same approach as the Feynman safecracker: model the metal, not the maths.

---

## Episode 1: the escapement

Every part is a shape in the drawing plane (units: escape wheel tip radius = 10):

| Part | Built by | How it moves |
|---|---|---|
| Escape wheel, 15 club teeth | `esc.fn_WheelOutline` | turns anticlockwise about O |
| Pallet fork + two ruby stones | `esc.fn_PalletBody`, `esc.fn_Lever`, `esc.fn_Stone` | rocks about the pallet arbor P |
| Banking pins | `esc.fn_BankingPins` | fixed |
| Balance, impulse jewel, hairspring | `esc.fn_Balance`, `esc.fn_Jewel`, `esc.fn_Hairspring` | swings about the staff B |

The physics is one spatial question, asked once for every pose on a grid
(`esc.usp_BuildMaps`, ~97,000 `STIntersects`, about 6 seconds):

| Map | Question |
|---|---|
| `esc.WheelFork.Clear` | do the wheel (0..24 deg, 0.1 steps) and fork (-8..+8 deg) overlap? |
| `esc.WheelFork.Face` | which stone face would the wheel hit one step further on? |
| `esc.JewelFork.Clear` | does the impulse jewel (-45..+45 deg of balance) overlap the lever? |
| `esc.ForkPos.PinClear` | is the fork clear of the banking pins? |

`esc.usp_Run` then drives the balance and lets the fork and wheel go
wherever those maps allow. That is a relational search, 76 ms for 413 frames.
The jewel shoves the fork. The fork drifts the way the tooth pushes it (draw on a
locking face, impulse on an impulse face). The wheel turns until it touches a
stone. Nothing says "lock", "impulse" or "drop". `esc.vBeat` measures them afterwards:

| per beat | designed | measured by `esc.vBeat` |
|---|---|---|
| lock (fork) | 3 deg | 2.6 / 3.3 deg |
| lift (fork) | 8 deg | 7.9 / 8.2 deg |
| recoil while unlocking (wheel) | | -0.2 deg |
| impulse (wheel) | 10 deg | 9.6 / 10.0 deg |
| drop (wheel) | 2 deg | 2.2 / 2.5 deg |
| advance (wheel) | 12 deg | 11.9 / 12.1 deg |

### Running it

```
sqlcmd -S localhost -E -C -i sql/01_schema.sql
sqlcmd -S localhost -E -C -i sql/02_geometry.sql
sqlcmd -S localhost -E -C -i sql/03_escapement.sql
sqlcmd -S localhost -E -C -d Watchmaker -Q "EXEC esc.usp_BuildMaps; EXEC esc.usp_Run;"
-- then work through sql/demo_escapement.sql in SSMS
```

```
cd python
python escapement_viz.py                          # simulator (no SQL Server needed)
python escapement_viz.py --source sql             # draw SQL Server's latest run
python escapement_viz.py --source sql --run --space ../out/escapement_space.png
python verify_escapement.py                       # SQL Server vs the Python mirror
```

`WATCH_SQL` overrides the ODBC connection string (default: localhost, Windows
auth, database `Watchmaker`).

**Verification.** `verify_escapement.py` compares every map cell (97,560) and
every frame (413) of the SQL Server run with `python/watch_lab/escapement.py`,
which uses the same shapes, grids and solver. Currently: 0 differences.

---

## Episode 2: the going train

```
centre wheel  80 teeth  ->  third pinion  10 leaves   (m 0.13 mm)
third wheel   75 teeth  ->  fourth pinion 10 leaves   (m 0.11 mm)
fourth wheel  80 teeth  ->  escape pinion  8 leaves   (m 0.08 mm)
```

The tooth counts are the only numbers; nothing types 8, 7.5, 10 or 60.
Wheel teeth are real cycloidal teeth: each addendum flank is an epicycloid
rolled by a circle half the pinion's pitch radius. Pinion leaves have radial
flanks and round tips. Each mesh is also built with naive straight-sided
teeth, for comparison. Even the arbor positions come from the teeth:
the centre distance is m (z + n) / 2.

Contact geometry is fine: 40 points per flank and a 5 deg step round each
pinion tip. With 10 points per flank the facets show up as a +/-2.5% wobble
in the ratio. The drawing uses coarser shapes.

`train.usp_BuildMaps` (about 75 s):
1. For each mesh, 60 wheel angles across a tooth by 120 pinion angles across a
   leaf: do they overlap? That is `train.MeshMap`, 43,200 `STIntersects`.
2. For each wheel angle, the **push edge**: the least the pinion must have
   turned to be clear of the tooth pushing it. The cell is found from the map,
   then split 16 ways twice (`train.Edge`, to 0.0012 deg). That edge *is* the
   gearing law.

`train.usp_Run` turns the centre arbor at its real rate, 0.1 deg a second, and
reads every other arbor through the push edges. That's three `CROSS APPLY`s
and no loop. `train.vMesh` reports what the teeth did:

| mesh | teeth | profile | mean ratio | min .. max | backlash (pinion deg) |
|---|---|---|---|---|---|
| centre -> third | 80/10 | cycloidal | 8.0000 | 7.91 .. 8.03 (-1.2% / +0.4%) | 5.10 (constant) |
| | | straight | 8.0000 | 5.45 .. 10.50 (-32% / +31%) | 1.50 .. 5.40 |
| third -> fourth | 75/10 | cycloidal | 7.5000 | 7.40 .. 7.54 (-1.4% / +0.6%) | 5.10 (constant) |
| | | straight | 7.5000 | 5.10 .. 9.87 | 1.20 .. 5.40 |
| fourth -> escape | 80/8 | cycloidal | 10.0000 | 9.69 .. 10.16 (-3.1% / +1.6%) | 6.38 (constant) |
| | | straight | **jams** | | |

The 8-leaf pinion is the least steady, as watchmakers expect, because it
engages before the line of centres. Over one simulated minute, the fourth
wheel (the seconds hand) turns 359.957 deg while the centre wheel turns 6.
That's a ratio of 59.993, not 60.000, because a minute is 1 1/3 centre-wheel
teeth and ends partway through a tooth. The escape wheel turns 10 times.

```
sqlcmd -S localhost -E -C -i sql/04_train.sql
sqlcmd -S localhost -E -C -d Watchmaker -Q "EXEC train.usp_BuildMaps; EXEC train.usp_Run;"
-- then sql/demo_train.sql in SSMS

cd python
python train_viz.py                              # simulator
python train_viz.py --source sql --figures       # SQL Server's run, plus the mesh figures
python verify_train.py                           # SQL Server vs the Python mirror
```

**Verification.** `verify_train.py`: 43,199 of 43,200 map cells agree. The odd
one is a touching case decided at the 6th decimal of the WKT. Every push edge
agrees to within one finest refinement step (0.0012 deg). Over the minute's
run, the escape wheel stays within 0.09 deg of the mirror, after 600:1
amplification.

---

## Episode 3: power

**Ratchet and click.** A 36-tooth sawtooth ratchet on the barrel arbor, and a
click on a pivot, pushed in by its spring. `power.usp_BuildClick` checks every
ratchet angle in one tooth (0.1 deg steps) against every click angle (0.05 deg
steps): 36,100 `STIntersects`, about a second. `power.usp_Click` then turns the
ratchet a step at a time:
- The click's spring pushes it in as far as it will go.
- If the ratchet would hit it, the click must be lifted clear. That is only
  possible if it can rise where it is.

Nothing says "one way":
- Winding, each tooth's slope lifts the click and it snaps into the next gap.
  `power.vClick` measures a click every 10.00 deg, so 36 a turn.
- Letting go, the ratchet slips back 10.9 deg down the slope it was on. Then the
  flat face drives the click towards its own pivot, so the click can't lift and
  the ratchet stops dead. It's the same draw as the escapement's pallet stones.

**How far can a barrel turn?** The strip is 350 mm long and 0.10 mm thick, in a
drum of radius 5.0 mm round an arbor of radius 1.6 mm. `power.fn_PackTurns`
packs it coil on coil round the arbor, and again against the wall, and finds
each pack's turns by measuring the drawn spiral with `STLength` (40 halvings).
The difference is all the barrel can ever turn. `power.usp_Fill` sweeps the
length and rediscovers the watchmaker's rule of thumb: **7.79 turns at best,
for a 350 mm spring that fills 49.6% of the space**.

**Power reserve.** Leave a turn on each side and a free coil between them,
and the spring goes from 13.81 turns (let down) to 20.17 (wound). That's 6.36
turns of the barrel. Each turn is 80 / 10 = 8 turns of the centre wheel, which
turns once an hour (episode 2), so the reserve is **50.9 hours**. In every
frame of `power.usp_Spring` the drawn spring measures 349.8 mm with `STLength`.

```
sqlcmd -S localhost -E -C -i sql/05_power.sql
sqlcmd -S localhost -E -C -d Watchmaker -Q "EXEC power.usp_BuildClick; DECLARE @r int; EXEC power.usp_Click @RunId=@r OUTPUT; EXEC power.usp_ClickParts @r; EXEC power.usp_Fill; EXEC power.usp_Spring;"
-- then sql/demo_power.sql in SSMS

cd python
python power_viz.py                      # simulator
python power_viz.py --source sql         # SQL Server's runs: two GIFs and two figures
python verify_power.py                   # SQL Server vs the Python mirror
```

**Verification.** `verify_power.py`:

| check | result |
|---|---|
| `power.ClickMap` cells | 0 of 36,100 differ |
| click run frames | 0 of 391 differ |
| `power.Fill` rows | identical to 6 decimal places |
| spring frames | identical; drawn length agrees to 3.5e-6 mm |

---

## Episode 4: the motion works

```
cannon pinion 12 leaves (centre arbor, minute hand) -> minute wheel 36   (m 0.125)
minute pinion 10 leaves (minute wheel's arbor)      -> hour wheel   40   (m 0.12, hour hand)
```

Same machinery as episode 2 (maps, push edges, `CROSS APPLY` transmission),
with two new things:

- **Pinions drive wheels.** So every gear gets the full cycloidal form: its
  addendum is the epicycloid rolled by a circle half its *partner's* pitch
  radius, and its dedendum is radial. With both gears right, `motion.vMesh`
  measures the ratios as exactly 1/3 and 1/4, steady to within the measurement's
  resolution, and the backlash is constant. The going train's round-tipped
  pinions, measured the same way, dip by 1.4% (`out/motion_ratio.png`).
- **The coaxial constraint.** The hour wheel rides on the cannon pinion, so both
  meshes must be the same length. They are only because the modules differ:
  0.125 x 48 / 2 = 0.12 x 50 / 2 = 3 mm. The database places the hour wheel by
  going out to the minute arbor and back. `motion.vCoaxial` measures, with
  `STDistance`, that it lands 4.4e-16 mm from the centre: floating-point dust.

Twelve hours: the minute hand turns 12 times, the minute wheel 4, the hour hand
once. The database measures 12.0 minute turns per hour turn, and after one hour
the hour wheel has turned exactly 30 deg.

```
sqlcmd -S localhost -E -C -i sql/06_motion.sql
sqlcmd -S localhost -E -C -d Watchmaker -Q "EXEC motion.usp_BuildMaps; EXEC motion.usp_Run;"
-- then sql/demo_motion.sql in SSMS

cd python
python motion_viz.py                     # simulator
python motion_viz.py --source sql        # SQL Server's run, plus the steadiness figure
python verify_motion.py                  # SQL Server vs the Python mirror
```

**Verification.** `verify_motion.py`:

| check | result |
|---|---|
| arbor positions | identical |
| `motion.MeshMap` cells | 0 of 14,400 differ |
| push edges | identical |
| twelve-hour run, 361 frames | hour hand within 3e-14 deg of the mirror |

---

## Episode 5: the movement in 3D (PostgreSQL 18 + PostGIS 3.6)

The whole watch: 34 parts and 107 pieces, from the mainplate to the hands,
in one PostGIS schema, `movement`.
- The going train, motion works, escapement and power parts are Part 1's
  outlines, ported to PostGIS. They match point for point.
- The plates, bridges, cock, screws, balance wheel, hairspring, dial, hands
  and stem are new.

**The calibre** (`03_calibre.sql`) is 26 mm across, seen from the dial with
the crown at 3.
- **Arbor positions:** each arbor is a bearing and a distance from another.
  The distances come from the teeth (`m (z1 + z2) / 2`) or from the
  escapement's own geometry (scaled 0.22). A recursive CTE turns them into
  positions.
- **Layout:** the barrel is at 11 o'clock, the third wheel at half past four
  and the fourth wheel at 6, where it carries the small seconds. The escape
  wheel, pallet fork and balance run round to 9.
- **Heights:** every piece is a prism, a 2D profile between two heights. The
  mainplate is z 0..1.2, the train side is negative z and the dial side is
  above 1.2.
- **Rest angles:** the database finds them itself. Working out from the
  escapement (Part 1's rest pose), each wheel is turned a tooth's worth in
  240 steps, and it stops in the middle of its longest clear run. The click
  drops into its tooth the way Part 1's click rule says.

**The solids** (`04_solids.sql`):
- **Why not SFCGAL:** on this build, SFCGAL's exact-arithmetic operations are
  far too slow for watch parts. `CG_Volume` took 20 s for one 160-point
  prism, and `CG_3DIntersects` and `CG_Tesselate` both ran past the timeout.
- **How the database builds each solid:** native PostGIS does it.
  `ST_TriangulatePolygon` (GEOS constrained Delaunay) makes the lids, and
  `ST_DumpSegments` gives two wall triangles per edge. Every triangle is wound
  outwards, and the result is a closed `TIN Z`. The stem lies along x, and
  `ST_Affine` turns its prism onto that axis.
- **One gap:** PostGIS has no way to make a `TRIANGLE` from coordinates, so
  each TIN is assembled as WKT text. That is the same trick Part 1 needed,
  but here it is needed once per solid rather than for every rotation.
- **Checks:** each solid is checked for watertightness (every edge used twice,
  once each way). Its volume is found with the divergence theorem in SQL and
  compared with area × height.

**Does anything share space?** `movement.clashes()` tests every pair of pieces.
- **Same-axis pairs:** for two prisms on the same axis, the 3D question
  factors into a 2D overlap (`ST_Relate` with `'2********'`) and an interval
  test. SQL Server could answer that much.
- **The stem:** it lies along another axis, so it needs real 3D:
  `ST_3DIntersects` on the surfaces, plus a point-in-solid test in case one
  piece is wholly inside the other.
- **First run:** the check found four overlaps of about 10⁻⁴ mm². They were
  the hands and the hairspring collet, pressed onto shafts whose n-gons didn't
  line up. Sliding-fit bores fixed them.

**Taking it apart** (`05_take_apart.sql`): no order is typed in anywhere.
- **The rule:** every round, each part still in the watch tries to slide out
  along its axis, away from the mainplate. It can go if its swept solid, the
  prism stretched out to infinity, meets nothing still in the watch.
- **The rounds:**

| round | off the back | off the front | sideways |
|---|---|---|---|
| 1 | all bridge screws except the pallet bridge's, ratchet screw, click screw | minute and seconds hands | stem |
| 2 | balance cock, click, ratchet | hour hand | |
| 3 | barrel bridge, hairspring | dial | |
| 4 | balance, barrel cover, **pallet-bridge screw**, train bridge | hour wheel | |
| 5 | barrel arbor, mainspring, pallet bridge, third wheel | cannon pinion, minute wheel | |
| 6 | barrel, escape wheel, pallet fork | | |
| 7 | fourth wheel | | |
| 8 | centre wheel | | |

- **Nobody told it this:** the pallet-bridge screw can't come out until the
  balance has gone, because its head is under the balance wheel. The centre
  wheel comes out last, because the barrel and the fourth wheel lie over it.
- **The exploded view:** how many rounds a part waits is how far it sits from
  the plate in the exploded view.

**The front end** (`viewer/index.html`, three.js 0.160) draws exactly what
the database computed.
- `movement_export.py` carries the triangles across: 90,836 of them, as
  integer micrometres. With Episode 6's run and breathing hairspring the file
  is 13.8 MB.
- In the viewer you can drag to turn the movement, and the slider explodes it
  by the database's rounds.
- Pointing at a part names it and gives its round.
- To run it locally, serve the folder:
  `python -m http.server 8765 --directory viewer`.

**Run it (both Part 2 episodes):**
```
cd sql/pg && psql -h localhost -p 5432 -U postgres -d watchmaker -f build.sql   # ~38 s
python python/movement_export.py
python python/verify_movement.py
python python/verify_run.py
```

**Verified** (`verify_movement.py`):

| check | result |
|---|---|
| 21 outlines (wheels, pinions, motion gears, escape wheel, stones, lever, pallet body, ratchet, click, mainspring) vs the Python mirror | same vertex counts, worst gap 7e-15 mm |
| mainspring limits | 13.809707915 / 20.169260966 turns, identical |
| arbor positions, recomputed | within 1e-15 mm; the hour wheel lands 4.4e-16 mm off centre |
| 107 solids | all watertight; volume = area × height within 3e-12 mm³; 1,038 mm³ in all |
| pieces sharing space | 0 |
| take-apart, recomputed in Python without the database | the same parts in the same 8 rounds. The stem test there takes another route: cut its cross-section to the other part's height band and intersect the y range in 2D |

**Timings:** the full build from nothing takes about 20 s:
- the 107 solids take 0.8 s;
- the clash check takes 0.24 s;
- the take-apart takes 4 to 19 s, mostly the stem's 3D tests;
- phasing all six meshes takes 66 ms (1,440 rotate-and-intersect tests).

---

## Episode 6: it runs (PostgreSQL + PostGIS)

Part 1's kinematics, ported to PostGIS and measured against the 3D layout.

**The gearing laws** (`06_laws.sql`). Part 1's method covers all six gear
pairs: barrel → centre → third → fourth → escape, and cannon pinion →
minute wheel → hour wheel.
- **The map:** for every driver angle (60 a tooth) and every driven angle
  (120 a tooth), do they overlap?
- **The push edge:** the least the driven gear must have turned to be clear.
  It is refined twice, sixteen ways each, then unwrapped.
- **Tooth shapes:** the laws use contact-quality teeth. The 3D model's coarser
  teeth sit inside them.
- **Speed-up:** both gears are first cut to the lens where their tip circles
  overlap. This is exact, because they can only touch there, and it is much
  faster.

| mesh | mean ratio | min .. max | |
|---|---|---|---|
| barrel 80 → centre pinion 10 | 8.000000 | 7.94 .. 8.05 | new: the barrel wasn't meshed in Part 1 |
| centre 80 → third 10 | 8.000000 | 7.89 .. 8.03 | |
| third 75 → fourth 10 | 7.500000 | 7.38 .. 7.54 | |
| fourth 80 → escape 8 | 10.000000 | 9.65 .. 10.16 | |
| cannon 12 → minute wheel 36 | 0.333333 | dead steady | |
| minute pinion 10 → hour wheel 40 | 0.250000 | dead steady | |

**The escapement** (`07_escapement.sql`): Part 1's maps and solver, in
plpgsql.
- **The maps:** wheel × fork, jewel × fork, fork × pins, and which face the
  wheel would touch next. That is 135,560 cells, all asked in one set-based
  pass.
- **The solver:** it loads the maps into arrays and steps frame by frame.
- **The balance:** it swings as a sine at 2.5 Hz (18,000 beats an hour). Each
  frame carries its time, filmed in slow motion near the fork.

**The run** (`08_run.sql`): one minute, 300 beats, 30,901 frames.
- **The escapement sets the pace,** and the train follows it backwards. The
  mainspring keeps every driving tooth pressed on its pinion, so the fourth,
  third and centre wheels and the barrel each come from running a law in
  reverse (`untransmit`).
- **The motion works** follow the cannon pinion forwards.
- **The rest pose is the run's first frame.** Episode 5 had set the train in
  the middle of its backlash; it now sits on the driving flank. The solids are
  rebuilt there, and there are still no clashes.
- **The hairspring breathes, not spins.** Its inner end turns with the balance
  and its outer end is held by the stud. There is one solid every 10° of
  balance swing, 23 in all.

After one minute, nothing in the SQL having said 60, 12 or 8:

| arbor | turned |
|---|---|
| escape wheel | +3600.000000° (10 turns, 300 beats × 12°) |
| fourth wheel (seconds hand) | −360.000000° |
| third wheel | +48.000000° |
| centre wheel (minute hand) | −6.000000° |
| barrel | +0.750000° (once every 8 hours) |
| hour hand | −0.500000° |

**The viewer** plays it back. You can pause it and set the speed (1/50, 1/10,
real time, 10×, 60×). It shows the watch's time, and in slow motion the
escapement's phase too: locked, unlocking, impulse or drop, and which stone.
The explode slider still works while it runs. After the minute the escapement
is back where it started, so the minute repeats and the slow wheels carry on
from where they reached.

**Verified** (`verify_run.py`):

| check | result |
|---|---|
| six gearing maps, rebuilt with shapely from the mirror's teeth | 0 of 43,200 cells differ; laws within 3e-14° |
| escapement maps vs the mirror's `clearance_maps()` | 0 of 135,560 cells differ |
| the minute's run vs the mirror's solver | all 30,901 frames identical |
| the first 413 frames vs SQL Server's Part 1 run (`esc.Frame`) | identical |
| the train, worked back by the mirror's own laws | within 7e-15° |

**The race, again** (the same questions in both databases):

| job | SQL Server 2025 (Part 1) | PostGIS |
|---|---|---|
| gearing maps and push edges | ~155 s for 8 maps (train, both tooth forms; motion works) | 0.6 s for 6 |
| escapement maps (~97k / 135k intersection tests) | ~6 s | 0.9 s |
| escapement run, 4 beats (413 frames) | 76 ms | 13 ms |
| storing the run's moving shapes | 20 s (escapement), 64 s (train): `fn_Affine` rewriting WKT | none needed: the viewer turns the database's solids by the database's angles |

**Timings:** the full build, including the minute's run, takes about 38 s:
- the laws take 0.6 s;
- the escapement maps take 0.9 s;
- solving 300 beats takes 0.28 s;
- working the train back through 30,901 frames takes 9 s, one SQL function
  call per law per frame;
- rebuilding the solids and the breathing poses takes 2.3 s.

---

## Notes for the Part 2 argument (what SQL Server made hard)

- **No rotate, translate, scale or affine transform.** `dbo.fn_Affine` (with
  `dbo.fn_Rotate` and `dbo.fn_Place` on top) counts each ring's points, walks
  them with `STPointN`, moves every point, and rebuilds the WKT. PostGIS has
  `ST_Affine`, `ST_Rotate`, `ST_Translate` and `ST_Scale`.
- **That rebuild is the slow part.** About 90 ms to move one 2,600-point wheel.
  - Escapement: solving a run takes 76 ms; storing its 413 frames of shapes takes 20 s.
  - Gear train: the run itself takes 45 ms; storing 361 frames of shapes takes 64 s.
  - How `fn_Affine` got there:
    1. Walking rings inside a CTE took 3 min 16 s for those 361 frames
       (CTEs aren't materialised, so each point re-extracted its ring).
    2. Walking the whole shape with `STPointN` was faster on a variable (90 ms
       a wheel), but 600 ms a wheel when the shape came from a table column:
       every `STPointN` re-read the shape.
    3. The version that stuck edits the WKT text: `STAsText`, `STRING_SPLIT`
       at the commas, move each `x y`, glue it back. That's 160 ms a wheel from a
       column. In SQL Server, the quickest way to rotate a shape is to rewrite
       its text.
- **Refining the push edges is mostly `fn_Affine` too.** About 30 s per round, turning pinions.
- **No point-array constructors.** Shapes are built as WKT strings (`dbo.fmt`,
  `dbo.fn_Polar`). PostGIS has `ST_MakePoint` / `ST_MakeLine` / `ST_MakePolygon`.
- **No 3D.** Z is stored but every spatial method ignores it. SQL Server has
  no TIN or polyhedral types, no triangulation, no 3D affine, and no 3D
  distance or intersection. PostGIS has all of them natively: `TIN Z`,
  `ST_TriangulatePolygon`, `ST_Affine` (12 parameters), `ST_3DIntersects`,
  `ST_3DDistance` and the `&&&` n-D index operator.
- **`STBuffer` chooses its own vertices,** so circles are built as explicit
  n-gons to keep the Python mirror exact.

**The race.** Turning the same 7,201-point wheel 100 times took 21.1 s in
SQL Server (`dbo.fn_Rotate`) and 2.8 ms in PostGIS (`ST_Rotate`), about
7,500 times faster.

**And where PostGIS was not easy either** (fair's fair):
- **SFCGAL's exact solids were unusable at this scale** on this build (2.2.0 /
  CGAL 6.0.1):
  - `CG_Volume` took about 20 s on a 160-point prism, and grid-snapping didn't
    help;
  - `CG_3DIntersects` and `CG_Tesselate` both timed out;
  - only `CG_Extrude` was quick.
  The movement uses no SFCGAL at all.
- **There is no `TRIANGLE` constructor,** so the TIN is built as WKT text,
  once per solid.
- **Same-axis clash tests factor into 2D plus an interval,** which SQL Server
  could do as well. The real 3D work is the stem, the solids themselves and
  the 3D placing.

## Files
```
sql/01_schema.sql          tables: spec, base shapes, pose grids, maps, runs, frames
sql/02_geometry.sql        builders: fmt, fn_Polar, fn_Circle, fn_Rotate, the parts
sql/03_escapement.sql      usp_BuildMaps, usp_Run, vBeat
sql/04_train.sql           episode 2: teeth, MeshMap, push edges, usp_Run, vMesh, vRatio
sql/05_power.sql           episode 3: ClickMap, usp_Click, vClick, fn_PackTurns, usp_Fill, usp_Spring
sql/06_motion.sql          episode 4: full cycloidal gears, MeshMap, push edges, usp_Run, vMesh, vCoaxial
sql/demo_escapement.sql    a guided tour in SSMS
sql/demo_train.sql         ... of the going train
sql/demo_power.sql         ... of power
sql/demo_motion.sql        ... and of the motion works
python/escapement_viz.py   the animation and the configuration-space figure
python/train_viz.py        the going train: animation, mesh-space and ratio figures
python/power_viz.py        power: click and mainspring animations, fill and click-space figures
python/motion_viz.py       the motion works: twelve hours, and the ratio-steadiness figure
python/verify_*.py         SQL Server vs the Python mirror, one per episode
python/watch_lab/          the mirrors (escapement.py, train.py, power.py, motion.py), SQL source, drawing
out/                       escapement.gif, escapement_space.png, train.gif, train_mesh_space.png,
                           train_ratio.png, power_click.gif, power_spring.gif, power_fill.png,
                           power_click_space.png, motion.gif, motion_ratio.png

Part 2 (PostgreSQL + PostGIS)
sql/pg/build.sql           runs 01..08 in order (~38 s)
sql/pg/01_schema.sql       schema movement: forms, specs, arbors, spots, meshes, parts, pieces, removal
sql/pg/02_profiles.sql     the outlines: gear, pinion, escape wheel, stones, lever, ratchet, click, springs
sql/pg/03_calibre.sql      the layout, every part and piece, the rest angles (clear_phase, phase_click)
sql/pg/04_solids.sql       prism -> TIN Z, volume, open_edges, v_solid, clashes()
sql/pg/05_take_apart.sql   blocked(), take_apart()
sql/pg/06_laws.sql         episode 6: spins, mesh_map, edge, law; transmit(), untransmit(), v_mesh
sql/pg/07_escapement.sql   escapement maps, run_escapement() (the solver), v_beat
sql/pg/08_run.sql          run(): a minute of every arbor, frame 0 as the rest pose, breathing hairspring; export_json()
sql/pg/demo_movement.sql   a guided tour of both episodes
python/movement_export.py  PostGIS -> viewer/movement_data.js
python/verify_movement.py  outlines vs the mirror, layout, solids, take-apart recomputed
python/verify_run.py       laws, escapement maps and run vs the mirror and Part 1; the train worked back
viewer/index.html          the three.js viewer: run it, turn it, explode it, point at parts
```
