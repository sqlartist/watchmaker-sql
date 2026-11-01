/* =====================================================================
   The Watchmaker, Part 2  —  pg/04_solids.sql
   Solids, and the first 3D question: does anything share space?

   SFCGAL can extrude a polygon (CG_Extrude) and has true solid booleans,
   but on this build its exact arithmetic is far too slow for watch parts
   (minutes for the volume of one wheel). So the database builds each
   solid's surface itself, from native PostGIS parts:
     lids    ST_TriangulatePolygon (GEOS's constrained Delaunay; holes and all)
     walls   ST_DumpSegments, two triangles per edge
     placing ST_Affine with a full 3D matrix
   giving a closed TIN Z per piece. The one thing missing is a way to make a
   TRIANGLE from coordinates, so the TIN is assembled as text: the same
   trick Part 1 needed for every rotation, needed here once per solid.
   ===================================================================== */

CREATE FUNCTION movement.xyz(x float8, y float8, z float8) RETURNS text LANGUAGE sql IMMUTABLE AS
$$ SELECT x::text || ' ' || y::text || ' ' || z::text $$;

/* A prism: the profile swept from z0 to z1, as a closed TIN Z. Each
   triangle is wound so its normal points out of the solid. For a part
   that lies along x (the stem) the profile is in the y z plane, and
   ST_Affine turns the prism round onto its axis. */
CREATE FUNCTION movement.prism(profile geometry, z0 float8, z1 float8, axis char DEFAULT 'z')
RETURNS geometry LANGUAGE sql IMMUTABLE AS $$
WITH p AS (SELECT ST_ForcePolygonCCW(profile) AS g),             -- outer rings anticlockwise, holes clockwise
lid AS (
    SELECT ST_ForcePolygonCCW(d.geom) AS t
    FROM p, ST_Dump(ST_TriangulatePolygon(p.g)) AS d),
corner AS (
    SELECT t, ST_X(ST_PointN(r, 1)) AS x1, ST_Y(ST_PointN(r, 1)) AS y1, ST_X(ST_PointN(r, 2)) AS x2,
              ST_Y(ST_PointN(r, 2)) AS y2, ST_X(ST_PointN(r, 3)) AS x3, ST_Y(ST_PointN(r, 3)) AS y3
    FROM lid, LATERAL (SELECT ST_ExteriorRing(t) AS r) AS e),
edge AS (                                                        -- the solid is on the left of every edge
    SELECT ST_X(ST_StartPoint(s.geom)) AS ax, ST_Y(ST_StartPoint(s.geom)) AS ay,
           ST_X(ST_EndPoint(s.geom)) AS bx, ST_Y(ST_EndPoint(s.geom)) AS by_
    FROM p, ST_DumpSegments(p.g) AS s),
tri AS (
    SELECT movement.xyz(x1, y1, z1) AS a, movement.xyz(x2, y2, z1) AS b, movement.xyz(x3, y3, z1) AS c FROM corner   -- top
    UNION ALL
    SELECT movement.xyz(x1, y1, z0), movement.xyz(x3, y3, z0), movement.xyz(x2, y2, z0) FROM corner                  -- bottom
    UNION ALL
    SELECT movement.xyz(ax, ay, z0), movement.xyz(bx, by_, z0), movement.xyz(bx, by_, z1) FROM edge                  -- walls
    UNION ALL
    SELECT movement.xyz(ax, ay, z0), movement.xyz(bx, by_, z1), movement.xyz(ax, ay, z1) FROM edge),
tin AS (SELECT ST_GeomFromText('TIN Z (' || string_agg('((' || a || ',' || b || ',' || c || ',' || a || '))', ',') || ')') AS g FROM tri)
SELECT CASE axis WHEN 'x' THEN ST_Affine(g, 0, 0, 1,  1, 0, 0,  0, 1, 0,  0, 0, 0)   -- (u, v, w) -> (x, y, z) = (w, u, v)
                 ELSE g END
FROM tin
$$;

/* every piece's solid, where it sits */
CREATE FUNCTION movement.build_meshes() RETURNS void LANGUAGE sql AS $$
UPDATE movement.piece AS pc
SET mesh = movement.prism(pc.world, pc.z0, pc.z1, p.axis)
FROM movement.part AS p WHERE p.part = pc.part
$$;

/* =====================================================================
   CHECKS ON THE SOLIDS THEMSELVES
   ===================================================================== */
/* The triangles of a TIN, one row each, with their corners */
CREATE FUNCTION movement.triangles(tin geometry)
RETURNS TABLE (n int, x1 float8, y1 float8, z1 float8, x2 float8, y2 float8, z2 float8, x3 float8, y3 float8, z3 float8)
LANGUAGE sql IMMUTABLE AS $$
SELECT d.path[1], ST_X(a), ST_Y(a), ST_Z(a), ST_X(b), ST_Y(b), ST_Z(b), ST_X(c), ST_Y(c), ST_Z(c)
FROM ST_Dump(tin) AS d,
     LATERAL (SELECT ST_ExteriorRing(d.geom) AS r) AS e,
     LATERAL (SELECT ST_PointN(e.r, 1) AS a, ST_PointN(e.r, 2) AS b, ST_PointN(e.r, 3) AS c) AS p
