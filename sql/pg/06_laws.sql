/* =====================================================================
   The Watchmaker, Part 2  —  pg/06_laws.sql
   Episode 6: it runs. First, the gearing law of every pair of wheels,
   measured from the teeth where they now sit in the movement.

   Part 1's method, in PostGIS. For each driver angle (60 steps a tooth)
   and driven angle (120 steps a tooth): do the two overlap? For each
   driver angle, the least the driven gear must have turned to be clear
   is the "push edge"; refined twice more, sixteen ways each, and
   unwrapped across the tooth, it is the law that carries motion through
   the mesh. Contact-quality teeth (40 points a flank, leaf tips every
   5 deg); the 3D model is drawn with coarser ones that sit inside them.

   Both shapes are cut down to the lens where their tip circles overlap
   before testing: they can only touch in there, and it makes every test
   small. Part 1 used fixed wedges and zones for the same reason.
   ===================================================================== */

/* which way each arbor turns when the watch runs (+1 anticlockwise, seen from the dial) */
CREATE TABLE movement.spin
(
    arbor   text PRIMARY KEY REFERENCES movement.arbor,
    spin    smallint NOT NULL
);
INSERT INTO movement.spin VALUES
    ('barrel', 1), ('centre', -1), ('third', 1), ('fourth', -1), ('escape', 1), ('minute', 1), ('hour', -1);

CREATE TABLE movement.law_form
(
    id        int PRIMARY KEY CHECK (id = 1),
    nu        int NOT NULL,          -- driver grid, steps per tooth
    nv        int NOT NULL,          -- driven grid, steps per tooth
    refine    int NOT NULL,
    rounds    int NOT NULL,
    flank_pts int NOT NULL,          -- contact-quality teeth
    tip_step  int NOT NULL
);
INSERT INTO movement.law_form VALUES (1, 60, 120, 16, 2, 40, 5);

CREATE TABLE movement.mesh_map                -- each mesh's configuration space
(
    mesh_no   int NOT NULL,
    i         int NOT NULL,
    j         int NOT NULL,
    clear     boolean NOT NULL,
    PRIMARY KEY (mesh_no, i, j)
);

CREATE TABLE movement.edge                    -- the push edge
(
    mesh_no   int NOT NULL,
    i         int NOT NULL,
    runs      int NOT NULL,                   -- clear runs in this row: 1 = fine
    lo        float8,                         -- driven blocked here (deg, forwards) ...
    hi        float8,                         -- ... and clear here
    edge_deg  float8,                         -- hi within one tooth
    progress  float8,                         -- unwrapped across the driver's tooth
    PRIMARY KEY (mesh_no, i)
);

CREATE TABLE movement.law                     -- the push edge as an array, for the run
(
    mesh_no   int PRIMARY KEY,
    pu        float8 NOT NULL,                -- driver tooth pitch, deg
    pv        float8 NOT NULL,                -- driven tooth pitch, deg
    prog      float8[] NOT NULL               -- driven progress at each driver step
);

/* A mesh's gear, contact quality, built about its own arbor. A gear's
   epicycloids are rolled by half its partner's pitch radius. */
CREATE FUNCTION movement.contact_shape(mesh_no int, side text) RETURNS geometry LANGUAGE sql STABLE AS $$
SELECT CASE WHEN kind = 'leaf' THEN movement.pinion(teeth, m.module, f.tip_step)
            ELSE movement.gear(teeth, m.module, m.module * partner / 4.0, kind, f.flank_pts) END
FROM movement.mesh AS m, movement.law_form AS f,
     LATERAL (SELECT CASE side WHEN 'driver' THEN m.driver_kind  ELSE m.driven_kind  END AS kind,
                     CASE side WHEN 'driver' THEN m.driver_teeth ELSE m.driven_teeth END AS teeth,
                     CASE side WHEN 'driver' THEN m.driven_teeth ELSE m.driver_teeth END AS partner) AS s
WHERE m.mesh_no = contact_shape.mesh_no
$$;

CREATE FUNCTION movement.fmod(x float8, p float8) RETURNS float8 LANGUAGE sql IMMUTABLE AS
$$ SELECT x - p * floor(x / p) $$;

CREATE FUNCTION movement.build_laws()
RETURNS TABLE (mesh_no int, clear_cells bigint, jammed_rows bigint, ms int) LANGUAGE plpgsql AS $$
DECLARE
    f movement.law_form; m record; lens geometry; t0 timestamptz;
    e record; lo float8; hi float8; step float8; v float8; wheel geometry;
