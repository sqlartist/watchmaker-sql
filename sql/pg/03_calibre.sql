/* =====================================================================
   The Watchmaker, Part 2  —  pg/03_calibre.sql
   The calibre: where every arbor goes, and every part, piece by piece.

   Plan (seen from the dial, 26 mm across): the barrel near 11 o'clock,
   the centre wheel in the middle, the third wheel at half past four, the
   fourth wheel at 6 (it turns once a minute, so it carries the small
   seconds hand), then the escape wheel, the pallet fork and the balance
   working round to 9. The crown is at 3.

   Heights: the mainplate is z 0 .. 1.2. Behind it (negative z), from the
   plate outwards: the centre wheel, the fourth wheel and barrel teeth,
   the third and escape wheels with the pallet fork, then the train and
   pallet bridges, the balance, the barrel bridge, the cock, and on top of
   the barrel bridge the ratchet and click. In front of the plate: the
   motion works, the dial, the hands.

   Wheels that overlap in plan must be at different heights. Nothing here
   checks that by hand: 04_solids.sql builds the solids and the database
   looks for any two parts that share space.
   ===================================================================== */

/* =====================================================================
   ARBORS: bearings typed in, distances worked out
   ===================================================================== */
INSERT INTO movement.setting VALUES
    ('click_bearing', 210),          -- the click sits this way from the barrel arbor
    ('hours', 10), ('minutes', 10), ('seconds', 30);     -- the time the hands are set to

INSERT INTO movement.arbor (arbor, from_arbor, bearing) VALUES
    ('centre',  NULL,      NULL),
    ('barrel',  'centre',  100),
    ('third',   'centre',  -45),
    ('fourth',  'third',  -150),
    ('escape',  'fourth',  160),
    ('pallet',  'escape',  150),     -- the escapement points this way: wheel, fork, balance in a line
    ('balance', 'pallet',  150),
    ('minute',  'centre', -135),
    ('hour',    'minute',   45);     -- and it should come back to the centre

INSERT INTO movement.mesh VALUES
    (1, 'barrel', 'Barrel',       'teeth',  80, 'centre', 'Centre arbor', 'pinion', 10, 0.14,  'driver', 4, 'wheel', 'leaf'),
    (2, 'centre', 'Centre arbor', 'wheel',  80, 'third',  'Third arbor',  'pinion', 10, 0.13,  'driver', 3, 'wheel', 'leaf'),
    (3, 'third',  'Third arbor',  'wheel',  75, 'fourth', 'Fourth arbor', 'pinion', 10, 0.11,  'driver', 2, 'wheel', 'leaf'),
    (4, 'fourth', 'Fourth arbor', 'wheel',  80, 'escape', 'Escape arbor', 'pinion',  8, 0.08,  'driver', 1, 'wheel', 'leaf'),
    (5, 'centre', 'Cannon pinion', 'pinion', 12, 'minute', 'Minute wheel', 'wheel', 36, 0.125, 'driven', 5, 'motion', 'motion'),
    (6, 'minute', 'Minute wheel', 'pinion', 10, 'hour',   'Hour wheel',   'wheel',  40, 0.12,  'driven', 6, 'motion', 'motion');

/* centre distance = the sum of the pitch radii */
UPDATE movement.arbor AS a
SET distance = m.module * (m.driver_teeth + m.driven_teeth) / 2.0
FROM movement.mesh AS m
WHERE (m.driver_arbor = a.from_arbor AND m.driven_arbor = a.arbor)
   OR (m.driven_arbor = a.from_arbor AND m.driver_arbor = a.arbor);

/* the escapement's own geometry, scaled: P = R / cos 30 from the wheel, the balance Lever beyond */
UPDATE movement.arbor SET distance = (SELECT scale * r / cos(radians(30)) FROM movement.esc_spec) WHERE arbor = 'pallet';
UPDATE movement.arbor SET distance = (SELECT scale * lever FROM movement.esc_spec) WHERE arbor = 'balance';

/* the click's pivot, from Part 1's power drawing turned to face this way */
INSERT INTO movement.arbor (arbor, from_arbor, bearing, distance)
SELECT 'click', 'barrel', s.value, sqrt(p.pawl_x ^ 2 + p.pawl_y ^ 2)
FROM movement.setting AS s, movement.power_spec AS p WHERE s.name = 'click_bearing';

WITH RECURSIVE pos AS (
    SELECT arbor, 0::float8 AS x, 0::float8 AS y FROM movement.arbor WHERE from_arbor IS NULL
    UNION ALL
    SELECT a.arbor, p.x + a.distance * cos(radians(a.bearing)), p.y + a.distance * sin(radians(a.bearing))
    FROM movement.arbor AS a JOIN pos AS p ON p.arbor = a.from_arbor)
UPDATE movement.arbor AS a SET x = pos.x, y = pos.y FROM pos WHERE pos.arbor = a.arbor;

