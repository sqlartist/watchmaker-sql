/* =====================================================================
   The Watchmaker, Part 2  —  pg/08_run.sql
   Episode 6: a minute of the watch's life, and the export.

   The escapement sets the pace: the balance swings, the fork flicks, the
   escape wheel steps. Everything upstream follows the escape wheel back
   through the gearing laws (the mainspring keeps every driving tooth
   pressed on its pinion): fourth wheel, third, centre, barrel. The
   cannon pinion turns with the centre arbor, and the motion works follow
   it forwards to the hour wheel. The hands ride on their arbors.

   The rest pose becomes the run's first frame: the teeth that were set
   in the middle of their backlash now sit where the run puts them, on
   the driving flank, and the 3D solids are rebuilt there.
   ===================================================================== */

CREATE TABLE movement.frame
(
    frame_no  int PRIMARY KEY,
    t         float8 NOT NULL,       -- seconds
    balance   float8 NOT NULL,       -- every arbor's angle, deg, anticlockwise seen from the dial
    pallet    float8 NOT NULL,
    escape    float8 NOT NULL,
    fourth    float8 NOT NULL,
    third     float8 NOT NULL,
    centre    float8 NOT NULL,
    barrel    float8 NOT NULL,
    cannon    float8,
    minute    float8,
    hour      float8
);

/* which series turns each part (the hands go round with their arbors) */
CREATE TABLE movement.drive
(
    part      text PRIMARY KEY REFERENCES movement.part ON DELETE CASCADE,
    series    text NOT NULL
);
INSERT INTO movement.drive VALUES
    ('Balance', 'balance'), ('Pallet fork', 'pallet'), ('Escape arbor', 'escape'), ('Fourth arbor', 'fourth'),
    ('Third arbor', 'third'), ('Centre arbor', 'centre'), ('Barrel', 'barrel'), ('Barrel cover', 'barrel'),
    ('Cannon pinion', 'cannon'), ('Minute wheel', 'minute'), ('Hour wheel', 'hour'),
    ('Seconds hand', 'fourth'), ('Minute hand', 'cannon'), ('Hour hand', 'hour');

/* The hairspring breathes rather than turning: one solid every 10 deg of balance */
CREATE TABLE movement.hairspring_pose
(
    dbeta     float8 PRIMARY KEY,    -- balance angle from its rest pose, deg
    mesh      geometry NOT NULL
);

CREATE FUNCTION movement.run(seconds float8 DEFAULT 60)
RETURNS TABLE (step text, rows_ int, ms int) LANGUAGE plpgsql AS $$
DECLARE t0 timestamptz := clock_timestamp(); beats int; et float8; f0 movement.frame;
        s_e int; s_4 int; s_3 int; s_c int; s_b int; s_m int; s_h int;
