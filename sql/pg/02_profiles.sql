/* =====================================================================
   The Watchmaker, Part 2  —  pg/02_profiles.sql
   The parts' outlines, ported from Part 1's SQL Server functions.

   Compare these with Part 1. There is no dbo.fn_Affine here, no WKT
   built up as strings and no STPointN loops: PostGIS has ST_MakeLine over
   an array of points, ST_Rotate, ST_Scale, ST_Translate and ST_Affine,
   and generate_series feeds them directly. The shapes are the same
   point for point (verify_movement.py checks them against the Python
   mirror, which matches SQL Server).
   ===================================================================== */

/* the point at radius r, angle deg (anticlockwise from +x) about (cx, cy) */
CREATE FUNCTION movement.polar(r float8, deg float8, cx float8 DEFAULT 0, cy float8 DEFAULT 0)
RETURNS geometry LANGUAGE sql IMMUTABLE AS
$$ SELECT ST_MakePoint(cx + r * cos(radians(deg)), cy + r * sin(radians(deg))) $$;

/* a polygon through these points, closed */
CREATE FUNCTION movement.ring(pts geometry[])
RETURNS geometry LANGUAGE sql IMMUTABLE AS
$$ SELECT ST_MakePolygon(ST_AddPoint(ST_MakeLine(pts), pts[1])) $$;

/* an explicit n-gon, so the Python mirror can build exactly the same one */
CREATE FUNCTION movement.circle(cx float8, cy float8, r float8, n int)
RETURNS geometry LANGUAGE sql IMMUTABLE AS
$$ SELECT movement.ring(array_agg(movement.polar(r, 360.0 * k / n, cx, cy) ORDER BY k))
   FROM generate_series(0, n - 1) AS k $$;

CREATE FUNCTION movement.annulus(cx float8, cy float8, r_out float8, r_in float8, n int)
RETURNS geometry LANGUAGE sql IMMUTABLE AS
$$ SELECT ST_Difference(movement.circle(cx, cy, r_out, n), movement.circle(cx, cy, r_in, n)) $$;

/* =====================================================================
   TEETH
   ===================================================================== */
/* How far to roll the epicycloid: to the addendum circle ('R') or the
   tooth's centre line ('A'). Sixty halvings, as in Part 1. Never more than
   a quarter turn of the base circle: past that the curve's angle wraps. */
CREATE FUNCTION movement.epi_end(a float8, rho float8, ra float8, g float8, mode char)
RETURNS float8 LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    lo float8 := 0;
    hi float8 := least(pi() * rho / a, pi() / 2);
    k  float8 := (a + rho) / rho;
    mid float8; ex float8; ey float8;
BEGIN
    FOR i IN 1 .. 60 LOOP
        mid := (lo + hi) / 2;
        ex := (a + rho) * cos(mid) - rho * cos(k * mid);
        ey := (a + rho) * sin(mid) - rho * sin(k * mid);
        IF (CASE mode WHEN 'R' THEN sqrt(ex * ex + ey * ey) - ra ELSE degrees(atan2(ey, ex)) - g END) >= 0 THEN
            hi := mid;
        ELSE
            lo := mid;
        END IF;
    END LOOP;
    RETURN hi;
END $$;

/* A gear of z teeth, module m, centred on the origin, tooth 0 on 0 deg:
   epicycloid addendum rolled by a circle of radius rho (half the partner's
   pitch radius), radial dedendum. `kind` picks the tooth form. One tooth
   is a list of (deg, radius); the gear is that list turned z times. */
CREATE FUNCTION movement.gear(z int, m float8, rho float8, kind text, pts int DEFAULT NULL)
RETURNS geometry LANGUAGE sql STABLE AS $$
WITH f AS (
    SELECT m * z / 2.0 AS a, m * z / 2.0 + ha * m AS ra, m * z / 2.0 - hf * m AS rr,
           degrees(s * m / 2 / (m * z / 2.0)) AS g, 360.0 / z AS pitch, coalesce(pts, flank_pts) AS np
    FROM movement.form WHERE form.kind = gear.kind),