INSERT INTO movement.spot (spot, from_arbor, bearing, distance) VALUES
    ('barrel foot 1', 'barrel',   30,    6.8),     -- bridge feet, each with a screw
    ('barrel foot 2', 'barrel',  160,    6.8),
    ('train foot 1',  'third',     0,    5.4),
    ('train foot 2',  'fourth', -100,    4.2),
    ('pallet foot',   'pallet',  195,    1.8),
    ('cock foot',     'balance', 120,    5.2),
    ('dial foot 1',   'centre',   36.87, 10.0),    -- the dial's two feet
    ('dial foot 2',   'centre', -143.13, 10.0);
UPDATE movement.spot AS s
SET x = a.x + s.distance * cos(radians(s.bearing)), y = a.y + s.distance * sin(radians(s.bearing))
FROM movement.arbor AS a WHERE a.arbor = s.from_arbor;

INSERT INTO movement.pivot VALUES
    ('centre', 0.12), ('barrel', 0.30), ('third', 0.10), ('fourth', 0.10),
    ('escape', 0.07), ('pallet', 0.07), ('balance', 0.05);

/* =====================================================================
   HELPERS
   ===================================================================== */
CREATE FUNCTION movement.pt(which text) RETURNS geometry LANGUAGE sql STABLE AS $$
SELECT ST_MakePoint(x, y) FROM (SELECT x, y FROM movement.arbor WHERE arbor = which
                                UNION ALL SELECT x, y FROM movement.spot WHERE spot = which) AS p
$$;

CREATE FUNCTION movement.disc(which text, r float8, n int DEFAULT 48) RETURNS geometry LANGUAGE sql STABLE AS
$$ SELECT movement.circle(ST_X(p), ST_Y(p), r, n) FROM (SELECT movement.pt(which) AS p) AS q $$;

CREATE FUNCTION movement.jewel_hole(which text) RETURNS float8 LANGUAGE sql STABLE AS
$$ SELECT r + 0.01 FROM movement.pivot WHERE arbor = which $$;

/* the escapement's frame: its +y (wheel to fork to balance) turned onto the pallet bearing */
CREATE FUNCTION movement.esc_turn() RETURNS float8 LANGUAGE sql STABLE AS
$$ SELECT bearing - 90 FROM movement.arbor WHERE arbor = 'pallet' $$;

/* escapement units, about the wheel, to the watch */
CREATE FUNCTION movement.esc_place(g geometry) RETURNS geometry LANGUAGE sql STABLE AS $$
SELECT ST_Translate(ST_Rotate(ST_Scale(g, s.scale, s.scale), radians(movement.esc_turn())), a.x, a.y)
FROM movement.esc_spec AS s, movement.arbor AS a WHERE a.arbor = 'escape'
$$;

/* Part 1's power drawing turned so the click is at click_bearing */
CREATE FUNCTION movement.power_turn() RETURNS float8 LANGUAGE sql STABLE AS
$$ SELECT s.value - degrees(atan2(p.pawl_y, p.pawl_x)) FROM movement.setting AS s, movement.power_spec AS p
   WHERE s.name = 'click_bearing' $$;

/* the hands' angles for the time in movement.setting (they turn clockwise: negative) */
CREATE FUNCTION movement.hand_deg(which text) RETURNS float8 LANGUAGE sql STABLE AS $$
SELECT CASE which WHEN 'hour'   THEN -30 * (h + m / 60 + s / 3600)
                  WHEN 'minute' THEN -6 * (m + s / 60)
                  ELSE -6 * s END
FROM (SELECT max(value) FILTER (WHERE name = 'hours') AS h, max(value) FILTER (WHERE name = 'minutes') AS m,
             max(value) FILTER (WHERE name = 'seconds') AS s FROM movement.setting) AS t
$$;

/* a wheel's rim inside its tooth roots */
CREATE FUNCTION movement.rim(z int, m float8, kind text) RETURNS float8 LANGUAGE sql STABLE AS
$$ SELECT m * z / 2.0 - hf * m - 0.35 FROM movement.form WHERE form.kind = rim.kind $$;

/* bridge outlines (before their holes) */
CREATE FUNCTION movement.cock_outline() RETURNS geometry LANGUAGE sql STABLE AS $$
SELECT ST_Union(ARRAY[movement.disc('balance', 1.6, 64),
                      ST_Buffer(ST_MakeLine(movement.pt('balance'), movement.pt('cock foot')), 0.9),
                      movement.disc('cock foot', 1.1, 48)])
$$;

CREATE FUNCTION movement.train_bridge_outline() RETURNS geometry LANGUAGE sql STABLE AS $$
SELECT ST_Difference(
    ST_Union(ARRAY[ST_Buffer(ST_MakeLine(ARRAY[movement.pt('train foot 1'), movement.pt('third'), movement.pt('centre')]), 0.75),
                   ST_Buffer(ST_MakeLine(ARRAY[movement.pt('third'), movement.pt('fourth'), movement.pt('train foot 2')]), 0.75),
                   ST_Buffer(ST_MakeLine(movement.pt('fourth'), movement.pt('escape')), 0.75),
                   movement.disc('centre', 1.0), movement.disc('third', 1.0), movement.disc('fourth', 1.0),
                   movement.disc('escape', 1.0), movement.disc('train foot 1', 1.0), movement.disc('train foot 2', 1.0)]),
    ST_Buffer(movement.disc('barrel', 5.3, 128), 0.15))           -- keep clear of the barrel drum