BEGIN
    beats := round(seconds * 2 * (SELECT hz FROM movement.esc_grid));
    PERFORM movement.run_escapement(beats);
    step := 'escapement, ' || beats || ' beats'; SELECT count(*) INTO rows_ FROM movement.esc_frame;
    ms := (extract(epoch FROM clock_timestamp() - t0) * 1000)::int; RETURN NEXT;

    t0 := clock_timestamp();
    et := movement.esc_turn();
    SELECT max(spin) FILTER (WHERE arbor = 'escape'), max(spin) FILTER (WHERE arbor = 'fourth'),
           max(spin) FILTER (WHERE arbor = 'third'),  max(spin) FILTER (WHERE arbor = 'centre'),
           max(spin) FILTER (WHERE arbor = 'barrel'), max(spin) FILTER (WHERE arbor = 'minute'),
           max(spin) FILTER (WHERE arbor = 'hour')
    INTO s_e, s_4, s_3, s_c, s_b, s_m, s_h FROM movement.spin;

    /* the train, back from the escape wheel: progress = spin x angle */
    DELETE FROM movement.frame;
    INSERT INTO movement.frame (frame_no, t, balance, pallet, escape, fourth, third, centre, barrel)
    SELECT f.frame_no, f.t, et + f.beta, et + f.phi, et + f.theta, s_4 * p4, s_3 * p3, s_c * pc, s_b * pb
    FROM movement.esc_frame AS f
    CROSS JOIN LATERAL (SELECT movement.untransmit(4, s_e * (et + f.theta)) AS p4) AS a
    CROSS JOIN LATERAL (SELECT movement.untransmit(3, a.p4) AS p3) AS b
    CROSS JOIN LATERAL (SELECT movement.untransmit(2, b.p3) AS pc) AS c
    CROSS JOIN LATERAL (SELECT movement.untransmit(1, c.pc) AS pb) AS d;

    /* the motion works, forwards from the cannon pinion (which starts at 0 and turns with the centre arbor) */
    SELECT * INTO f0 FROM movement.frame WHERE frame_no = 0;
    UPDATE movement.frame AS fr SET cannon = c.cannon, minute = s_m * pm, hour = s_h * movement.transmit(6, pm)
    FROM (SELECT frame_no, centre - f0.centre AS cannon FROM movement.frame) AS c
    CROSS JOIN LATERAL (SELECT movement.transmit(5, s_c * c.cannon) AS pm) AS m
    WHERE fr.frame_no = c.frame_no;
    step := 'train and motion works'; SELECT count(*) INTO rows_ FROM movement.frame;
    ms := (extract(epoch FROM clock_timestamp() - t0) * 1000)::int; RETURN NEXT;

    /* the first frame is the rest pose */
    t0 := clock_timestamp();
    SELECT * INTO f0 FROM movement.frame WHERE frame_no = 0;
    UPDATE movement.part AS p SET phase = CASE d.series
            WHEN 'balance' THEN f0.balance WHEN 'pallet' THEN f0.pallet WHEN 'escape' THEN f0.escape
            WHEN 'fourth' THEN f0.fourth WHEN 'third' THEN f0.third WHEN 'centre' THEN f0.centre
            WHEN 'barrel' THEN f0.barrel WHEN 'cannon' THEN f0.cannon WHEN 'minute' THEN f0.minute
            WHEN 'hour' THEN f0.hour END
    FROM movement.drive AS d WHERE d.part = p.part AND p.part NOT LIKE '% hand';
    UPDATE movement.part SET phase = f0.balance WHERE part = 'Hairspring';
    PERFORM movement.place();
    PERFORM movement.build_meshes();

    DELETE FROM movement.hairspring_pose;
    INSERT INTO movement.hairspring_pose
    SELECT db, movement.prism(ST_Translate(ST_Rotate(ST_Buffer(movement.hairspring_line(db, 24), 0.018, 'endcap=flat join=round quad_segs=2'),
                                                     radians(f0.balance)), a.x, a.y), pc.z0, pc.z1)
    FROM generate_series(-220, 0, 10) AS db, movement.arbor AS a, movement.piece AS pc
    WHERE a.arbor = 'balance' AND pc.part = 'Hairspring' AND pc.piece = 'spring';
    step := 'rest pose = frame 0, solids rebuilt'; SELECT count(*) INTO rows_ FROM movement.piece;
    ms := (extract(epoch FROM clock_timestamp() - t0) * 1000)::int; RETURN NEXT;
END $$;

/* =====================================================================
   EXPORT: everything the viewer draws, as computed here. Coordinates in
   micrometres (integers) to keep the file small; the run as each
   series' turn since frame 0.
   ===================================================================== */
CREATE FUNCTION movement.mesh_json(mesh geometry) RETURNS json LANGUAGE sql IMMUTABLE AS $$
SELECT json_agg(v ORDER BY t.n, u.k)
FROM movement.triangles(mesh) AS t,
     LATERAL unnest(ARRAY[t.x1, t.y1, t.z1, t.x2, t.y2, t.z2, t.x3, t.y3, t.z3]) WITH ORDINALITY AS u (c, k),
     LATERAL (SELECT round(u.c * 1000)::int AS v) AS q