c AS (
    SELECT f.*, least(e.tr, e.ta) AS tend, e.ta <= e.tr AS pointed
    FROM f, LATERAL (SELECT movement.epi_end(f.a, rho, f.ra, f.g, 'R') AS tr,
                            movement.epi_end(f.a, rho, f.ra, f.g, 'A') AS ta) AS e),
flank AS (                                   -- the trailing addendum flank, from the pitch circle up
    SELECT j, -c.g + degrees(atan2(p.ey, p.ex)) AS d, sqrt(p.ex * p.ex + p.ey * p.ey) AS rad
    FROM c, generate_series(0, c.np) AS j,
         LATERAL (SELECT (c.a + rho) * cos(c.tend * j / c.np) - rho * cos((c.a + rho) / rho * c.tend * j / c.np) AS ex,
                         (c.a + rho) * sin(c.tend * j / c.np) - rho * sin((c.a + rho) / rho * c.tend * j / c.np) AS ey) AS p),
tooth AS (
    SELECT 0 AS seq, -c.g AS d, c.rr AS rad FROM c                                   -- radial dedendum
    UNION ALL SELECT 1 + j, d, rad FROM flank                                        -- trailing flank up
    UNION ALL SELECT 1000 + t, fl.d - 2 * fl.d * t / 4.0, c.ra                       -- across the tip
              FROM c, flank AS fl, generate_series(1, 3) AS t WHERE fl.j = c.np AND NOT c.pointed
    UNION ALL SELECT 2000 + (c.np - fl.j), -fl.d, fl.rad                             -- leading flank down
              FROM c, flank AS fl WHERE NOT c.pointed OR fl.j < c.np
    UNION ALL SELECT 3000, c.g, c.rr FROM c
    UNION ALL SELECT 3000 + t, c.g + (c.pitch - 2 * c.g) * t / 4.0, c.rr             -- root arc
              FROM c, generate_series(1, 3) AS t)
SELECT movement.ring(array_agg(movement.polar(t.rad, k * c.pitch + t.d) ORDER BY k, t.seq))
FROM c, generate_series(0, z - 1) AS k, tooth AS t
$$;

/* A pinion of n leaves: radial flanks and a round tip */
CREATE FUNCTION movement.pinion(n int, m float8, tip_step int DEFAULT NULL)
RETURNS geometry LANGUAGE sql STABLE AS $$
WITH f AS (
    SELECT m * n / 2.0 AS rp, m * n / 2.0 - hf * m AS rr, degrees(s * m / 2 / (m * n / 2.0)) AS g,
           360.0 / n AS pitch, coalesce(pinion.tip_step, form.tip_step) AS ts
    FROM movement.form WHERE kind = 'leaf'),
c AS (SELECT f.*, f.rp * cos(radians(f.g)) AS cx, f.rp * sin(radians(f.g)) AS half FROM f),
leaf AS (
    SELECT 0 AS seq, -c.g AS d, c.rr AS rad FROM c
    UNION ALL SELECT 1, -c.g, c.rp FROM c
    UNION ALL SELECT 1000 + a, degrees(atan2(p.py, p.px)), sqrt(p.px * p.px + p.py * p.py)
              FROM c, generate_series(-90 + c.ts, 90 - c.ts, c.ts) AS a,
                   LATERAL (SELECT c.cx + c.half * cos(radians(a)) AS px, c.half * sin(radians(a)) AS py) AS p
    UNION ALL SELECT 2000, c.g, c.rp FROM c
    UNION ALL SELECT 2001, c.g, c.rr FROM c
    UNION ALL SELECT 2001 + t, c.g + (c.pitch - 2 * c.g) * t / 4.0, c.rr FROM c, generate_series(1, 3) AS t)
SELECT movement.ring(array_agg(movement.polar(l.rad, k * c.pitch + l.d) ORDER BY k, l.seq))
FROM c, generate_series(0, n - 1) AS k, leaf AS l
$$;

/* A wheel cut away to a rim, crossings and a hub, with an arbor hole */
CREATE FUNCTION movement.crossed(outline geometry, rim float8, hub float8, hole float8,
                                 arms int, arm_w float8, arm0 float8 DEFAULT 45)