$$;

/* =====================================================================
   PARTS
   ===================================================================== */
INSERT INTO movement.part (part, arbor, phase, axis, is_base)
SELECT v.part, v.arbor, v.phase, v.axis, v.is_base
FROM (SELECT movement.esc_turn() AS et, movement.power_turn() AS pt, s.theta0, s.phi0, s.beta0
      FROM movement.esc_spec AS s) AS c,
LATERAL (VALUES
    ('Mainplate',              NULL::text, 0::float8, 'z', true),
    ('Barrel bridge',          NULL, 0, 'z', false),
    ('Train bridge',           NULL, 0, 'z', false),
    ('Pallet bridge',          NULL, 0, 'z', false),
    ('Balance cock',           NULL, 0, 'z', false),
    ('Screw, barrel bridge 1', NULL, 0, 'z', false),
    ('Screw, barrel bridge 2', NULL, 0, 'z', false),
    ('Screw, train bridge 1',  NULL, 0, 'z', false),
    ('Screw, train bridge 2',  NULL, 0, 'z', false),
    ('Screw, pallet bridge',   NULL, 0, 'z', false),
    ('Screw, balance cock',    NULL, 0, 'z', false),
    ('Ratchet screw',          NULL, 0, 'z', false),
    ('Click screw',            NULL, 0, 'z', false),
    ('Ratchet',                'barrel',  c.pt, 'z', false),
    ('Click',                  'click',   c.pt, 'z', false),
    ('Barrel arbor',           'barrel',  c.pt, 'z', false),
    ('Barrel',                 'barrel',  0, 'z', false),
    ('Barrel cover',           'barrel',  0, 'z', false),
    ('Mainspring',             'barrel',  c.pt, 'z', false),
    ('Centre arbor',           'centre',  0, 'z', false),
    ('Third arbor',            'third',   0, 'z', false),
    ('Fourth arbor',           'fourth',  0, 'z', false),
    ('Escape arbor',           'escape',  c.et + c.theta0, 'z', false),
    ('Pallet fork',            'pallet',  c.et + c.phi0, 'z', false),
    ('Balance',                'balance', c.et + c.beta0, 'z', false),
    ('Hairspring',             'balance', c.et + c.beta0, 'z', false),
    ('Cannon pinion',          'centre',  0, 'z', false),
    ('Minute wheel',           'minute',  0, 'z', false),
    ('Hour wheel',             'hour',    0, 'z', false),
    ('Dial',                   NULL, 0, 'z', false),
    ('Hour hand',              'hour',    movement.hand_deg('hour'), 'z', false),
    ('Minute hand',            'centre',  movement.hand_deg('minute'), 'z', false),
    ('Seconds hand',           'fourth',  movement.hand_deg('second'), 'z', false),
    ('Stem',                   NULL, 0, 'x', false)
) AS v (part, arbor, phase, axis, is_base);

/* =====================================================================
   PIECES  (z0, z1 along the part's axis; behind the plate is negative)
   ===================================================================== */

/* ---- the mainplate: three layers (the middle one has the stem's channel), jewels, studs, pins ---- */
WITH holes AS (
    SELECT ST_Union(ARRAY[
        movement.disc('third', 0.45, 32), movement.disc('fourth', 0.45, 32), movement.disc('escape', 0.45, 32),
        movement.disc('pallet', 0.45, 32), movement.disc('balance', 0.45, 32),
        movement.disc('centre', 0.27, 24), movement.disc('barrel', 0.32, 24),
        movement.disc('barrel foot 1', 0.32, 24), movement.disc('barrel foot 2', 0.32, 24),
        movement.disc('train foot 1', 0.32, 24), movement.disc('train foot 2', 0.32, 24),
        movement.disc('pallet foot', 0.32, 24), movement.disc('cock foot', 0.32, 24),
        movement.disc('dial foot 1', 0.27, 24), movement.disc('dial foot 2', 0.27, 24)]) AS g),
plate AS (SELECT ST_Difference(movement.circle(0, 0, 13.0, 256), holes.g) AS g FROM holes)
INSERT INTO movement.piece (part, piece, material, profile, z0, z1)
SELECT 'Mainplate', 'layer 1', 'plate', g, 0.0, 0.1 FROM plate
UNION ALL SELECT 'Mainplate', 'layer 2', 'plate', ST_Difference(g, ST_MakeEnvelope(8.95, -0.5, 13.5, 0.5)), 0.1, 1.1 FROM plate
UNION ALL SELECT 'Mainplate', 'layer 3', 'plate', g, 1.1, 1.2 FROM plate
UNION ALL SELECT 'Mainplate', 'jewel, ' || arbor, 'ruby',
                 movement.annulus(x, y, 0.45, movement.jewel_hole(arbor), 32), 0.0, 1.2
          FROM movement.arbor WHERE arbor IN ('third', 'fourth', 'escape', 'pallet', 'balance')
