/* =====================================================================
   The Watchmaker, Part 2  —  demo_movement.sql
   A guided tour of the 3D movement. Run build.sql first, then this a
   section at a time (psql, pgAdmin or DBeaver; pgAdmin's geometry viewer
   shows the 2D profiles).
   ===================================================================== */

/* 1. Where the arbors went: bearings typed in, distances from the teeth */
SELECT arbor, from_arbor, bearing, round(distance::numeric, 4) AS distance,
       round(x::numeric, 4) AS x, round(y::numeric, 4) AS y
FROM movement.arbor ORDER BY x;

/* 2. The hour wheel is placed by going out to the minute wheel and back
      again (two meshes, two modules). Does it land on the centre? */
SELECT ST_Distance(movement.pt('hour'), movement.pt('centre')) AS hour_wheel_off_centre_mm;

/* 3. The rest angles the database found, turning each wheel until its
      teeth sat clear of its neighbour's (from the escapement outwards) */
SELECT part, round(phase::numeric, 3) AS phase_deg FROM movement.part WHERE arbor IS NOT NULL ORDER BY part;

/* 4. One wheel, from profile to solid: a 2D polygon, then a TIN Z */
SELECT ST_NPoints(world) AS profile_points, ST_NumPatches(mesh) AS triangles,
       movement.volume(mesh) AS volume_mm3, ST_Area(world) * (z1 - z0) AS area_x_height,
       movement.open_edges(mesh) AS open_edges
FROM movement.piece WHERE part = 'Centre arbor' AND piece = 'wheel';

/* 5. What a solid looks like: a screw head, 32 sides */
SELECT left(ST_AsText(mesh), 300) || ' ...' AS screw_head FROM movement.piece
WHERE part = 'Screw, balance cock' AND piece = 'head';

/* 6. Every piece: watertight, and volume = area x height */
SELECT count(*) AS pieces, sum(triangles) AS triangles,
       count(*) FILTER (WHERE open_edges > 0) AS leaky,
       max(abs(volume_mm3 - area_x_height)) AS worst_volume_error_mm3,
       round(sum(volume_mm3)::numeric, 1) AS total_mm3
FROM movement.v_solid;

/* 7. Does anything share space? (none should) */
SELECT * FROM movement.clashes();

/* 8. Take it apart. Nobody wrote the order down. */
SELECT * FROM movement.take_apart();

/* 9. The race: the same 7,201-point wheel turned 100 times.
      SQL Server, with dbo.fn_Rotate rewriting WKT text: 21 s. */
SELECT sum(ST_NPoints(ST_Rotate(g, radians(3.6 * k)))) AS points_moved
FROM (SELECT movement.gear(80, 0.13, 0.325, 'wheel', 40) AS g) AS w, generate_series(1, 100) AS k;

/* =====================================================================
   EPISODE 6: IT RUNS
   ===================================================================== */

/* 10. The gearing laws, measured from the teeth where they sit in 3D.
       Nobody typed 8, 7.5, 10, 1/3 or 1/4. */
SELECT * FROM movement.v_mesh;

/* 11. The escapement's four questions, asked once (about 0.9 s) */
SELECT 'wheel x fork' AS map, count(*) AS cells, count(*) FILTER (WHERE clear) AS clear FROM movement.esc_wheel_fork
UNION ALL SELECT 'jewel x fork', count(*), count(*) FILTER (WHERE clear) FROM movement.esc_jewel_fork
UNION ALL SELECT 'fork x pins', count(*), count(*) FILTER (WHERE clear) FROM movement.esc_pin;

/* 12. The first few beats: lock, recoil, impulse, drop, 12 deg a beat */
SELECT * FROM movement.v_beat WHERE beat <= 4;

/* 13. One minute later. The escape wheel has stepped 300 times; how far did everything else go? */
SELECT round((f1.escape - f0.escape)::numeric, 6) AS escape, round((f1.fourth - f0.fourth)::numeric, 6) AS fourth_seconds,
       round((f1.third - f0.third)::numeric, 6) AS third, round((f1.centre - f0.centre)::numeric, 6) AS centre_minutes,
       round((f1.barrel - f0.barrel)::numeric, 6) AS barrel, round((f1.hour - f0.hour)::numeric, 6) AS hour_hand
FROM movement.frame AS f0, movement.frame AS f1
WHERE f0.frame_no = 0 AND f1.frame_no = (SELECT max(frame_no) FROM movement.frame);
