/* =====================================================================
   The Watchmaker, Part 2  —  pg/07_escapement.sql
   Episode 6: the escapement, Part 1's solver ported to PostGIS.

   The maps are the same questions as Part 1, asked in the escapement's
   own units (wheel tip radius R = 10):
     wheel_fork  wheel turned i x 0.1 deg (one tooth = 240), fork j x 0.1 deg (-8 .. +8): clear?
     jewel_fork  balance at -45 + b x 0.25 deg, fork j: is the impulse jewel clear of the lever?
     pin         fork j: clear of the banking pins?
     face        which stone face would the wheel touch one step further on?
   Then the solver: drive the balance, and let the fork and the wheel go
   wherever the metal allows. The balance swings as a sine at 2.5 Hz
   (18,000 beats an hour); frames are filmed in slow motion near the fork
   (0.75 deg of balance a frame) and quickly elsewhere (6 deg), and every
   frame carries its time, so the viewer can play it back at any speed.
   ===================================================================== */

CREATE TABLE movement.esc_grid
(
    id          int PRIMARY KEY CHECK (id = 1),
    theta_step  float8, phi_step float8, phi_min float8, phi_max float8,
    beta_step   float8, beta_max float8,
    wheel_cap   int,                 -- the wheel moves at most this many steps a frame
    amplitude   float8, slow float8, fine float8, coarse float8,
    hz          float8               -- balance swings a second
);
INSERT INTO movement.esc_grid VALUES (1, 0.1, 0.1, -8, 8, 0.25, 45, 15, 110, 30, 0.75, 6, 2.5);

CREATE TABLE movement.esc_wheel_fork (i int, j int, clear boolean NOT NULL, face smallint NOT NULL, PRIMARY KEY (i, j));
CREATE TABLE movement.esc_jewel_fork (b int, j int, clear boolean NOT NULL, PRIMARY KEY (b, j));
CREATE TABLE movement.esc_pin        (j int PRIMARY KEY, clear boolean NOT NULL);

CREATE TABLE movement.esc_frame
(
    frame_no  int PRIMARY KEY,
    t         float8 NOT NULL,       -- seconds
    beta      float8 NOT NULL,       -- balance, deg
    phi       float8 NOT NULL,       -- fork
    theta     float8 NOT NULL,       -- wheel (unbounded: it keeps going round)
    phase     text NOT NULL,         -- locked | unlocking | impulse | drop
    stone     text,                  -- entry | exit
    face      text                   -- lock | impulse
);

/* ---- the shapes the maps are made of ---- */
/* the only part of the wheel that can reach the pallets: clipped at rest, then turned */
CREATE FUNCTION movement.esc_wheel_contact() RETURNS geometry LANGUAGE sql STABLE AS $$
SELECT ST_Intersection(movement.escape_wheel(),
         ST_Difference((SELECT movement.ring(ARRAY[ST_MakePoint(0, 0)] || array_agg(movement.polar(14.0, a) ORDER BY a))
                        FROM generate_series(10, 150, 5) AS a),
                       movement.circle(0, 0, 6.0, 128)))
$$;

/* the fork at phi: steel, entry stone and exit stone each turned about the pallet arbor, then joined */
CREATE FUNCTION movement.esc_fork(phi float8) RETURNS geometry LANGUAGE sql STABLE AS $$
SELECT ST_Union(ARRAY[ST_Rotate(ST_Union(movement.pallet_body(), movement.lever()), radians(phi), p),
                      ST_Rotate(movement.stone(s.entry_lock), radians(phi), p),
                      ST_Rotate(movement.stone(s.exit_lock), radians(phi), p)])
FROM movement.esc_spec AS s, LATERAL (SELECT movement.esc_p() AS p) AS q
$$;

/* a stone's working faces at phi: 'lock' (outer end to locking corner) or 'impulse' (locking corner to discharge corner) */
CREATE FUNCTION movement.esc_face(stone text, face text, phi float8) RETURNS geometry LANGUAGE sql STABLE AS $$
SELECT ST_Rotate(CASE face WHEN 'lock' THEN ST_MakeLine(ST_PointN(q.edge, 1), ST_PointN(q.edge, 2))
                           ELSE ST_MakeLine(ST_PointN(q.edge, 2), ST_PointN(q.edge, 3)) END,
                 radians(phi), movement.esc_p())