UNION ALL SELECT 'Mainplate', 'banking pins', 'steel', movement.esc_place(movement.banking_pins()), -1.25, 0.0
UNION ALL SELECT 'Mainplate', 'minute stud', 'steel', movement.disc('minute', 0.3, 32), 1.2, 2.0;

/* ---- bridges: a plate, its jewels, and feet down to the mainplate ---- */
INSERT INTO movement.piece (part, piece, material, profile, z0, z1)
SELECT 'Barrel bridge', 'plate', 'plate',
       ST_Difference(
           ST_Intersection(ST_ConvexHull(ST_Union(ARRAY[movement.disc('barrel', 6.0, 128), movement.disc('barrel foot 1', 1.0),
                                                       movement.disc('barrel foot 2', 1.0), movement.disc('click', 1.0)])),
                           movement.circle(0, 0, 12.9, 256)),
           ST_Union(ARRAY[movement.disc('barrel', 0.62, 32), movement.disc('barrel foot 1', 0.32, 24),
                          movement.disc('barrel foot 2', 0.32, 24), movement.disc('click', 0.18, 16),
                          ST_Buffer(movement.cock_outline(), 0.25)])),
       -3.40, -2.90
UNION ALL SELECT 'Barrel bridge', 'foot ' || k, 'plate',
                 ST_Difference(movement.disc('barrel foot ' || k, 0.8), movement.disc('barrel foot ' || k, 0.32, 24)), -2.90, 0.0
          FROM generate_series(1, 2) AS k

UNION ALL SELECT 'Train bridge', 'plate', 'plate',
                 ST_Difference(movement.train_bridge_outline(),
                     ST_Union(ARRAY[movement.disc('centre', 0.13, 16), movement.disc('third', 0.45, 32),
                                    movement.disc('fourth', 0.45, 32), movement.disc('escape', 0.45, 32),
                                    movement.disc('train foot 1', 0.32, 24), movement.disc('train foot 2', 0.32, 24)])),
                 -2.20, -1.70
UNION ALL SELECT 'Train bridge', 'jewel, ' || arbor, 'ruby', movement.annulus(x, y, 0.45, movement.jewel_hole(arbor), 32), -2.20, -1.70
          FROM movement.arbor WHERE arbor IN ('third', 'fourth', 'escape')
UNION ALL SELECT 'Train bridge', 'foot ' || k, 'plate',
                 ST_Difference(movement.disc('train foot ' || k, 0.8), movement.disc('train foot ' || k, 0.32, 24)), -1.70, 0.0
          FROM generate_series(1, 2) AS k

UNION ALL SELECT 'Pallet bridge', 'plate', 'plate',
                 ST_Difference(ST_Union(ARRAY[ST_Buffer(ST_MakeLine(movement.pt('pallet'), movement.pt('pallet foot')), 0.6),
                                              movement.disc('pallet', 0.9), movement.disc('pallet foot', 1.0)]),
                               ST_Union(movement.disc('pallet', 0.45, 32), movement.disc('pallet foot', 0.32, 24))),
                 -2.00, -1.70
UNION ALL SELECT 'Pallet bridge', 'jewel', 'ruby', movement.annulus(x, y, 0.45, movement.jewel_hole('pallet'), 32), -2.00, -1.70
          FROM movement.arbor WHERE arbor = 'pallet'
UNION ALL SELECT 'Pallet bridge', 'foot', 'plate',
                 ST_Difference(movement.disc('pallet foot', 0.8), movement.disc('pallet foot', 0.32, 24)), -1.70, 0.0

UNION ALL SELECT 'Balance cock', 'plate', 'plate',
                 ST_Difference(movement.cock_outline(),
                               ST_Union(movement.disc('balance', 0.45, 32), movement.disc('cock foot', 0.32, 24))),
                 -3.60, -3.10
UNION ALL SELECT 'Balance cock', 'jewel', 'ruby', movement.annulus(x, y, 0.45, movement.jewel_hole('balance'), 32), -3.60, -3.10
          FROM movement.arbor WHERE arbor = 'balance'
UNION ALL SELECT 'Balance cock', 'foot', 'plate',
                 ST_Difference(movement.disc('cock foot', 0.9), movement.disc('cock foot', 0.32, 24)), -3.10, 0.0;

/* ---- screws: a head on the bridge, a shank down into the mainplate ---- */
INSERT INTO movement.piece (part, piece, material, profile, z0, z1)
SELECT s.part, 'head', 'blued', movement.disc(s.spot, 0.55, 32), s.top - 0.25, s.top
FROM (VALUES ('Screw, barrel bridge 1', 'barrel foot 1', -3.40), ('Screw, barrel bridge 2', 'barrel foot 2', -3.40),
             ('Screw, train bridge 1', 'train foot 1', -2.20), ('Screw, train bridge 2', 'train foot 2', -2.20),
             ('Screw, pallet bridge', 'pallet foot', -2.00), ('Screw, balance cock', 'cock foot', -3.60)) AS s (part, spot, top)