RETURNS geometry LANGUAGE sql IMMUTABLE AS $$
SELECT ST_Difference(
         ST_Difference(outline,
             ST_Difference(movement.annulus(0, 0, rim, hub, 128),
                 (SELECT ST_Union(ST_Buffer(ST_MakeLine(ST_MakePoint(0, 0), movement.polar(rim + 0.1, arm0 + 360.0 / arms * k)),
                                            arm_w, 'quad_segs=4'))
                  FROM generate_series(0, arms - 1) AS k))),
         movement.circle(0, 0, hole, 24))
$$;

/* =====================================================================
   ESCAPEMENT (escapement units: wheel at the origin, pallet arbor at
   P = (0, R / cos 30), balance at P + (0, Lever))
   ===================================================================== */
CREATE FUNCTION movement.esc_p() RETURNS geometry LANGUAGE sql STABLE AS
$$ SELECT ST_MakePoint(0, r / cos(radians(30))) FROM movement.esc_spec $$;

CREATE FUNCTION movement.esc_bal() RETURNS geometry LANGUAGE sql STABLE AS
$$ SELECT ST_MakePoint(0, r / cos(radians(30)) + lever) FROM movement.esc_spec $$;

/* radial travel of a stone per deg of fork */
CREATE FUNCTION movement.esc_k() RETURNS float8 LANGUAGE sql STABLE AS
$$ SELECT radians(1) * r * tan(radians(30)) FROM movement.esc_spec $$;

/* Fifteen club teeth: back face up to the heel, down the club's impulse
   face to the locking corner, down the forward-leaning front face, root arc */
CREATE FUNCTION movement.escape_wheel() RETURNS geometry LANGUAGE sql STABLE AS $$
WITH s AS (SELECT r, rr, club_rise, teeth, 360.0 / teeth AS pitch FROM movement.esc_spec),
tooth AS (
    SELECT v.seq, v.d::float8 AS d, v.rad FROM s, LATERAL (VALUES
        (1, -11.0, s.rr), (2, -8.5, 7.9), (3, -6.5, 8.8), (4, -4.5, 9.55), (5, -3.0, s.r),
        (6, -2.0, s.r - s.club_rise / 3), (7, -1.0, s.r - 2 * s.club_rise / 3), (8, 0.0, s.r - s.club_rise),
        (9, -1.2, 9.05), (10, -2.6, 8.2), (11, -4.2, 7.45), (12, -5.0, s.rr)) AS v (seq, d, rad)
    UNION ALL
    SELECT 12 + j, -5.0 + 18.0 * j / 8, s.rr FROM s, generate_series(1, 7) AS j)
SELECT movement.ring(array_agg(movement.polar(t.rad, k * s.pitch + t.d) ORDER BY k, t.seq))
FROM s, generate_series(0, s.teeth - 1) AS k, tooth AS t
$$;

/* the wheel as made: teeth, five crossings, hub, arbor hole */
CREATE FUNCTION movement.escape_wheel_display() RETURNS geometry LANGUAGE sql STABLE AS $$
SELECT ST_Difference(ST_Difference(movement.escape_wheel(),
           ST_Difference(movement.annulus(0, 0, 6.4, 2.0, 128),
               (SELECT ST_Union(ST_Buffer(ST_MakeLine(ST_MakePoint(0, 0), movement.polar(6.6, 90 + 72 * k)), 0.45, 'quad_segs=4'))
                FROM generate_series(0, 4) AS k))),
       movement.circle(0, 0, 0.5, 24))
$$;

/* A pallet stone. lock_at = angle about the wheel of its locking corner.
   The locking face leans forward by the draw; the impulse face falls
   LiftDeg-worth of fork travel across StoneW deg of wheel. */
CREATE FUNCTION movement.stone(lock_at float8) RETURNS geometry LANGUAGE sql STABLE AS $$
WITH c AS (
    SELECT (s.r + s.lock_deg * k.k) * cos(radians(lock_at)) AS clx,
           (s.r + s.lock_deg * k.k) * sin(radians(lock_at)) AS cly,
           (s.r + (s.lock_deg - s.lift_deg) * k.k) * cos(radians(lock_at + s.stone_w)) AS cex,
           (s.r + (s.lock_deg - s.lift_deg) * k.k) * sin(radians(lock_at + s.stone_w)) AS cey,
           cos(radians(lock_at + s.draw_deg)) AS fx, sin(radians(lock_at + s.draw_deg)) AS fy,
           cos(radians(lock_at + s.stone_w)) AS ux, sin(radians(lock_at + s.stone_w)) AS uy
    FROM movement.esc_spec AS s, LATERAL (SELECT movement.esc_k() AS k) AS k)
