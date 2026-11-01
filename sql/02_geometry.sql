/* =====================================================================
   The Watchmaker  —  02_geometry.sql
   Geometry builders. Every part is built once, in its rest position, from
   points worked out with SIN and COS. Poses are rotations of those shapes.

   SQL Server's geometry type has no rotate, translate or affine transform,
   so dbo.fn_Affine does it the long way: it rewrites the numbers in the
   shape's WKT text. dbo.fn_Rotate and dbo.fn_Place are built on it.

   Layout of the drawing plane (units: escape wheel tip radius R = 10):
     escape wheel    centred at O = (0, 0), turns anticlockwise
     pallet arbor    P = (0, R / cos 30)  where the tangents at +/-30 deg meet
     balance staff   B = P + (0, Lever)
   ===================================================================== */
USE Watchmaker;
GO
DROP FUNCTION IF EXISTS dbo.fn_Polar;      -- so dbo.fmt can be re-created
GO

/* fixed-point text for WKT (no scientific notation) */
CREATE OR ALTER FUNCTION dbo.fmt (@v float)
RETURNS varchar(32)
WITH SCHEMABINDING
AS
BEGIN
    RETURN LTRIM(STR(@v, 24, 6));
END;
GO

/* 'x y' of the point at radius @r, angle @deg (anticlockwise from +x) about (@cx, @cy) */
CREATE OR ALTER FUNCTION dbo.fn_Polar (@cx float, @cy float, @r float, @deg float)
RETURNS varchar(70)
AS
BEGIN
    RETURN CONCAT(dbo.fmt(@cx + @r * COS(RADIANS(@deg))), ' ', dbo.fmt(@cy + @r * SIN(RADIANS(@deg))));
END;
GO

/* An explicit n-gon. STBuffer would pick its own vertices; this way the
   Python mirror builds exactly the same polygon. */
CREATE OR ALTER FUNCTION dbo.fn_Circle (@cx float, @cy float, @r float, @n int)
RETURNS geometry
AS
BEGIN
    DECLARE @pts varchar(max);
    SELECT @pts = STRING_AGG(CAST(dbo.fn_Polar(@cx, @cy, @r, 360e0 * k.value / @n) AS varchar(max)), ', ')
                  WITHIN GROUP (ORDER BY k.value)
    FROM GENERATE_SERIES(0, @n - 1) AS k;

    RETURN geometry::STGeomFromText(CONCAT('POLYGON((', @pts, ', ', dbo.fn_Polar(@cx, @cy, @r, 0), '))'), 0);
END;
GO

/* The missing ST_Affine (2D):  x' = a x + b y + xoff,  y' = d x + e y + yoff.
   Works on any point, line or polygon, single, multi or a collection.

   It edits the shape's text. The obvious way - walk the points with
   STPointN - re-reads the whole shape on every call when the shape comes
   from a table column (600 ms for a 2,600-point wheel, against 160 ms
   this way). So: STAsText once, split it at the commas, and each piece is
   "<brackets and type words> x y <closing brackets>". Move the x y, keep
   the rest, glue it back together. */
CREATE OR ALTER FUNCTION dbo.fn_Affine (@g geometry, @a float, @b float, @d float, @e float, @xoff float, @yoff float)
RETURNS geometry
WITH INLINE = OFF
AS
BEGIN
    IF @g IS NULL OR @g.STIsEmpty() = 1 RETURN @g;

    DECLARE @out varchar(max);

    SELECT @out = STRING_AGG(CAST(CONCAT(p.Head,
                      LTRIM(STR(@a * c.X + @b * c.Y + @xoff, 24, 6)), ' ',
                      LTRIM(STR(@d * c.X + @e * c.Y + @yoff, 24, 6)), p.Tail) AS varchar(max)), ',')
                  WITHIN GROUP (ORDER BY s.ordinal)
    FROM STRING_SPLIT(@g.STAsText(), ',', 1) AS s
    CROSS APPLY (SELECT PATINDEX('%[0-9-]%', s.value) AS i) AS h                 -- where the numbers start
    CROSS APPLY (SELECT LEFT(s.value, h.i - 1) AS Head, SUBSTRING(s.value, h.i, 100) AS Rest) AS r
    CROSS APPLY (SELECT CHARINDEX(')', r.Rest + ')') AS j) AS t                   -- ... and stop
    CROSS APPLY (SELECT r.Head, LEFT(r.Rest, t.j - 1) AS Pair, SUBSTRING(r.Rest, t.j, 100) AS Tail) AS p
    CROSS APPLY (SELECT CAST(LEFT(p.Pair, CHARINDEX(' ', p.Pair) - 1) AS float) AS X,
                        CAST(SUBSTRING(p.Pair, CHARINDEX(' ', p.Pair) + 1, 50) AS float) AS Y) AS c;

    RETURN geometry::STGeomFromText(@out, 0);