BEGIN
    SELECT * INTO f FROM movement.law_form;
    DELETE FROM movement.mesh_map; DELETE FROM movement.edge; DELETE FROM movement.law;

    FOR m IN
        SELECT x.mesh_no, a.x AS dx, a.y AS dy, b.x AS nx, b.y AS ny, sa.spin AS sd, sb.spin AS sn,
               360.0 / x.driver_teeth AS pu, 360.0 / x.driven_teeth AS pv,
               movement.contact_shape(x.mesh_no, 'driver') AS drv, movement.contact_shape(x.mesh_no, 'driven') AS dvn
        FROM movement.mesh AS x
        JOIN movement.arbor AS a ON a.arbor = x.driver_arbor JOIN movement.spin AS sa ON sa.arbor = x.driver_arbor
        JOIN movement.arbor AS b ON b.arbor = x.driven_arbor JOIN movement.spin AS sb ON sb.arbor = x.driven_arbor
        ORDER BY x.mesh_no
    LOOP
        t0 := clock_timestamp();
        lens := ST_Intersection(
            movement.circle(m.dx, m.dy, ST_MaxDistance(ST_MakePoint(0, 0), m.drv) + 0.02, 128),
            movement.circle(m.nx, m.ny, ST_MaxDistance(ST_MakePoint(0, 0), m.dvn) + 0.02, 128));

        /* the map: driver turned i/nu of a tooth, driven j/nv, both forwards */
        CREATE TEMP TABLE drv_pose ON COMMIT DROP AS
        SELECT i, ST_Intersection(ST_Translate(ST_Rotate(m.drv, radians(m.sd * m.pu * i / f.nu)), m.dx, m.dy), lens) AS g
        FROM generate_series(0, f.nu - 1) AS i;
        CREATE TEMP TABLE dvn_pose ON COMMIT DROP AS
        SELECT j, ST_Intersection(ST_Translate(ST_Rotate(m.dvn, radians(m.sn * m.pv * j / f.nv)), m.nx, m.ny), lens) AS g
        FROM generate_series(0, f.nv - 1) AS j;

        INSERT INTO movement.mesh_map
        SELECT m.mesh_no, d.i, n.j, NOT ST_Intersects(d.g, n.g) FROM drv_pose AS d CROSS JOIN dvn_pose AS n;

        /* where each row's clear run starts (circularly) */
        INSERT INTO movement.edge (mesh_no, i, runs, lo, hi)
        SELECT m.mesh_no, c.i, count(*), max(c.j - 1) * m.pv / f.nv, max(c.j) * m.pv / f.nv
        FROM movement.mesh_map AS c
        JOIN movement.mesh_map AS p ON p.mesh_no = c.mesh_no AND p.i = c.i AND p.j = (c.j + f.nv - 1) % f.nv
        WHERE c.mesh_no = m.mesh_no AND c.clear AND NOT p.clear
        GROUP BY c.i;

        /* refine: between the last blocked and first clear driven angle, sixteen ways, twice */
        FOR e IN SELECT ed.i, ed.lo, ed.hi FROM movement.edge AS ed WHERE ed.mesh_no = m.mesh_no AND ed.runs = 1 LOOP
            SELECT g INTO wheel FROM drv_pose WHERE drv_pose.i = e.i;
            lo := e.lo; hi := e.hi;
            FOR rnd IN 1 .. f.rounds LOOP
                step := (hi - lo) / f.refine;
                FOR kk IN 1 .. f.refine LOOP
                    v := lo + kk * step;
                    IF NOT ST_Intersects(wheel, ST_Translate(ST_Rotate(m.dvn, radians(m.sn * v)), m.nx, m.ny)) THEN
                        lo := v - step; hi := v; EXIT;
                    END IF;
                END LOOP;
            END LOOP;
            UPDATE movement.edge AS ed SET lo = refined.a, hi = refined.b, edge_deg = movement.fmod(refined.b, m.pv)
            FROM (SELECT lo AS a, hi AS b) AS refined
            WHERE ed.mesh_no = m.mesh_no AND ed.i = e.i;
        END LOOP;
        DROP TABLE drv_pose; DROP TABLE dvn_pose;

        /* unwrap across the tooth: each step moves the edge by less than half a driven tooth */
        UPDATE movement.edge AS ed SET progress = u.progress
        FROM (SELECT i, first_value(edge_deg) OVER w + coalesce(sum(d) OVER w, 0) AS progress
              FROM (SELECT i, edge_deg,
                           movement.fmod(edge_deg - lag(edge_deg) OVER (ORDER BY i) + m.pv / 2, m.pv) - m.pv / 2 AS d
                    FROM movement.edge WHERE edge.mesh_no = m.mesh_no) AS s
              WINDOW w AS (ORDER BY i ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS u
        WHERE ed.mesh_no = m.mesh_no AND ed.i = u.i;

        INSERT INTO movement.law
        SELECT m.mesh_no, m.pu, m.pv, array_agg(ed.progress ORDER BY ed.i)
        FROM movement.edge AS ed WHERE ed.mesh_no = m.mesh_no;

        mesh_no := m.mesh_no;
        SELECT count(*) FILTER (WHERE clear) INTO clear_cells FROM movement.mesh_map AS mm WHERE mm.mesh_no = m.mesh_no;
        SELECT f.nu - count(*) FILTER (WHERE runs = 1) INTO jammed_rows FROM movement.edge AS ed WHERE ed.mesh_no = m.mesh_no;
        ms := (extract(epoch FROM clock_timestamp() - t0) * 1000)::int;
        RETURN NEXT;
    END LOOP;
END $$;

/* Driven progress for driver progress u (both deg, forwards): the law, interpolated */
CREATE FUNCTION movement.transmit(mesh_no int, u float8) RETURNS float8 LANGUAGE sql STABLE AS $$
SELECT l.prog[c.i + 1] + c.t * (CASE WHEN c.i + 1 < n.nu THEN l.prog[c.i + 2] ELSE l.prog[1] + l.pv END - l.prog[c.i + 1])
       + c.k * l.pv
FROM movement.law AS l, (SELECT nu FROM movement.law_form) AS n,
     LATERAL (SELECT floor(u / l.pu) AS k) AS kk,
     LATERAL (SELECT (u - kk.k * l.pu) / (l.pu / n.nu) AS x) AS xx,
     LATERAL (SELECT kk.k, least(floor(xx.x)::int, n.nu - 1) AS i, xx.x - least(floor(xx.x)::int, n.nu - 1) AS t) AS c
WHERE l.mesh_no = transmit.mesh_no
$$;

/* ... and backwards: the driver progress that puts the driven gear at v.
   The train runs this way, from the escape wheel back to the barrel: the
   mainspring keeps every driving tooth pressed on its pinion. */
CREATE FUNCTION movement.untransmit(mesh_no int, v float8) RETURNS float8 LANGUAGE sql STABLE AS $$
WITH l AS (SELECT * FROM movement.law WHERE law.mesh_no = untransmit.mesh_no),
n AS (SELECT nu FROM movement.law_form),
k AS (SELECT floor((v - l.prog[1]) / l.pv) AS k FROM l),
r AS (SELECT v - k.k * l.pv AS r FROM l, k),
seg AS (                                       -- the step of the law that r falls in
    SELECT s.i, l.prog[s.i + 1] AS p0, CASE WHEN s.i + 1 < n.nu THEN l.prog[s.i + 2] ELSE l.prog[1] + l.pv END AS p1
    FROM l, n, r, generate_series(0, n.nu - 1) AS s (i)
    WHERE l.prog[s.i + 1] <= r.r
    ORDER BY s.i DESC LIMIT 1)
SELECT (seg.i + (r.r - seg.p0) / (seg.p1 - seg.p0)) * l.pu / n.nu + k.k * l.pu
FROM l, n, k, r, seg
$$;

/* What the teeth do: ratio (mean, min, max), whether it ever jams */
CREATE VIEW movement.v_mesh AS
SELECT m.mesh_no, m.driver_part || ' ' || m.driver_teeth || ' -> ' || m.driven_part || ' ' || m.driven_teeth AS mesh,
       CASE WHEN bool_and(r.runs = 1) THEN 'turns' ELSE 'JAMS' END AS verdict,
       round(avg(r.ratio)::numeric, 6) AS mean_ratio,
       round(min(r.ratio)::numeric, 6) AS min_ratio,
       round(max(r.ratio)::numeric, 6) AS max_ratio,
       round(m.driver_teeth::numeric / m.driven_teeth, 6) AS teeth_ratio
FROM movement.mesh AS m
JOIN (SELECT e.mesh_no, e.runs,
             (coalesce(lead(e.progress) OVER (PARTITION BY e.mesh_no ORDER BY e.i), l.prog[1] + l.pv) - e.progress)
             / (l.pu / f.nu) AS ratio
      FROM movement.edge AS e JOIN movement.law AS l ON l.mesh_no = e.mesh_no CROSS JOIN movement.law_form AS f) AS r
  ON r.mesh_no = m.mesh_no
GROUP BY m.mesh_no, m.driver_part, m.driver_teeth, m.driven_part, m.driven_teeth
ORDER BY m.mesh_no;

SELECT * FROM movement.build_laws();
SELECT * FROM movement.v_mesh;