$$;

CREATE FUNCTION movement.export_json() RETURNS json LANGUAGE sql STABLE AS $$
SELECT json_build_object(
    'units', 'um',
    'time', (SELECT json_build_object('h', max(value) FILTER (WHERE name = 'hours'), 'm', max(value) FILTER (WHERE name = 'minutes'),
                                      's', max(value) FILTER (WHERE name = 'seconds')) FROM movement.setting),
    'parts', (SELECT json_agg(json_build_object(
                  'part', p.part, 'axis', p.axis, 'base', p.is_base, 'arbor', p.arbor,
                  'centre', CASE WHEN a.arbor IS NULL THEN NULL ELSE json_build_array(a.x, a.y) END,
                  'series', d.series,
                  'round', r.round, 'level', coalesce(r.level, 0),
                  'dir', json_build_array(coalesce(r.dx, 0), coalesce(r.dy, 0), coalesce(r.dz, 0)),
                  'pieces', (SELECT json_agg(json_build_object('piece', pc.piece, 'material', pc.material,
                                                               'pos', movement.mesh_json(pc.mesh)) ORDER BY pc.piece)
                             FROM movement.piece AS pc WHERE pc.part = p.part))
              ORDER BY coalesce(r.round, 0), p.part)
              FROM movement.part AS p
              LEFT JOIN movement.arbor AS a ON a.arbor = p.arbor
              LEFT JOIN movement.removal AS r ON r.part = p.part
              LEFT JOIN movement.drive AS d ON d.part = p.part),
    'breathing', (SELECT json_agg(json_build_object('dbeta', dbeta, 'pos', movement.mesh_json(mesh)) ORDER BY dbeta)
                  FROM movement.hairspring_pose),
    'run', (SELECT json_build_object(
                'beats', (SELECT count(*) FROM movement.v_beat),
                't',       json_agg(round(f.t::numeric, 6) ORDER BY f.frame_no),
                'balance', json_agg(round((f.balance - f0.balance)::numeric, 3) ORDER BY f.frame_no),
                'pallet',  json_agg(round((f.pallet - f0.pallet)::numeric, 3) ORDER BY f.frame_no),
                'escape',  json_agg(round((f.escape - f0.escape)::numeric, 3) ORDER BY f.frame_no),
                'fourth',  json_agg(round((f.fourth - f0.fourth)::numeric, 4) ORDER BY f.frame_no),
                'third',   json_agg(round((f.third - f0.third)::numeric, 5) ORDER BY f.frame_no),
                'centre',  json_agg(round((f.centre - f0.centre)::numeric, 6) ORDER BY f.frame_no),
                'barrel',  json_agg(round((f.barrel - f0.barrel)::numeric, 7) ORDER BY f.frame_no),
                'cannon',  json_agg(round((f.cannon - f0.cannon)::numeric, 6) ORDER BY f.frame_no),
                'minute',  json_agg(round((f.minute - f0.minute)::numeric, 6) ORDER BY f.frame_no),
                'hour',    json_agg(round((f.hour - f0.hour)::numeric, 7) ORDER BY f.frame_no),
                'phase',   json_agg(CASE e.phase WHEN 'locked' THEN 0 WHEN 'unlocking' THEN 1 WHEN 'impulse' THEN 2 ELSE 3 END
                                    + CASE e.stone WHEN 'entry' THEN 4 WHEN 'exit' THEN 8 ELSE 0 END ORDER BY f.frame_no))
            FROM movement.frame AS f
            JOIN movement.esc_frame AS e ON e.frame_no = f.frame_no
            CROSS JOIN (SELECT * FROM movement.frame WHERE frame_no = 0) AS f0)
)
$$;

SELECT * FROM movement.run(60);
SELECT count(*) AS pieces_sharing_space FROM movement.clashes();
SELECT * FROM movement.take_apart();
