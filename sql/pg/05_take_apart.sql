/* =====================================================================
   The Watchmaker, Part 2  —  pg/05_take_apart.sql
   Taking the watch apart, and the exploded view that comes out of it.

   No list of steps is typed in. Every round, each part still in the watch
   tries to slide out along its axis, away from the mainplate: off the
   back (-z), off the front (+z), or, for the stem, out sideways (+x).
   It can go if nothing still in the watch is in its way, all the way out.
   Everything that can go in a round goes together. The rounds are the
   order a watchmaker works in; how many rounds a part waits is how far it
   sits from the plate in the exploded view.

   "In its way" is the swept solid: the part's prism stretched out to
   infinity along the way it leaves. Same-axis pairs use the exact 2D +
   interval test, as in the clash check; the stem uses real 3D tests.
   ===================================================================== */

/* the way each part leaves: away from the plate's middle (z 0.6), or out along x */
CREATE VIEW movement.v_way_out AS
SELECT p.part, p.axis, p.is_base,
       CASE WHEN p.axis = 'x' THEN 1
            WHEN (min(pc.z0) + max(pc.z1)) / 2 < 0.6 THEN -1 ELSE 1 END AS s
FROM movement.part AS p JOIN movement.piece AS pc ON pc.part = p.part
GROUP BY p.part, p.axis, p.is_base;

/* Does `mover`, sliding out (s = +1 / -1 along its axis), hit any piece of
   a part still in the watch? */
CREATE FUNCTION movement.blocked(mover text, s int) RETURNS boolean LANGUAGE sql STABLE AS $$
SELECT EXISTS (
    SELECT 1
    FROM movement.v_piece AS a
    JOIN movement.v_piece AS q ON q.part <> a.part
    CROSS JOIN LATERAL (SELECT CASE WHEN s < 0 THEN a.z0 - 100 ELSE a.z0 END AS lo,
                               CASE WHEN s < 0 THEN a.z1 ELSE a.z1 + 100 END AS hi) AS w
    WHERE a.part = mover
      AND NOT EXISTS (SELECT 1 FROM movement.removal AS r WHERE r.part = q.part)
      AND CASE
            WHEN a.axis = q.axis THEN                          -- same axis: profiles overlap, and q is on the way out
                 a.world && q.world AND (CASE WHEN s < 0 THEN q.z0 < a.z1 - 1e-9 ELSE q.z1 > a.z0 + 1e-9 END)
                 AND ST_Relate(a.world, q.world, '2********')
            ELSE                                               -- across axes: the swept solid, in 3D
                 EXISTS (SELECT 1
                         FROM (SELECT movement.prism(a.world, w.lo, w.hi, a.axis) AS sweep) AS sw
                         WHERE sw.sweep &&& q.mesh
                           AND (ST_3DIntersects(sw.sweep, q.mesh)
                                OR movement.inside(movement.first_corner(q.mesh), a.world, w.lo, w.hi, a.axis)
                                OR movement.inside(movement.first_corner(sw.sweep), q.world, q.z0, q.z1, q.axis)))
          END)
$$;

CREATE FUNCTION movement.take_apart() RETURNS TABLE (round int, way text, parts text) LANGUAGE plpgsql AS $$
DECLARE r int := 0; free text[];
BEGIN
    DELETE FROM movement.removal;
    LOOP
        r := r + 1;
        free := ARRAY(SELECT o.part FROM movement.v_way_out AS o
                      WHERE NOT o.is_base
                        AND NOT EXISTS (SELECT 1 FROM movement.removal AS m WHERE m.part = o.part)
                        AND NOT movement.blocked(o.part, o.s));
        EXIT WHEN cardinality(free) = 0;
        INSERT INTO movement.removal (part, round, dx, dy, dz)
        SELECT o.part, r, CASE WHEN o.axis = 'x' THEN o.s ELSE 0 END, 0, CASE WHEN o.axis = 'z' THEN o.s ELSE 0 END
        FROM movement.v_way_out AS o WHERE o.part = ANY (free);
    END LOOP;

    IF EXISTS (SELECT 1 FROM movement.part AS p
               WHERE NOT p.is_base AND NOT EXISTS (SELECT 1 FROM movement.removal AS m WHERE m.part = p.part)) THEN
        RAISE EXCEPTION 'stuck: % cannot come out',
            (SELECT string_agg(p.part, ', ') FROM movement.part AS p
             WHERE NOT p.is_base AND NOT EXISTS (SELECT 1 FROM movement.removal AS m WHERE m.part = p.part));
    END IF;

    /* the exploded view: the last off sits one layer out from the plate, the first off furthest */
    UPDATE movement.removal AS m SET level = g.last_round - m.round + 1
    FROM (SELECT dx, dy, dz, max(removal.round) AS last_round FROM movement.removal GROUP BY dx, dy, dz) AS g
    WHERE g.dx = m.dx AND g.dy = m.dy AND g.dz = m.dz;

    RETURN QUERY
    SELECT m.round, CASE WHEN m.dz < 0 THEN 'off the back' WHEN m.dz > 0 THEN 'off the front' ELSE 'out sideways' END,
           string_agg(m.part, ', ' ORDER BY m.part)
    FROM movement.removal AS m GROUP BY m.round, 2 ORDER BY m.round, 2;
END $$;

SELECT * FROM movement.take_apart();