UNION ALL
SELECT s.part, 'shank', 'blued', movement.disc(s.spot, 0.30, 24), s.top, 0.8
FROM (VALUES ('Screw, barrel bridge 1', 'barrel foot 1', -3.40), ('Screw, barrel bridge 2', 'barrel foot 2', -3.40),
             ('Screw, train bridge 1', 'train foot 1', -2.20), ('Screw, train bridge 2', 'train foot 2', -2.20),
             ('Screw, pallet bridge', 'pallet foot', -2.00), ('Screw, balance cock', 'cock foot', -3.60)) AS s (part, spot, top)
UNION ALL SELECT 'Ratchet screw', 'head',  'blued', movement.disc('barrel', 1.2, 48), -4.00, -3.75
UNION ALL SELECT 'Ratchet screw', 'shank', 'blued', movement.disc('barrel', 0.35, 24), -3.75, -3.45
UNION ALL SELECT 'Click screw',   'head',  'blued', movement.disc('click', 0.5, 32), -3.95, -3.75
UNION ALL SELECT 'Click screw',   'shank', 'blued', movement.disc('click', 0.17, 16), -3.75, -3.10;

/* ---- power: ratchet and click on the barrel bridge, the barrel and what is in it ---- */
INSERT INTO movement.piece (part, piece, material, profile, z0, z1)
SELECT 'Ratchet', 'wheel', 'steel', ST_Difference(movement.ratchet(), ST_MakeEnvelope(-0.4, -0.4, 0.4, 0.4)), -3.75, -3.45
UNION ALL SELECT 'Click', 'click', 'steel', ST_Translate(movement.click(), -p.pawl_x, -p.pawl_y), -3.75, -3.45
          FROM movement.power_spec AS p
UNION ALL SELECT 'Barrel arbor', 'lower pivot', 'steel', movement.circle(0, 0, 0.30, 24), -0.05, 0.9
UNION ALL SELECT 'Barrel arbor', 'shaft 1',     'steel', movement.circle(0, 0, 0.60, 32), -0.75, -0.05
UNION ALL SELECT 'Barrel arbor', 'core',        'steel', movement.circle(0, 0, 1.60, 64), -2.50, -0.75
UNION ALL SELECT 'Barrel arbor', 'shaft 2',     'steel', movement.circle(0, 0, 0.60, 32), -3.40, -2.50
UNION ALL SELECT 'Barrel arbor', 'square',      'steel',
                 ST_Difference(ST_MakeEnvelope(-0.4, -0.4, 0.4, 0.4), movement.circle(0, 0, 0.36, 24)), -3.75, -3.40
UNION ALL SELECT 'Barrel', 'teeth', 'gilt', ST_Difference(movement.gear(80, 0.14, 0.35, 'wheel'), movement.circle(0, 0, 5.0, 128)), -0.95, -0.55
UNION ALL SELECT 'Barrel', 'floor', 'gilt', movement.annulus(0, 0, 5.0, 0.62, 128), -0.70, -0.55
UNION ALL SELECT 'Barrel', 'wall',  'gilt', movement.annulus(0, 0, 5.3, 5.0, 128), -2.55, -0.95
UNION ALL SELECT 'Barrel cover', 'cover', 'gilt', movement.annulus(0, 0, 5.3, 0.62, 128), -2.70, -2.55
UNION ALL SELECT 'Mainspring', 'spring', 'spring',
                 ST_Buffer(movement.spring_line(0, (l.let_down + l.wound) / 2), 0.045, 'endcap=flat join=round quad_segs=2'),
                 -2.45, -0.80
          FROM movement.spring_limits() AS l;

/* ---- the going train ---- */
INSERT INTO movement.piece (part, piece, material, profile, z0, z1)
SELECT 'Centre arbor', 'dial shaft', 'steel', movement.circle(0, 0, 0.25, 24), -0.05, 2.60
UNION ALL SELECT 'Centre arbor', 'shaft',  'steel', movement.circle(0, 0, 0.30, 24), -1.65, -0.05
UNION ALL SELECT 'Centre arbor', 'wheel',  'gilt',
                 movement.crossed(movement.gear(80, 0.13, 0.325, 'wheel'), movement.rim(80, 0.13, 'wheel'), 0.55, 0.30, 4, 0.17),
                 -0.30, -0.15
UNION ALL SELECT 'Centre arbor', 'pinion', 'steel', movement.pinion(10, 0.14), -1.05, -0.45
UNION ALL SELECT 'Centre arbor', 'pivot',  'steel', movement.circle(0, 0, 0.12, 16), -2.15, -1.65

UNION ALL SELECT 'Third arbor', 'lower pivot', 'steel', movement.circle(0, 0, 0.10, 16), -0.05, 0.9
UNION ALL SELECT 'Third arbor', 'pinion', 'steel', movement.pinion(10, 0.13), -0.40, -0.05
UNION ALL SELECT 'Third arbor', 'shaft',  'steel', movement.circle(0, 0, 0.25, 24), -1.65, -0.40
UNION ALL SELECT 'Third arbor', 'wheel',  'gilt',
                 movement.crossed(movement.gear(75, 0.11, 0.275, 'wheel'), movement.rim(75, 0.11, 'wheel'), 0.55, 0.25, 4, 0.17),
                 -1.25, -1.10