$$;

/* Volume of a closed surface: add up the signed tetrahedra each triangle
   makes with the origin (the divergence theorem). Ten lines of SQL for
   what CG_Volume takes minutes over. */
CREATE FUNCTION movement.volume(tin geometry) RETURNS float8 LANGUAGE sql IMMUTABLE AS $$
SELECT sum(x1 * (y2 * z3 - z2 * y3) - y1 * (x2 * z3 - z2 * x3) + z1 * (x2 * y3 - y2 * x3)) / 6
FROM movement.triangles(tin)
$$;

/* Is it watertight? Every edge must be used twice, once each way round.
   Returns the number of edges that are not. */
CREATE FUNCTION movement.open_edges(tin geometry) RETURNS bigint LANGUAGE sql IMMUTABLE AS $$
WITH e AS (
    SELECT movement.xyz(x1, y1, z1) AS p, movement.xyz(x2, y2, z2) AS q FROM movement.triangles(tin)
    UNION ALL SELECT movement.xyz(x2, y2, z2), movement.xyz(x3, y3, z3) FROM movement.triangles(tin)
    UNION ALL SELECT movement.xyz(x3, y3, z3), movement.xyz(x1, y1, z1) FROM movement.triangles(tin)),
c AS (SELECT p, q, count(*) AS uses FROM e GROUP BY p, q)
SELECT count(*) FROM c
WHERE c.uses <> 1 OR NOT EXISTS (SELECT 1 FROM c AS r WHERE r.p = c.q AND r.q = c.p AND r.uses = 1)
$$;

CREATE VIEW movement.v_solid AS
SELECT pc.part, pc.piece, pc.material,
       ST_NumPatches(pc.mesh)                             AS triangles,
       movement.volume(pc.mesh)                           AS volume_mm3,
       ST_Area(pc.world) * (pc.z1 - pc.z0)                AS area_x_height,
       movement.open_edges(pc.mesh)                       AS open_edges
FROM movement.piece AS pc;

/* =====================================================================
   DOES ANYTHING SHARE SPACE?
   Two pieces of different parts clash if their solids overlap (touching
   is fine: a screw head sits on its bridge, a hand on its pipe).

   Two prisms on the same axis overlap exactly when their profiles overlap
   in area AND their z ranges overlap: the 3D question factors into a 2D
   one and an interval test. That part SQL Server could answer too. A
   prism on another axis (the stem) has no such shortcut: there the test
   is ST_3DIntersects on the two surfaces, plus a point-in-solid test in
   case one is wholly inside the other.
   ===================================================================== */
CREATE FUNCTION movement.inside(pt geometry, world geometry, z0 float8, z1 float8, axis char)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
SELECT CASE axis WHEN 'x' THEN ST_X(pt) > z0 AND ST_X(pt) < z1 AND ST_Contains(world, ST_MakePoint(ST_Y(pt), ST_Z(pt)))
                 ELSE ST_Z(pt) > z0 AND ST_Z(pt) < z1 AND ST_Contains(world, ST_MakePoint(ST_X(pt), ST_Y(pt))) END
$$;

CREATE FUNCTION movement.first_corner(tin geometry) RETURNS geometry LANGUAGE sql IMMUTABLE AS
$$ SELECT ST_PointN(ST_ExteriorRing(ST_GeometryN(tin, 1)), 1) $$;

CREATE VIEW movement.v_piece AS
SELECT pc.*, p.axis, p.is_base FROM movement.piece AS pc JOIN movement.part AS p ON p.part = pc.part;

CREATE FUNCTION movement.clashes()
RETURNS TABLE (part_a text, piece_a text, part_b text, piece_b text, test text, overlap float8)
LANGUAGE sql STABLE AS $$
SELECT a.part, a.piece, b.part, b.piece, 'same axis', ST_Area(ST_Intersection(a.world, b.world))
FROM movement.v_piece AS a
JOIN movement.v_piece AS b ON a.part < b.part AND a.axis = b.axis
WHERE a.axis = 'z'
  AND a.z0 < b.z1 - 1e-9 AND b.z0 < a.z1 - 1e-9
  AND a.world && b.world
  AND ST_Relate(a.world, b.world, '2********')
UNION ALL
SELECT a.part, a.piece, b.part, b.piece, '3D', NULL
FROM movement.v_piece AS a
JOIN movement.v_piece AS b ON a.part <> b.part AND a.axis = 'x' AND b.axis = 'z'
WHERE a.mesh &&& b.mesh
  AND (ST_3DIntersects(a.mesh, b.mesh)
       OR movement.inside(movement.first_corner(a.mesh), b.world, b.z0, b.z1, b.axis)
       OR movement.inside(movement.first_corner(b.mesh), a.world, a.z0, a.z1, a.axis))
$$;

SELECT movement.build_meshes();