END;
GO

/* ST_Rotate: @deg anticlockwise about (@cx, @cy) */
CREATE OR ALTER FUNCTION dbo.fn_Rotate (@g geometry, @deg float, @cx float, @cy float)
RETURNS geometry
AS
BEGIN
    DECLARE @c float = COS(RADIANS(@deg)), @s float = SIN(RADIANS(@deg));
    RETURN dbo.fn_Affine(@g, @c, -@s, @s, @c, @cx - @cx * @c + @cy * @s, @cy - @cx * @s - @cy * @c);
END;
GO

/* Turn a shape built about the origin by @deg, scale it, and put it at (@x, @y) */
CREATE OR ALTER FUNCTION dbo.fn_Place (@g geometry, @deg float, @x float, @y float, @scale float = 1)
RETURNS geometry
AS
BEGIN
    DECLARE @c float = @scale * COS(RADIANS(@deg)), @s float = @scale * SIN(RADIANS(@deg));
    RETURN dbo.fn_Affine(@g, @c, -@s, @s, @c, @x, @y);
END;
GO

/* =====================================================================
   THE PLACES: pallet arbor and balance staff, from the spec
   ===================================================================== */
CREATE OR ALTER FUNCTION esc.fn_Places ()
RETURNS TABLE
AS
RETURN
    SELECT  0e0                                      AS Px,
            R / COS(RADIANS(30e0))                   AS Py,
            0e0                                      AS BalX,
            R / COS(RADIANS(30e0)) + Lever           AS BalY,
            RADIANS(1e0) * R * TAN(RADIANS(30e0))    AS K      -- radial travel of a stone per deg of fork
    FROM esc.Spec;
GO

/* =====================================================================
   ESCAPE WHEEL
   ===================================================================== */
/* Fifteen club teeth. One tooth is a list of (deg from its locking corner,
   radius), walked anticlockwise: back face up to the heel, down the club's
   impulse face to the locking corner, down the forward-leaning front face,
   then the root arc to the next tooth. */
CREATE OR ALTER FUNCTION esc.fn_WheelOutline ()
RETURNS geometry
AS
BEGIN
    DECLARE @R float, @RR float, @rise float, @teeth int;
    SELECT @R = R, @RR = RR, @rise = ClubRise, @teeth = Teeth FROM esc.Spec;

    DECLARE @pitch float = 360e0 / @teeth, @pts varchar(max);

    WITH tooth (Seq, D, Rad) AS (
        SELECT Seq, D, Rad FROM (VALUES
            (1, -11.0, @RR), (2, -8.5, 7.9), (3, -6.5, 8.8), (4, -4.5, 9.55), (5, -3.0, @R),
            (6, -2.0, @R - @rise / 3), (7, -1.0, @R - 2 * @rise / 3), (8, 0.0, @R - @rise),
            (9, -1.2, 9.05), (10, -2.6, 8.2), (11, -4.2, 7.45), (12, -5.0, @RR)) AS t (Seq, D, Rad)
        UNION ALL
        SELECT 12 + s.value, -5.0 + 18.0 * s.value / 8, @RR      -- root arc to the next tooth
        FROM GENERATE_SERIES(1, 7) AS s
    )
    SELECT @pts = STRING_AGG(CAST(dbo.fn_Polar(0, 0, t.Rad, k.value * @pitch + t.D) AS varchar(max)), ', ')
                  WITHIN GROUP (ORDER BY k.value, t.Seq)
    FROM GENERATE_SERIES(0, @teeth - 1) AS k
    CROSS JOIN tooth AS t;

    RETURN geometry::STGeomFromText(CONCAT('POLYGON((', @pts, ', ', dbo.fn_Polar(0, 0, @RR, -11.0), '))'), 0);