UNION ALL SELECT 'Third arbor', 'pivot',  'steel', movement.circle(0, 0, 0.10, 16), -2.15, -1.65

UNION ALL SELECT 'Fourth arbor', 'seconds pivot', 'steel', movement.circle(0, 0, 0.10, 16), -0.05, 2.70
UNION ALL SELECT 'Fourth arbor', 'shaft',  'steel', movement.circle(0, 0, 0.25, 24), -1.65, -0.05
UNION ALL SELECT 'Fourth arbor', 'wheel',  'gilt',
                 movement.crossed(movement.gear(80, 0.08, 0.16, 'wheel'), movement.rim(80, 0.08, 'wheel'), 0.50, 0.25, 4, 0.15),
                 -0.68, -0.55
UNION ALL SELECT 'Fourth arbor', 'pinion', 'steel', movement.pinion(10, 0.11), -1.35, -1.00
UNION ALL SELECT 'Fourth arbor', 'pivot',  'steel', movement.circle(0, 0, 0.10, 16), -2.15, -1.65

UNION ALL SELECT 'Escape arbor', 'lower pivot', 'steel', movement.circle(0, 0, 0.07, 16), -0.05, 0.9
UNION ALL SELECT 'Escape arbor', 'shaft',  'steel', movement.circle(0, 0, 0.20, 24), -1.65, -0.05
UNION ALL SELECT 'Escape arbor', 'pinion', 'steel', movement.pinion(8, 0.08), -0.78, -0.45
UNION ALL SELECT 'Escape arbor', 'wheel',  'steel', ST_Scale(movement.escape_wheel_display(), s.scale, s.scale), -1.22, -1.10
          FROM movement.esc_spec AS s
UNION ALL SELECT 'Escape arbor', 'pivot',  'steel', movement.circle(0, 0, 0.07, 16), -2.15, -1.65;

/* ---- the escapement: Part 1's fork and roller, scaled; a new balance wheel and hairspring ---- */
INSERT INTO movement.piece (part, piece, material, profile, z0, z1)
SELECT 'Pallet fork', 'lower pivot', 'steel', movement.circle(0, 0, 0.07, 16), -0.05, 0.9
UNION ALL SELECT 'Pallet fork', 'staff', 'steel', movement.circle(0, 0, 0.15, 24), -1.65, -0.05
UNION ALL SELECT 'Pallet fork', 'fork', 'steel',
                 ST_Scale(ST_Translate(ST_Union(movement.lever(), movement.pallet_body()), 0, -ST_Y(movement.esc_p())), s.scale, s.scale),
                 -1.22, -1.10
          FROM movement.esc_spec AS s
UNION ALL SELECT 'Pallet fork', v.piece, 'ruby',
                 ST_Scale(ST_Translate(movement.stone(v.lock_at), 0, -ST_Y(movement.esc_p())), s.scale, s.scale), -1.22, -1.10
          FROM movement.esc_spec AS s, LATERAL (VALUES ('entry stone', s.entry_lock), ('exit stone', s.exit_lock)) AS v (piece, lock_at)
UNION ALL SELECT 'Pallet fork', 'pivot', 'steel', movement.circle(0, 0, 0.07, 16), -1.95, -1.65

UNION ALL SELECT 'Balance', 'lower pivot', 'steel', movement.circle(0, 0, 0.05, 12), -0.05, 0.9
UNION ALL SELECT 'Balance', 'staff 1', 'steel', movement.circle(0, 0, 0.15, 24), -1.45, -0.05
UNION ALL SELECT 'Balance', 'roller',  'steel', movement.circle(0, 0, 2.0 * s.scale, 48), -1.55, -1.45 FROM movement.esc_spec AS s
UNION ALL SELECT 'Balance', 'impulse jewel', 'ruby', movement.circle(0, -s.rj * s.scale, s.jewel_r * s.scale, 24), -1.55, -1.06
          FROM movement.esc_spec AS s
UNION ALL SELECT 'Balance', 'staff 2', 'steel', movement.circle(0, 0, 0.25, 24), -2.30, -1.55
UNION ALL SELECT 'Balance', 'wheel', 'gilt',
                 ST_Difference(ST_Union(ARRAY[
                     movement.annulus(0, 0, 4.0, 3.7, 160),
                     (SELECT ST_Union(ST_Buffer(ST_MakeLine(ST_MakePoint(0, 0), movement.polar(3.8, -90 + 120 * k)), 0.15, 'quad_segs=4'))
                      FROM generate_series(0, 2) AS k),
                     movement.circle(0, 0, 0.5, 32),
                     (SELECT ST_Union(movement.circle(ST_X(p), ST_Y(p), 0.15, 12))
                      FROM generate_series(0, 11) AS k, LATERAL (SELECT movement.polar(4.1, 15 + 30 * k) AS p) AS q)]),
                     movement.circle(0, 0, 0.25, 24)),
                 -2.60, -2.30