SELECT movement.ring(ARRAY[ST_MakePoint(clx + 2.2 * fx, cly + 2.2 * fy), ST_MakePoint(clx, cly),
                           ST_MakePoint(cex, cey), ST_MakePoint(cex + 2.9 * ux, cey + 2.9 * uy)])
FROM c
$$;

/* The lever, arbor to fork; the horns stop at 9.95 */
CREATE FUNCTION movement.lever() RETURNS geometry LANGUAGE sql STABLE AS $$
SELECT ST_Translate(movement.ring(ARRAY[
           ST_MakePoint(-0.45, 0.0), ST_MakePoint(-0.35, 8.0), ST_MakePoint(-1.0, 8.6), ST_MakePoint(-1.0, 9.6),
           ST_MakePoint(-0.75, 9.95), ST_MakePoint(-0.4, 9.95), ST_MakePoint(-0.4, 9.25), ST_MakePoint(0.4, 9.25),
           ST_MakePoint(0.4, 9.95), ST_MakePoint(0.75, 9.95), ST_MakePoint(1.0, 9.6), ST_MakePoint(1.0, 8.6),
           ST_MakePoint(0.35, 8.0), ST_MakePoint(0.45, 0.0)]),
       ST_X(movement.esc_p()), ST_Y(movement.esc_p()))
$$;

/* Pallet body: a bar from stone to stone through the arbor, and the boss */
CREATE FUNCTION movement.pallet_body() RETURNS geometry LANGUAGE sql STABLE AS $$
SELECT ST_Difference(
         ST_Union(ST_Buffer(ST_MakeLine(ARRAY[movement.polar(s.r + 2.4, s.entry_lock + s.stone_w / 2), movement.esc_p(),
                                              movement.polar(s.r + 2.4, s.exit_lock + s.stone_w / 2)]), 0.6, 'quad_segs=16'),
                  movement.circle(ST_X(movement.esc_p()), ST_Y(movement.esc_p()), 1.3, 64)),
         movement.circle(ST_X(movement.esc_p()), ST_Y(movement.esc_p()), 0.35, 24))
FROM movement.esc_spec AS s
$$;

/* Banking pins: they meet the lever's edge 4.5 along it at +/- BankDeg */
CREATE FUNCTION movement.banking_pins() RETURNS geometry LANGUAGE sql STABLE AS $$
WITH p AS (SELECT ST_X(movement.esc_p()) AS px, ST_Y(movement.esc_p()) AS py, s.bank_deg,
                  0.45 - 0.10 * 4.5 / 8.0 AS hw, 0.3 AS pr FROM movement.esc_spec AS s),
c AS (SELECT p.pr,
             ST_Rotate(ST_MakePoint(px - (hw + pr), py + 4.5),  radians(bank_deg), px, py) AS l,
             ST_Rotate(ST_MakePoint(px + (hw + pr), py + 4.5), -radians(bank_deg), px, py) AS r FROM p)
SELECT ST_Union(movement.circle(ST_X(l), ST_Y(l), pr, 48), movement.circle(ST_X(r), ST_Y(r), pr, 48)) FROM c
$$;

/* =====================================================================
   POWER (the barrel arbor at the origin)
   ===================================================================== */
CREATE TABLE movement.power_spec
(
    id int PRIMARY KEY CHECK (id = 1),
    ratchet_teeth int, ratchet_tip float8, ratchet_root float8, pawl_x float8, pawl_y float8,
    rb float8, ra float8, t float8, l float8, pts_per_turn int, free_turns float8, min_pack float8
);
INSERT INTO movement.power_spec VALUES (1, 36, 4.40, 3.95, 5.7, -3.4, 5.0, 1.6, 0.10, 350.0, 48, 1.25, 1.0);