FROM movement.esc_spec AS s,
     LATERAL (SELECT ST_ExteriorRing(movement.stone(CASE stone WHEN 'entry' THEN s.entry_lock ELSE s.exit_lock END)) AS edge) AS q
$$;

CREATE FUNCTION movement.esc_jewel(beta float8) RETURNS geometry LANGUAGE sql STABLE AS $$
SELECT movement.circle(ST_X(b) + s.rj * sin(radians(beta)), ST_Y(b) - s.rj * cos(radians(beta)), s.jewel_r, 48)
FROM movement.esc_spec AS s, LATERAL (SELECT movement.esc_bal() AS b) AS q
$$;

/* ---- the maps ---- */
CREATE FUNCTION movement.build_esc_maps() RETURNS TABLE (map text, cells bigint, clear bigint, ms int) LANGUAGE plpgsql AS $$
DECLARE g movement.esc_grid; n_theta int; n_phi int; n_beta int; t0 timestamptz := clock_timestamp();
BEGIN
    SELECT * INTO g FROM movement.esc_grid;
    n_theta := round(360.0 / (SELECT teeth FROM movement.esc_spec) / g.theta_step);
    n_phi   := round((g.phi_max - g.phi_min) / g.phi_step) + 1;
    n_beta  := round(2 * g.beta_max / g.beta_step) + 1;
    DELETE FROM movement.esc_wheel_fork; DELETE FROM movement.esc_jewel_fork; DELETE FROM movement.esc_pin;

    CREATE TEMP TABLE w ON COMMIT DROP AS                 -- wheel poses, and one step further on
    SELECT i, ST_Rotate(c.g, radians(i * g.theta_step)) AS now_, ST_Rotate(c.g, radians((i + 1) * g.theta_step)) AS next_
    FROM generate_series(0, n_theta - 1) AS i, (SELECT movement.esc_wheel_contact() AS g) AS c;
    CREATE TEMP TABLE f ON COMMIT DROP AS                 -- fork poses and their faces
    SELECT j, movement.esc_fork(phi) AS fork, ST_Rotate(movement.lever(), radians(phi), movement.esc_p()) AS lever,
           movement.esc_face('entry', 'lock', phi) AS f1, movement.esc_face('entry', 'impulse', phi) AS f2,
           movement.esc_face('exit', 'lock', phi) AS f3, movement.esc_face('exit', 'impulse', phi) AS f4
    FROM generate_series(0, n_phi - 1) AS j, LATERAL (SELECT g.phi_min + j * g.phi_step AS phi) AS a;

    INSERT INTO movement.esc_wheel_fork
    SELECT w.i, f.j, NOT ST_Intersects(w.now_, f.fork),
           CASE WHEN ST_Intersects(w.next_, f.f1) THEN 1 WHEN ST_Intersects(w.next_, f.f2) THEN 2   -- lock faces win at a shared corner
                WHEN ST_Intersects(w.next_, f.f3) THEN 3 WHEN ST_Intersects(w.next_, f.f4) THEN 4 ELSE 0 END
    FROM w CROSS JOIN f;
    map := 'wheel x fork'; SELECT count(*), count(*) FILTER (WHERE esc_wheel_fork.clear) INTO cells, clear FROM movement.esc_wheel_fork;
    ms := (extract(epoch FROM clock_timestamp() - t0) * 1000)::int; RETURN NEXT;

    t0 := clock_timestamp();
    CREATE TEMP TABLE jw ON COMMIT DROP AS
    SELECT b, movement.esc_jewel(-g.beta_max + b * g.beta_step) AS jewel FROM generate_series(0, n_beta - 1) AS b;
    INSERT INTO movement.esc_jewel_fork
    SELECT jw.b, f.j, NOT ST_Intersects(jw.jewel, f.lever) FROM jw CROSS JOIN f;
    DROP TABLE jw;
    map := 'jewel x fork'; SELECT count(*), count(*) FILTER (WHERE esc_jewel_fork.clear) INTO cells, clear FROM movement.esc_jewel_fork;
    ms := (extract(epoch FROM clock_timestamp() - t0) * 1000)::int; RETURN NEXT;

    t0 := clock_timestamp();
    INSERT INTO movement.esc_pin SELECT f.j, NOT ST_Intersects(f.fork, (SELECT movement.banking_pins())) FROM f;
    map := 'fork x pins'; SELECT count(*), count(*) FILTER (WHERE esc_pin.clear) INTO cells, clear FROM movement.esc_pin;
    ms := (extract(epoch FROM clock_timestamp() - t0) * 1000)::int; RETURN NEXT;
    DROP TABLE w; DROP TABLE f;