UNION ALL SELECT 'Balance', 'staff 3', 'steel', movement.circle(0, 0, 0.25, 24), -2.75, -2.60
UNION ALL SELECT 'Balance', 'staff 4', 'steel', movement.circle(0, 0, 0.15, 32), -3.05, -2.75   -- the collet's n-gon
UNION ALL SELECT 'Balance', 'pivot',   'steel', movement.circle(0, 0, 0.05, 12), -3.45, -3.05

UNION ALL SELECT 'Hairspring', 'collet', 'steel', movement.annulus(0, 0, 0.40, 0.15, 32), -2.87, -2.75
UNION ALL SELECT 'Hairspring', 'spring', 'spring',
                 ST_Buffer(movement.hairspring_line(0, 24), 0.018, 'endcap=flat join=round quad_segs=2'),
                 -2.87, -2.75;

/* ---- the motion works, the dial and the hands (in front of the plate) ---- */
INSERT INTO movement.piece (part, piece, material, profile, z0, z1)
SELECT 'Cannon pinion', 'pinion', 'steel', ST_Difference(movement.gear(12, 0.125, 1.125, 'motion'), movement.circle(0, 0, 0.26, 24)), 1.30, 1.60
UNION ALL SELECT 'Cannon pinion', 'pipe', 'steel', movement.annulus(0, 0, 0.45, 0.26, 32), 1.60, 2.95
UNION ALL SELECT 'Minute wheel', 'wheel', 'gilt',
                 movement.crossed(movement.gear(36, 0.125, 0.375, 'motion'), movement.rim(36, 0.125, 'motion') + 0.05, 0.6, 0.32, 4, 0.15),
                 1.35, 1.50
UNION ALL SELECT 'Minute wheel', 'hub', 'gilt', movement.annulus(0, 0, 0.6, 0.32, 32), 1.50, 1.62
UNION ALL SELECT 'Minute wheel', 'pinion', 'steel', ST_Difference(movement.gear(10, 0.12, 1.2, 'motion'), movement.circle(0, 0, 0.32, 24)), 1.62, 1.92
UNION ALL SELECT 'Hour wheel', 'wheel', 'gilt',
                 movement.crossed(movement.gear(40, 0.12, 0.3, 'motion'), movement.rim(40, 0.12, 'motion') + 0.05, 0.8, 0.47, 4, 0.15),
                 1.70, 1.85
UNION ALL SELECT 'Hour wheel', 'pipe', 'gilt', movement.annulus(0, 0, 0.62, 0.47, 32), 1.85, 2.75

UNION ALL SELECT 'Dial', 'dial', 'dial',
                 ST_Difference(movement.circle(0, 0, 12.9, 256),
                               ST_Union(movement.circle(0, 0, 0.75, 48), movement.disc('fourth', 0.3, 24))),
                 2.40, 2.60
UNION ALL SELECT 'Dial', 'feet', 'gilt', ST_Union(movement.disc('dial foot 1', 0.25, 24), movement.disc('dial foot 2', 0.25, 24)), 0.60, 2.40
UNION ALL SELECT 'Dial', 'markers', 'gilt',
                 (SELECT ST_Union(ST_Rotate(ST_MakeEnvelope(-0.25, 10.6, 0.25, 12.0), radians(-30 * k))) FROM generate_series(0, 11) AS k),
                 2.60, 2.68
UNION ALL SELECT 'Dial', 'seconds ring', 'gilt', ST_Difference(movement.disc('fourth', 2.0, 96), movement.disc('fourth', 1.9, 96)), 2.60, 2.62

/* a hand is turned to its own angle, so its hole can't line up facet for facet with its pipe:
   the bores are a sliding fit, just bigger than the pipe's n-gon corners (r / cos(180/n)) */
UNION ALL SELECT 'Hour hand',    'hand', 'blued', movement.hand(1.2, 0.32, 5.4, 0.8, 0.90, 0.630, 32), 2.68, 2.73
UNION ALL SELECT 'Minute hand',  'hand', 'blued', movement.hand(1.4, 0.22, 8.6, 0.7, 0.65, 0.455, 32), 2.88, 2.93
UNION ALL SELECT 'Seconds hand', 'hand', 'blued', movement.hand(0.6, 0.07, 1.6, 0.3, 0.22, 0.103, 16), 2.62, 2.66

/* ---- the stem lies along x: its profiles are in the y z plane, centred on z 0.6 (mid-plate) ---- */
UNION ALL SELECT 'Stem', 'stem',  'steel', movement.circle(0, 0.6, 0.45, 32), 9.0, 13.7
UNION ALL SELECT 'Stem', 'tube',  'steel', movement.circle(0, 0.6, 0.90, 32), 13.7, 14.1
UNION ALL SELECT 'Stem', 'crown', 'gilt',  movement.knurl(0, 0.6, 1.8, 1.65, 24), 14.1, 15.9;