END;
GO

/* The whole wheel, for drawing: teeth, five crossings, hub, arbor hole */
CREATE OR ALTER FUNCTION esc.fn_WheelDisplay ()
RETURNS geometry
AS
BEGIN
    DECLARE @arms geometry;
    SELECT @arms = geometry::UnionAggregate(
                       geometry::STGeomFromText(CONCAT('LINESTRING(0 0, ',
                           dbo.fn_Polar(0, 0, 6.6, 90e0 + 72e0 * k.value), ')'), 0).STBuffer(0.45))
    FROM GENERATE_SERIES(0, 4) AS k;

    DECLARE @windows geometry = dbo.fn_Circle(0, 0, 6.4, 128)
                                  .STDifference(dbo.fn_Circle(0, 0, 2.0, 64))
                                  .STDifference(@arms);

    RETURN esc.fn_WheelOutline().STDifference(@windows).STDifference(dbo.fn_Circle(0, 0, 0.5, 24));
END;
GO

/* The only part of the wheel that can ever reach the pallets, for any turn
   of 0..24 deg: clipped at rest, then rotated, so the sector starts early. */
CREATE OR ALTER FUNCTION esc.fn_WheelContact ()
RETURNS geometry
AS
BEGIN
    DECLARE @pts varchar(max);
    SELECT @pts = STRING_AGG(CAST(dbo.fn_Polar(0, 0, 14.0, a.value) AS varchar(max)), ', ')
                  WITHIN GROUP (ORDER BY a.value)
    FROM GENERATE_SERIES(10, 150, 5) AS a;

    DECLARE @zone geometry = geometry::STGeomFromText(CONCAT('POLYGON((0 0, ', @pts, ', 0 0))'), 0);

    RETURN esc.fn_WheelOutline().STIntersection(@zone.STDifference(dbo.fn_Circle(0, 0, 6.0, 128)));
END;
GO

/* =====================================================================
   PALLET FORK
   ===================================================================== */
/* A stone's four corners. @LockAt = angle about the wheel of its locking
   corner. The locking face leans forward by the draw angle; the impulse
   face falls LiftDeg-worth of fork travel across StoneW deg of wheel. */
CREATE OR ALTER FUNCTION esc.fn_StoneCorners (@LockAt float)
RETURNS TABLE
AS
RETURN
    WITH c AS (
        SELECT  (s.R + s.LockDeg * p.K) * COS(RADIANS(@LockAt))                      AS CLx,
                (s.R + s.LockDeg * p.K) * SIN(RADIANS(@LockAt))                      AS CLy,
                (s.R + (s.LockDeg - s.LiftDeg) * p.K) * COS(RADIANS(@LockAt + s.StoneW)) AS CEx,
                (s.R + (s.LockDeg - s.LiftDeg) * p.K) * SIN(RADIANS(@LockAt + s.StoneW)) AS CEy,
                COS(RADIANS(@LockAt + s.DrawDeg)) AS Fx,   -- radial, leaned forward by the draw
                SIN(RADIANS(@LockAt + s.DrawDeg)) AS Fy,
                COS(RADIANS(@LockAt + s.StoneW))  AS Ux,   -- radial at the discharge corner
                SIN(RADIANS(@LockAt + s.StoneW))  AS Uy
        FROM esc.Spec AS s CROSS JOIN esc.fn_Places() AS p
    )
    SELECT  CLx + 2.2 * Fx AS LOx, CLy + 2.2 * Fy AS LOy,      -- locking face, outer end
            CLx, CLy,                                          -- locking corner
            CEx, CEy,                                          -- discharge corner
            CEx + 2.9 * Ux AS BOx, CEy + 2.9 * Uy AS BOy       -- back, outer end
    FROM c;