END $$;

/* ---- the solver ----
   Each frame:
     1. the jewel shoves the fork to the nearest angle clear of it, and a
        stone that ends up in a tooth drives the wheel back (recoil);
     2. the fork drifts the way the tooth is pushing it: back towards its
        banking while the tooth sits on a locking face (draw), onwards while
        it rides an impulse face, until the jewel, a pin or the wheel stops it;
     3. the wheel turns forward until it touches a stone (at most wheel_cap
        steps a frame). 2 and 3 repeat until nothing moves. */
CREATE FUNCTION movement.run_escapement(beats int) RETURNS TABLE (frames int, seconds float8, ms int) LANGUAGE plpgsql AS $$
DECLARE
    g movement.esc_grid; n_theta int; n_phi int; n_beta int;
    wf boolean[]; cf smallint[]; fj boolean[]; pin boolean[];
    faces text[] := ARRAY['entry lock', 'entry impulse', 'exit lock', 'exit impulse'];
    omega float8; t0 timestamptz := clock_timestamp();
    beta float8; dir int := -1; half int := 0; step float8; tt float8;
    j int; n int; n0 int; b int; push int := -1; prev_face text := 'lock';
    shoved boolean; moved boolean; jj int; back int; code int; drift int;
    st text; fc text; ph text; f int := 0; done boolean;