/* Sawtooth, walked anticlockwise: up the radial (locking) face, down the slope */
CREATE FUNCTION movement.ratchet() RETURNS geometry LANGUAGE sql STABLE AS $$
SELECT movement.ring(array_agg(p ORDER BY k, i))
FROM movement.power_spec AS s, generate_series(0, s.ratchet_teeth - 1) AS k,
     LATERAL (VALUES (0, movement.polar(s.ratchet_root, k * 360.0 / s.ratchet_teeth)),
                     (1, movement.polar(s.ratchet_tip, k * 360.0 / s.ratchet_teeth + 0.4))) AS v (i, p)
$$;

/* The click at rest: a head in the gap, an arm 0.6 wide, a boss on its pivot */
CREATE FUNCTION movement.click() RETURNS geometry LANGUAGE sql STABLE AS $$
WITH s AS (SELECT pawl_x AS bx, pawl_y AS by_ FROM movement.power_spec),
a AS (SELECT s.*, ST_X(movement.polar(4.72, -3.0)) AS ax, ST_Y(movement.polar(4.72, -3.0)) AS ay FROM s),
n AS (SELECT a.*, -(by_ - ay) / sqrt((bx - ax) ^ 2 + (by_ - ay) ^ 2) * 0.3 AS nx,
                   (bx - ax) / sqrt((bx - ax) ^ 2 + (by_ - ay) ^ 2) * 0.3 AS ny FROM a)
SELECT ST_Difference(
         ST_Union(ARRAY[
             movement.ring(ARRAY[movement.polar(4.00, -0.6), movement.polar(4.62, -0.6), movement.polar(5.05, -1.5),
                                 movement.polar(4.75, -4.6), movement.polar(4.30, -4.0)]),
             movement.ring(ARRAY[ST_MakePoint(ax + nx, ay + ny), ST_MakePoint(bx + nx, by_ + ny),
                                 ST_MakePoint(bx - nx, by_ - ny), ST_MakePoint(ax - nx, ay - ny)]),
             movement.circle(ax, ay, 0.3, 32), movement.circle(bx, by_, 0.6, 32)]),
         movement.circle(bx, by_, 0.18, 16))
FROM n
$$;

/* Archimedean spiral: radius r0 + dr s after s turns, angle a0 + dir 360 s */
CREATE FUNCTION movement.spiral_pts(r0 float8, dr float8, a0 float8, turns float8, dir int, per_turn int)
RETURNS TABLE (k int, pt geometry) LANGUAGE sql IMMUTABLE AS $$
SELECT j, movement.polar(r0 + dr * (turns * j / (n - 1.0)), a0 + dir * 360.0 * (turns * j / (n - 1.0)))
FROM (SELECT greatest(2, ceil(turns * per_turn)::int + 1) AS n) AS c, generate_series(0, c.n - 1) AS j
$$;

/* the spring's length for so many turns packed on the arbor and on the wall, plus the free coil */
CREATE FUNCTION movement.spring_len(n_in float8, n_out float8) RETURNS float8 LANGUAGE sql STABLE AS $$
SELECT 2 * pi() * n_in * (ra + t / 2 + t * n_in / 2) + 2 * pi() * n_out * (rb - t / 2 - t * n_out / 2)
       + pi() * free_turns * ((ra + t / 2 + t * n_in) + (rb - t / 2 - t * n_out))
FROM movement.power_spec
$$;

/* Turns of spring (packs + free coil) when let down and when fully wound */
CREATE FUNCTION movement.spring_limits(OUT let_down float8, OUT wound float8) LANGUAGE plpgsql STABLE AS $$
DECLARE s movement.power_spec; lo float8; hi float8; mid float8;
BEGIN
    SELECT * INTO s FROM movement.power_spec;
    FOR side IN 0 .. 1 LOOP                     -- 0: MinPack on the arbor; 1: MinPack on the wall
        lo := 0; hi := (s.rb - s.ra) / s.t - s.min_pack - s.free_turns;
        FOR i IN 1 .. 60 LOOP
            mid := (lo + hi) / 2;
            IF movement.spring_len(CASE side WHEN 0 THEN s.min_pack ELSE mid END,
                                   CASE side WHEN 0 THEN mid ELSE s.min_pack END) > s.l THEN hi := mid; ELSE lo := mid; END IF;
        END LOOP;
        IF side = 0 THEN let_down := s.min_pack + hi + s.free_turns; ELSE wound := hi + s.min_pack + s.free_turns; END IF;
    END LOOP;