GO

/* @Part: 'Stone' (polygon), 'Lock' or 'Impulse' (the working face, as a line) */
CREATE OR ALTER FUNCTION esc.fn_Stone (@LockAt float, @Part varchar(10))
RETURNS geometry
AS
BEGIN
    DECLARE @lo varchar(70), @cl varchar(70), @ce varchar(70), @bo varchar(70);
    SELECT @lo = CONCAT(dbo.fmt(LOx), ' ', dbo.fmt(LOy)),
           @cl = CONCAT(dbo.fmt(CLx), ' ', dbo.fmt(CLy)),
           @ce = CONCAT(dbo.fmt(CEx), ' ', dbo.fmt(CEy)),
           @bo = CONCAT(dbo.fmt(BOx), ' ', dbo.fmt(BOy))
    FROM esc.fn_StoneCorners(@LockAt);

    RETURN geometry::STGeomFromText(CASE @Part
        WHEN 'Lock'    THEN CONCAT('LINESTRING(', @lo, ', ', @cl, ')')
        WHEN 'Impulse' THEN CONCAT('LINESTRING(', @cl, ', ', @ce, ')')
        ELSE CONCAT('POLYGON((', @lo, ', ', @cl, ', ', @ce, ', ', @bo, ', ', @lo, '))') END, 0);
END;
GO

/* The lever: arbor to fork. Its own frame is x across, y along from P. */
CREATE OR ALTER FUNCTION esc.fn_Lever ()
RETURNS geometry
AS
BEGIN
    DECLARE @Px float, @Py float, @pts varchar(max);
    SELECT @Px = Px, @Py = Py FROM esc.fn_Places();

    -- the jewel only dips about its own radius into the slot, so the horns stop at 9.95
    SELECT @pts = STRING_AGG(CAST(CONCAT(dbo.fmt(@Px + x), ' ', dbo.fmt(@Py + y)) AS varchar(max)), ', ')
                  WITHIN GROUP (ORDER BY Seq)
    FROM (VALUES (1, -0.45, 0.0), (2, -0.35, 8.0), (3, -1.0, 8.6), (4, -1.0, 9.6), (5, -0.75, 9.95),
                 (6, -0.4, 9.95), (7, -0.4, 9.25), (8, 0.4, 9.25), (9, 0.4, 9.95), (10, 0.75, 9.95),
                 (11, 1.0, 9.6), (12, 1.0, 8.6), (13, 0.35, 8.0), (14, 0.45, 0.0), (15, -0.45, 0.0)) AS v (Seq, x, y);

    RETURN geometry::STGeomFromText(CONCAT('POLYGON((', @pts, '))'), 0);
END;
GO

/* Pallet body: a bar from stone to stone through the arbor, plus the boss */
CREATE OR ALTER FUNCTION esc.fn_PalletBody ()
RETURNS geometry
AS
BEGIN
    DECLARE @R float, @w float, @e float, @x float, @Px float, @Py float;
    SELECT @R = R, @w = StoneW, @e = EntryLock, @x = ExitLock FROM esc.Spec;
    SELECT @Px = Px, @Py = Py FROM esc.fn_Places();

    DECLARE @bar geometry = geometry::STGeomFromText(CONCAT('LINESTRING(',
        dbo.fn_Polar(0, 0, @R + 2.4, @e + @w / 2), ', ', dbo.fmt(@Px), ' ', dbo.fmt(@Py), ', ',
        dbo.fn_Polar(0, 0, @R + 2.4, @x + @w / 2), ')'), 0).STBuffer(0.6);

    RETURN @bar.STUnion(dbo.fn_Circle(@Px, @Py, 1.3, 64)).STDifference(dbo.fn_Circle(@Px, @Py, 0.35, 24));
END;
GO