BEGIN
    SELECT * INTO g FROM movement.esc_grid;
    n_theta := round(360.0 / (SELECT teeth FROM movement.esc_spec) / g.theta_step);
    n_phi   := round((g.phi_max - g.phi_min) / g.phi_step) + 1;
    n_beta  := round(2 * g.beta_max / g.beta_step) + 1;
    omega   := 2 * pi() * g.hz;
    wf  := ARRAY(SELECT m.clear FROM movement.esc_wheel_fork AS m ORDER BY m.i, m.j);    -- [i * n_phi + j + 1]
    cf  := ARRAY(SELECT m.face  FROM movement.esc_wheel_fork AS m ORDER BY m.i, m.j);
    fj  := ARRAY(SELECT m.clear FROM movement.esc_jewel_fork AS m ORDER BY m.b, m.j);    -- [b * n_phi + j + 1]
    pin := ARRAY(SELECT m.clear FROM movement.esc_pin AS m ORDER BY m.j);                -- [j + 1]
    DELETE FROM movement.esc_frame;

    /* start: entry stone locked, fork on its banking, a tooth on its way to the entry stone */
    j := round((-(SELECT bank_deg FROM movement.esc_spec) - g.phi_min) / g.phi_step);
    n := round(2.0 / g.theta_step);
    WHILE wf[movement.fmod(n + 1, n_theta)::int * n_phi + j + 1] LOOP n := n + 1; END LOOP;

    beta := g.amplitude;
    LOOP
        /* this frame's time: beta = A cos(omega t), half swing `half` */
        tt := (half * pi() + acos(greatest(-1, least(1, CASE WHEN half % 2 = 0 THEN beta ELSE -beta END / g.amplitude)))) / omega;
        b := round((beta + g.beta_max) / g.beta_step);
        IF b < 0 OR b >= n_beta THEN b := NULL; END IF;
        n0 := n; shoved := false;

        /* 1. the jewel shoves the fork out of its way */
        IF b IS NOT NULL AND NOT fj[b * n_phi + j + 1] THEN
            FOR d IN 1 .. n_phi - 1 LOOP
                jj := NULL;
                IF j - d >= 0 AND pin[j - d + 1] AND fj[b * n_phi + (j - d) + 1] THEN jj := j - d;
                ELSIF j + d < n_phi AND pin[j + d + 1] AND fj[b * n_phi + (j + d) + 1] THEN jj := j + d; END IF;
                IF jj IS NOT NULL THEN
                    push := CASE WHEN jj > j THEN 1 ELSE -1 END; j := jj; shoved := true; EXIT;
                END IF;
            END LOOP;
            back := 0;
            WHILE NOT wf[movement.fmod(n, n_theta)::int * n_phi + j + 1] AND back < 200 LOOP n := n - 1; back := back + 1; END LOOP;
        END IF;

        /* 2./3. the fork drifts the way the wheel pushes it; the wheel follows */
        FOR it IN 1 .. 200 LOOP
            moved := false;
            code := cf[movement.fmod(n, n_theta)::int * n_phi + j + 1];
            drift := CASE WHEN code = 1 THEN -1 WHEN code = 3 THEN 1 ELSE push END;     -- draw: towards the banking
            IF j + drift >= 0 AND j + drift < n_phi AND pin[j + drift + 1]
               AND (b IS NULL OR fj[b * n_phi + (j + drift) + 1])
               AND wf[movement.fmod(n, n_theta)::int * n_phi + (j + drift) + 1] THEN
                j := j + drift; push := drift; moved := true;
            END IF;
            WHILE n - n0 < g.wheel_cap AND wf[movement.fmod(n + 1, n_theta)::int * n_phi + j + 1] LOOP
                n := n + 1; moved := true;
            END LOOP;
            EXIT WHEN NOT moved;
        END LOOP;

        code := cf[movement.fmod(n, n_theta)::int * n_phi + j + 1];
        st := CASE WHEN code > 0 THEN split_part(faces[code], ' ', 1) END;
        fc := CASE WHEN code > 0 THEN split_part(faces[code], ' ', 2) END;
        ph := CASE WHEN n < n0 OR (shoved AND n = n0) THEN 'unlocking'
                   WHEN n = n0 THEN 'locked'
                   WHEN fc = 'impulse' THEN 'impulse'
                   WHEN fc = 'lock' AND prev_face = 'lock' THEN 'locked'          -- drawn in to the banking
                   ELSE 'drop' END;
        prev_face := fc;
        INSERT INTO movement.esc_frame VALUES (f, tt, beta, g.phi_min + j * g.phi_step, n * g.theta_step, ph, st, fc);
        f := f + 1;

        /* the next balance angle: slow motion near the fork */
        EXIT WHEN half >= beats;
        step := CASE WHEN abs(beta) < g.slow THEN g.fine ELSE g.coarse END;
        beta := round((beta + dir * step)::numeric, 4);
        IF abs(beta) >= g.amplitude THEN
            beta := dir * g.amplitude; dir := -dir; half := half + 1;
        END IF;
    END LOOP;

    frames := f; seconds := tt; ms := (extract(epoch FROM clock_timestamp() - t0) * 1000)::int;
    RETURN NEXT;
END $$;

/* What the run says, beat by beat (deg of wheel, and the fork's swing) */
CREATE VIEW movement.v_beat AS
WITH x AS (
    SELECT f.*, lag(phase) OVER w AS prev_phase, lag(theta) OVER w AS prev_theta, lag(stone) OVER w AS prev_stone
    FROM movement.esc_frame AS f WINDOW w AS (ORDER BY frame_no)),
s AS (SELECT x.*, sum(CASE WHEN phase = 'unlocking' AND prev_phase = 'locked' THEN 1 ELSE 0 END) OVER (ORDER BY frame_no) AS beat
      FROM x),
b AS (SELECT s.*, first_value(prev_theta) OVER (PARTITION BY beat ORDER BY frame_no) AS theta0 FROM s WHERE beat > 0)
SELECT beat,
       min(prev_stone) FILTER (WHERE phase = 'unlocking' AND prev_phase = 'locked')        AS stone,
       round(min(t)::numeric, 4)                                                          AS starts_s,
       round(min(theta - theta0) FILTER (WHERE phase = 'unlocking')::numeric, 2)          AS recoil_deg,
       round(sum(theta - prev_theta) FILTER (WHERE phase = 'impulse')::numeric, 2)        AS impulse_deg,
       round(sum(theta - prev_theta) FILTER (WHERE phase = 'drop')::numeric, 2)           AS drop_deg,
       round(sum(theta - prev_theta)::numeric, 2)                                         AS advance_deg,
       round((max(phi) - min(phi))::numeric, 2)                                           AS fork_swing_deg
FROM b GROUP BY beat ORDER BY beat;

SELECT * FROM movement.build_esc_maps();