/* =====================================================================
   PLACING: each piece turned to its part's angle and moved to its arbor
   ===================================================================== */
CREATE FUNCTION movement.place() RETURNS void LANGUAGE sql AS $$
UPDATE movement.piece AS pc
SET world = CASE WHEN p.arbor IS NULL THEN pc.profile
                 ELSE ST_Translate(ST_Rotate(pc.profile, radians(p.phase)), a.x, a.y) END
FROM movement.part AS p LEFT JOIN movement.arbor AS a ON a.arbor = p.arbor
WHERE p.part = pc.part
$$;

/* Turn one part about its arbor, a tooth's worth in `steps` steps, and
   find where it is clear of another part's piece. The answer is the
   middle of the longest clear run: the most backlash either way. */
CREATE FUNCTION movement.clear_phase(moving_part text, moving_piece text, fixed_part text, fixed_piece text,
                                     teeth int, steps int DEFAULT 240)
RETURNS float8 LANGUAGE plpgsql AS $$
DECLARE
    cx float8; cy float8; mv geometry; fx geometry;
    clear boolean[]; start_at int := NULL; run int := 0; best int := 0; best_mid float8 := NULL; idx int;
BEGIN
    SELECT a.x, a.y, pc.world INTO cx, cy, mv
    FROM movement.piece AS pc JOIN movement.part AS p ON p.part = pc.part JOIN movement.arbor AS a ON a.arbor = p.arbor
    WHERE pc.part = moving_part AND pc.piece = moving_piece;
    SELECT world INTO fx FROM movement.piece WHERE part = fixed_part AND piece = fixed_piece;

    SELECT array_agg(NOT ST_Intersects(ST_Rotate(mv, radians(360.0 / teeth * j / steps), cx, cy), fx) ORDER BY j)
    INTO clear FROM generate_series(0, steps - 1) AS j;

    FOR j IN 1 .. steps LOOP                    -- start just after a blocked step, so runs don't wrap
        IF NOT clear[j] THEN start_at := j; EXIT; END IF;
    END LOOP;
    IF start_at IS NULL THEN RETURN 0; END IF;  -- never touches
    FOR k IN 1 .. steps LOOP
        idx := (start_at + k - 1) % steps + 1;
        IF clear[idx] THEN
            run := run + 1;
            IF run > best THEN best := run; best_mid := start_at + k - (run - 1) / 2.0 - 1; END IF;
        ELSE
            run := 0;
        END IF;
    END LOOP;
    IF best = 0 THEN RAISE EXCEPTION '% never clears %', moving_part, fixed_part; END IF;
    RETURN 360.0 / teeth * best_mid / steps;
END $$;

/* Phase the train from the escapement outwards, then the motion works */
CREATE FUNCTION movement.phase_meshes() RETURNS TABLE (mesh_no int, part text, turned_deg float8) LANGUAGE plpgsql AS $$
DECLARE m movement.mesh; d float8;
BEGIN
    PERFORM movement.place();
    FOR m IN SELECT * FROM movement.mesh ORDER BY seq LOOP
        IF m.moves = 'driver' THEN
            d := movement.clear_phase(m.driver_part, m.driver_piece, m.driven_part, m.driven_piece, m.driver_teeth);
            UPDATE movement.part AS p SET phase = p.phase + d WHERE p.part = m.driver_part;
            mesh_no := m.mesh_no; part := m.driver_part;
        ELSE
            d := movement.clear_phase(m.driven_part, m.driven_piece, m.driver_part, m.driver_piece, m.driven_teeth);
            UPDATE movement.part AS p SET phase = p.phase + d WHERE p.part = m.driven_part;
            mesh_no := m.mesh_no; part := m.driven_part;
        END IF;
        turned_deg := d;
        PERFORM movement.place();
        RETURN NEXT;
    END LOOP;
END $$;

/* The click, as in Part 1: its spring pushes it in as far as it will go.
   Lift it until it clears the ratchet, then let it drop to the top of
   that clear run (0.05 deg steps, -14 .. +4 deg). */
CREATE FUNCTION movement.phase_click() RETURNS float8 LANGUAGE plpgsql AS $$
DECLARE cx float8; cy float8; mv geometry; fx geometry; a float8 := 0;
BEGIN
    PERFORM movement.place();
    SELECT x, y INTO cx, cy FROM movement.arbor WHERE arbor = 'click';
    SELECT world INTO mv FROM movement.piece WHERE part = 'Click';
    SELECT world INTO fx FROM movement.piece WHERE part = 'Ratchet';
    WHILE a > -14 AND ST_Intersects(ST_Rotate(mv, radians(a), cx, cy), fx) LOOP a := a - 0.05; END LOOP;
    WHILE a < 4 AND NOT ST_Intersects(ST_Rotate(mv, radians(a + 0.05), cx, cy), fx) LOOP a := a + 0.05; END LOOP;
    UPDATE movement.part SET phase = phase + a WHERE part = 'Click';
    PERFORM movement.place();
    RETURN a;
END $$;

SELECT * FROM movement.phase_meshes();
SELECT movement.phase_click() AS click_deg;