/* Banking pins: they meet the lever's edge 4.5 along it when the fork is at +/- BankDeg */
CREATE OR ALTER FUNCTION esc.fn_BankingPins ()
RETURNS geometry
AS
BEGIN
    DECLARE @bank float, @Px float, @Py float;
    SELECT @bank = BankDeg FROM esc.Spec;
    SELECT @Px = Px, @Py = Py FROM esc.fn_Places();

    DECLARE @hw float = 0.45 - 0.10 * 4.5 / 8.0, @pr float = 0.3;
    DECLARE @l geometry = dbo.fn_Rotate(geometry::Point(@Px - (@hw + @pr), @Py + 4.5, 0),  @bank, @Px, @Py);
    DECLARE @r geometry = dbo.fn_Rotate(geometry::Point(@Px + (@hw + @pr), @Py + 4.5, 0), -@bank, @Px, @Py);

    RETURN dbo.fn_Circle(@l.STX, @l.STY, @pr, 48).STUnion(dbo.fn_Circle(@r.STX, @r.STY, @pr, 48));
END;
GO

/* =====================================================================
   BALANCE
   ===================================================================== */
/* The impulse jewel, with the balance turned @Beta deg */
CREATE OR ALTER FUNCTION esc.fn_Jewel (@Beta float)
RETURNS geometry
AS
BEGIN
    DECLARE @RJ float, @jr float, @BalX float, @BalY float;
    SELECT @RJ = RJ, @jr = JewelR FROM esc.Spec;
    SELECT @BalX = BalX, @BalY = BalY FROM esc.fn_Places();
    RETURN dbo.fn_Circle(@BalX + @RJ * SIN(RADIANS(@Beta)), @BalY - @RJ * COS(RADIANS(@Beta)), @jr, 48);
END;
GO

/* Balance wheel at rest: rim, three arms, twelve timing screws, hub */
CREATE OR ALTER FUNCTION esc.fn_Balance ()
RETURNS geometry
AS
BEGIN
    DECLARE @BalX float, @BalY float, @arms geometry, @screws geometry;
    SELECT @BalX = BalX, @BalY = BalY FROM esc.fn_Places();

    SELECT @arms = geometry::UnionAggregate(geometry::STGeomFromText(CONCAT('LINESTRING(',
                       dbo.fmt(@BalX), ' ', dbo.fmt(@BalY), ', ', dbo.fn_Polar(@BalX, @BalY, 7.6, -90e0 + 120e0 * k.value), ')'), 0)
                       .STBuffer(0.35))
    FROM GENERATE_SERIES(0, 2) AS k;

    SELECT @screws = geometry::UnionAggregate(dbo.fn_Circle(
                         @BalX + 8.15 * COS(RADIANS(15e0 + 30e0 * k.value)),
                         @BalY + 8.15 * SIN(RADIANS(15e0 + 30e0 * k.value)), 0.32, 16))
    FROM GENERATE_SERIES(0, 11) AS k;

    RETURN dbo.fn_Circle(@BalX, @BalY, 8.0, 192).STDifference(dbo.fn_Circle(@BalX, @BalY, 7.2, 192))
              .STUnion(@arms).STUnion(@screws).STUnion(dbo.fn_Circle(@BalX, @BalY, 0.9, 32));
END;
GO

/* Hairspring: an Archimedean spiral. The inner end turns with the balance,
   the outer end is held by the stud, so the coils bunch and spread. */
CREATE OR ALTER FUNCTION esc.fn_Hairspring (@Beta float)
RETURNS geometry
AS
BEGIN
    DECLARE @BalX float, @BalY float, @pts varchar(max);
    SELECT @BalX = BalX, @BalY = BalY FROM esc.fn_Places();

    SELECT @pts = STRING_AGG(CAST(dbo.fn_Polar(@BalX, @BalY,
                      1.0 + 3.6 * s.f,
                      -90e0 + 360e0 * 9 * s.f + @Beta * (1 - s.f)) AS varchar(max)), ', ')
                  WITHIN GROUP (ORDER BY k.value)
    FROM GENERATE_SERIES(0, 899) AS k
    CROSS APPLY (SELECT k.value / 899e0 AS f) AS s;

    RETURN geometry::STGeomFromText(CONCAT('LINESTRING(', @pts, ')'), 0);
END;
GO