END $$;

/* The mainspring as one line: inner pack from the arbor, the free coil, the outer pack to the wall */
CREATE FUNCTION movement.spring_line(arbor_deg float8, wound float8) RETURNS geometry LANGUAGE plpgsql STABLE AS $$
DECLARE s movement.power_spec; lo float8 := 0; hi float8; mid float8; n_in float8; n_out float8; r1 float8; r2 float8;
BEGIN
    SELECT * INTO s FROM movement.power_spec;
    hi := wound - s.free_turns;
    FOR i IN 1 .. 60 LOOP                       -- more on the arbor = less length for the same turns
        mid := (lo + hi) / 2;
        IF movement.spring_len(mid, wound - s.free_turns - mid) > s.l THEN lo := mid; ELSE hi := mid; END IF;
    END LOOP;
    n_in := hi; n_out := wound - s.free_turns - hi;
    r1 := s.ra + s.t / 2 + s.t * n_in;
    r2 := s.rb - s.t / 2 - s.t * n_out;
    RETURN (
        SELECT ST_MakeLine(pt ORDER BY seg, k)
        FROM (SELECT 1 AS seg, k, pt FROM movement.spiral_pts(s.ra + s.t / 2, s.t, arbor_deg, n_in, -1, s.pts_per_turn)
              UNION ALL
              SELECT 2, k, pt FROM movement.spiral_pts(r1, (r2 - r1) / s.free_turns, arbor_deg - 360 * n_in, s.free_turns, -1, s.pts_per_turn)
              WHERE k > 0
              UNION ALL
              SELECT 3, k, pt FROM movement.spiral_pts(r2, s.t, arbor_deg - 360 * (n_in + s.free_turns), n_out, -1, s.pts_per_turn)
              WHERE k > 0) AS p);
END $$;

/* The hairspring: twelve turns from r 0.45 to 2.2. Its inner end turns
   with the balance (dbeta deg from rest); its outer end is held by the
   stud. In between, each point turns in proportion, so the coils breathe. */
CREATE FUNCTION movement.hairspring_line(dbeta float8, per_turn int) RETURNS geometry LANGUAGE sql IMMUTABLE AS $$
SELECT ST_MakeLine(movement.polar(0.45 + 1.75 * s, -90 + 360.0 * 12 * s + dbeta * (1 - s)) ORDER BY k)
FROM generate_series(0, 12 * per_turn) AS k, LATERAL (SELECT k / (12.0 * per_turn) AS s) AS q
$$;

/* =====================================================================
   SMALL THINGS
   ===================================================================== */
/* a knurled edge: n ridges between radii r_in and r_out */
CREATE FUNCTION movement.knurl(cx float8, cy float8, r_out float8, r_in float8, n int)
RETURNS geometry LANGUAGE sql IMMUTABLE AS
$$ SELECT movement.ring(array_agg(movement.polar(CASE WHEN j % 2 = 0 THEN r_out ELSE r_in END, 180.0 * j / n, cx, cy) ORDER BY j))
   FROM generate_series(0, 2 * n - 1) AS j $$;

/* a hand pointing to 12, with a hole of radius `bore` (an n-gon) */
CREATE FUNCTION movement.hand(tail float8, w float8, len float8, tip float8, boss float8, bore float8, bore_n int)
RETURNS geometry LANGUAGE sql IMMUTABLE AS $$
SELECT ST_Difference(ST_Union(movement.ring(ARRAY[ST_MakePoint(-w, -tail), ST_MakePoint(w, -tail), ST_MakePoint(w * 0.75, len),
                                                  ST_MakePoint(0, len + tip), ST_MakePoint(-w * 0.75, len)]),
                              movement.circle(0, 0, boss, 48)),
                     movement.circle(0, 0, bore, bore_n))
$$;
