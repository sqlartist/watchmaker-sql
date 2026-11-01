/* =====================================================================
   The Watchmaker  —  04_train.sql
   Episode 2: the going train.

       centre wheel  80 teeth  ->  third pinion  10 leaves   (m 0.13 mm)
       third wheel   75 teeth  ->  fourth pinion 10 leaves   (m 0.11 mm)
       fourth wheel  80 teeth  ->  escape pinion  8 leaves   (m 0.08 mm)

   The tooth counts are the only numbers. Nowhere does this script say 8,
   7.5, 10 or 60.

   train.usp_BuildMaps  builds real watch teeth (epicycloid wheel teeth,
                        radial-flanked pinion leaves), and for every wheel
                        angle in one tooth (60 steps) and pinion angle in one
                        leaf (120 steps) asks: do they overlap? Then, for each
                        wheel angle, it homes in on the least the pinion must
                        have turned to be clear of the tooth pushing it. That
                        "push edge" is the gearing law.
   train.usp_Run        turns the centre arbor at its real rate (0.1 deg a
                        second) and works out every other arbor through the
                        push edges: three CROSS APPLYs, no loop.
   train.vMesh          what the teeth did: ratio (mean, min, max), backlash,
                        and whether the mesh jammed.

   Units are millimetres. Each mesh is built twice: with proper cycloidal
   teeth, and with naive straight-sided ones, to see why the shape matters.
   ===================================================================== */
USE Watchmaker;
GO
IF SCHEMA_ID('train') IS NULL EXEC ('CREATE SCHEMA train');
GO

DROP TABLE IF EXISTS train.FramePart, train.Frame, train.Run, train.Edge, train.MeshMap,
                     train.PinionPose, train.WheelPose, train.Shape, train.Mesh, train.Arbor, train.Form;
GO

/* Tooth form (in modules) and the grids */
CREATE TABLE train.Form
(
    Id        tinyint PRIMARY KEY CHECK (Id = 1),
    WheelS    float NOT NULL,     -- wheel tooth thickness on the pitch circle
    WheelHa   float NOT NULL,     -- wheel addendum (the ogive)
    WheelHf   float NOT NULL,     -- wheel dedendum
    LeafS     float NOT NULL,     -- pinion leaf thickness on the pitch circle
    LeafHf    float NOT NULL,     -- pinion dedendum
    FlankPts  int   NOT NULL,     -- points per addendum flank (fewer and the facets show up as ratio wobble)
    TipStep   int   NOT NULL,     -- deg between points on a pinion leaf's round tip
    DisplayFlankPts int NOT NULL, -- the same, for drawing
    DisplayTipStep  int NOT NULL,
    PinionWedge float NOT NULL,   -- contact: only the pinion's leaves within this many deg of the wheel are kept
    NU        int   NOT NULL,     -- wheel grid, steps per tooth
    NV        int   NOT NULL,     -- pinion grid, steps per leaf
    Refine    int   NOT NULL,     -- each refinement splits the edge cell this many ways
    Rounds    int   NOT NULL,
    ZoneM     float NOT NULL      -- the wheel is only tested within pinion tip + ZoneM modules
);

CREATE TABLE train.Arbor
(
    Arbor     varchar(10) PRIMARY KEY,
    Spin      smallint NOT NULL,  -- +1 anticlockwise (seen from the dial side)
    X         float NULL,         -- worked out from the meshes
    Y         float NULL
);

CREATE TABLE train.Mesh
(
    MeshNo      int PRIMARY KEY,
    WheelArbor  varchar(10) NOT NULL REFERENCES train.Arbor(Arbor),
    PinionArbor varchar(10) NOT NULL REFERENCES train.Arbor(Arbor),
    Teeth       int   NOT NULL,
    Leaves      int   NOT NULL,
    Module      float NOT NULL,
    Direction   float NOT NULL    -- bearing from the wheel's arbor to the pinion's, deg
);

CREATE TABLE train.Shape                      -- parts built about the origin, at rest
(
    MeshNo    int NOT NULL,                   -- 0 = not part of a mesh
    Profile   varchar(10) NOT NULL,           -- cycloidal | straight | -
    Part      varchar(20) NOT NULL,
    Geom      geometry NOT NULL,
    CONSTRAINT PK_TrainShape PRIMARY KEY (MeshNo, Profile, Part)
);

CREATE TABLE train.WheelPose                  -- the wheel near its pinion, turned I/NU of a tooth
(
    MeshNo    int NOT NULL,
    Profile   varchar(10) NOT NULL,
    I         int NOT NULL,
    Geom      geometry NOT NULL,
    CONSTRAINT PK_WheelPose PRIMARY KEY (MeshNo, Profile, I)
);

CREATE TABLE train.PinionPose                 -- the pinion, turned J/NV of a leaf
(
    MeshNo    int NOT NULL,
    J         int NOT NULL,
    Geom      geometry NOT NULL,
    CONSTRAINT PK_PinionPose PRIMARY KEY (MeshNo, J)
);

CREATE TABLE train.MeshMap                    -- each mesh's configuration space
(
    MeshNo    int NOT NULL,
    Profile   varchar(10) NOT NULL,
    I         int NOT NULL,
    J         int NOT NULL,
    Clear     bit NOT NULL,
    CONSTRAINT PK_MeshMap PRIMARY KEY (MeshNo, Profile, I, J)
);

CREATE TABLE train.Edge                       -- the push edge: the gearing law
(
    MeshNo    int NOT NULL,
    Profile   varchar(10) NOT NULL,
    I         int NOT NULL,
    Runs      int NOT NULL,                   -- clear runs in this row: 1 = fine, 0 = jammed
    Lo        float NULL,                     -- pinion blocked here (deg, forwards) ...
    Hi        float NULL,                     -- ... and clear here
    EdgeDeg   float NULL,                     -- Hi within one leaf
    Progress  float NULL,                     -- unwrapped across the tooth
    CONSTRAINT PK_Edge PRIMARY KEY (MeshNo, Profile, I)
);

CREATE TABLE train.Run
(
    RunId     int IDENTITY PRIMARY KEY,
    Started   datetime2(3) NOT NULL DEFAULT SYSDATETIME(),
    Profile   varchar(10) NOT NULL,
    Seconds   float NOT NULL,                 -- simulated time
    Frames    int NOT NULL,
    ComputeSeconds float NULL
);

CREATE TABLE train.Frame
(
    RunId     int NOT NULL REFERENCES train.Run(RunId),
    FrameNo   int NOT NULL,
    Seconds   float NOT NULL,
    CentreDeg    float NOT NULL,                 -- arbor angles, deg, anticlockwise positive
    ThirdDeg     float NOT NULL,
    FourthDeg    float NOT NULL,
    EscapeDeg    float NOT NULL,
    CONSTRAINT PK_TrainFrame PRIMARY KEY (RunId, FrameNo)
);

CREATE TABLE train.FramePart
(
    RunId     int NOT NULL,
    FrameNo   int NOT NULL,
    Part      varchar(20) NOT NULL,
    Geom      geometry NOT NULL,
    CONSTRAINT PK_TrainFramePart PRIMARY KEY (RunId, FrameNo, Part),
    CONSTRAINT FK_TrainFramePart FOREIGN KEY (RunId, FrameNo) REFERENCES train.Frame(RunId, FrameNo)
);
GO

INSERT train.Form (Id, WheelS, WheelHa, WheelHf, LeafS, LeafHf, FlankPts, TipStep, DisplayFlankPts, DisplayTipStep,
                   PinionWedge, NU, NV, Refine, Rounds, ZoneM)
VALUES (1, 1.50, 1.40, 1.60, 1.20, 1.65, 40, 5, 4, 20, 78.0, 60, 120, 16, 2, 3.0);

INSERT train.Arbor (Arbor, Spin) VALUES ('centre', -1), ('third', 1), ('fourth', -1), ('escape', 1);

INSERT train.Mesh (MeshNo, WheelArbor, PinionArbor, Teeth, Leaves, Module, Direction)
VALUES (1, 'centre', 'third',  80, 10, 0.13,  -30.0),
       (2, 'third',  'fourth', 75, 10, 0.11,  -80.0),
       (3, 'fourth', 'escape', 80,  8, 0.08, -150.0);
GO

/* =====================================================================
   TEETH
   ===================================================================== */
/* An epicycloid: a circle of radius @rho rolling round the outside of a
   circle of radius @A, traced from (@A, 0) */
CREATE OR ALTER FUNCTION train.fn_Epi (@t float, @A float, @rho float)
RETURNS TABLE
AS
RETURN
    SELECT  (@A + @rho) * COS(@t) - @rho * COS(((@A + @rho) / @rho) * @t) AS X,
            (@A + @rho) * SIN(@t) - @rho * SIN(((@A + @rho) / @rho) * @t) AS Y;
GO

/* How far to roll: until the curve reaches the addendum circle (@Mode 'R')
   or the tooth's centre line (@Mode 'A'). Sixty halvings. */
CREATE OR ALTER FUNCTION train.fn_EpiEnd (@A float, @rho float, @Ra float, @g float, @Mode char(1))
RETURNS float
AS
BEGIN
    DECLARE @lo float = 0, @hi float = PI() * @rho / @A, @mid float, @x float, @y float, @i int = 0;
    DECLARE @k float = (@A + @rho) / @rho;
    WHILE @i < 60
    BEGIN
        SET @mid = (@lo + @hi) / 2;
        SET @x = (@A + @rho) * COS(@mid) - @rho * COS(@k * @mid);
        SET @y = (@A + @rho) * SIN(@mid) - @rho * SIN(@k * @mid);
        IF IIF(@Mode = 'R', SQRT(@x * @x + @y * @y) - @Ra, DEGREES(ATN2(@y, @x)) - @g) >= 0
            SET @hi = @mid;
        ELSE
            SET @lo = @mid;
        SET @i += 1;
    END;
    RETURN @hi;
END;
GO

/* A wheel of @z teeth, module @m, centred on the origin, tooth 0 on 0 deg.
   Cycloidal: each addendum flank is the epicycloid rolled by a circle half
   the pinion's pitch radius (@rho) - the partner of the pinion's radial
   flank. Straight: the naive version, a trapezoid. Dedendum flanks radial. */
CREATE OR ALTER FUNCTION train.fn_WheelOutline (@z int, @m float, @rho float, @Profile varchar(10), @N int)
RETURNS geometry
AS
BEGIN
    DECLARE @S float, @ha float, @hf float;
    SELECT @S = WheelS, @ha = WheelHa, @hf = WheelHf FROM train.Form;

    DECLARE @A float = @m * @z / 2;
    DECLARE @Ra float = @A + @ha * @m, @Rr float = @A - @hf * @m;
    DECLARE @g float = DEGREES(@S * @m / 2 / @A);          -- half a tooth on the pitch circle
    DECLARE @pitch float = 360e0 / @z;
    DECLARE @pointed bit = 0;
    DECLARE @flank TABLE (K int PRIMARY KEY, D float, R float);

    IF @Profile = 'straight'
    BEGIN
        DECLARE @tip float = @g * 0.45;
        INSERT @flank (K, D, R)
        SELECT k.value, -@g + (@g - @tip) * k.value / @N, @A + (@Ra - @A) * k.value / @N
        FROM GENERATE_SERIES(0, @N) AS k;
    END
    ELSE
    BEGIN
        DECLARE @tr float = train.fn_EpiEnd(@A, @rho, @Ra, @g, 'R'),
                @ta float = train.fn_EpiEnd(@A, @rho, @Ra, @g, 'A');
        DECLARE @tend float = IIF(@ta < @tr, @ta, @tr);
        SET @pointed = IIF(@ta <= @tr, 1, 0);
        INSERT @flank (K, D, R)
        SELECT k.value, -@g + DEGREES(ATN2(e.Y, e.X)), SQRT(e.X * e.X + e.Y * e.Y)
        FROM GENERATE_SERIES(0, @N) AS k
        CROSS APPLY train.fn_Epi(@tend * k.value / @N, @A, @rho) AS e;
    END;

    -- one tooth plus the root to the next, walked anticlockwise
    DECLARE @tooth TABLE (Seq int IDENTITY PRIMARY KEY, D float, R float);
    INSERT @tooth (D, R) VALUES (-@g, @Rr);                                       -- radial dedendum
    INSERT @tooth (D, R) SELECT D, R FROM @flank ORDER BY K;                       -- trailing flank up
    IF @pointed = 0
        INSERT @tooth (D, R)                                                       -- across the tip
        SELECT x.a0 + (x.a1 - x.a0) * k.value / 4, @Ra
        FROM GENERATE_SERIES(1, 3) AS k
        CROSS APPLY (SELECT f.D AS a0, -f.D AS a1 FROM @flank AS f WHERE f.K = @N) AS x
        ORDER BY k.value;
    INSERT @tooth (D, R) SELECT -D, R FROM @flank WHERE @pointed = 0 OR K < @N ORDER BY K DESC;   -- leading flank down
    INSERT @tooth (D, R) VALUES (@g, @Rr);
    INSERT @tooth (D, R)                                                           -- root arc
    SELECT @g + (@pitch - 2 * @g) * k.value / 4, @Rr FROM GENERATE_SERIES(1, 3) AS k ORDER BY k.value;

    DECLARE @pts varchar(max);
    SELECT @pts = STRING_AGG(CAST(dbo.fn_Polar(0, 0, t.R, k.value * @pitch + t.D) AS varchar(max)), ', ')
                  WITHIN GROUP (ORDER BY k.value, t.Seq)
    FROM GENERATE_SERIES(0, @z - 1) AS k
    CROSS JOIN @tooth AS t;

    RETURN geometry::STGeomFromText(CONCAT('POLYGON((', @pts, ', ', dbo.fn_Polar(0, 0, @Rr, -@g), '))'), 0);
END;
GO

/* A pinion of @n leaves: radial flanks (what makes cycloidal gearing work)
   and a round tip */
CREATE OR ALTER FUNCTION train.fn_LeafOutline (@n int, @m float, @TipStep int)
RETURNS geometry
AS
BEGIN
    DECLARE @S float, @hf float;
    SELECT @S = LeafS, @hf = LeafHf FROM train.Form;

    DECLARE @rp float = @m * @n / 2;
    DECLARE @rr float = @rp - @hf * @m;
    DECLARE @g float = DEGREES(@S * @m / 2 / @rp);
    DECLARE @cx float = @rp * COS(RADIANS(@g)), @half float = @rp * SIN(RADIANS(@g));
    DECLARE @pitch float = 360e0 / @n;

    DECLARE @leaf TABLE (Seq int IDENTITY PRIMARY KEY, D float, R float);
    INSERT @leaf (D, R) VALUES (-@g, @rr), (-@g, @rp);
    INSERT @leaf (D, R)
    SELECT DEGREES(ATN2(p.Y, p.X)), SQRT(p.X * p.X + p.Y * p.Y)
    FROM GENERATE_SERIES(-90 + @TipStep, 90 - @TipStep, @TipStep) AS a
    CROSS APPLY (SELECT @cx + @half * COS(RADIANS(1e0 * a.value)) AS X, @half * SIN(RADIANS(1e0 * a.value)) AS Y) AS p
    ORDER BY a.value;
    INSERT @leaf (D, R) VALUES (@g, @rp), (@g, @rr);
    INSERT @leaf (D, R)
    SELECT @g + (@pitch - 2 * @g) * k.value / 4, @rr FROM GENERATE_SERIES(1, 3) AS k ORDER BY k.value;

    DECLARE @pts varchar(max);
    SELECT @pts = STRING_AGG(CAST(dbo.fn_Polar(0, 0, l.R, k.value * @pitch + l.D) AS varchar(max)), ', ')
                  WITHIN GROUP (ORDER BY k.value, l.Seq)
    FROM GENERATE_SERIES(0, @n - 1) AS k
    CROSS JOIN @leaf AS l;

    RETURN geometry::STGeomFromText(CONCAT('POLYGON((', @pts, ', ', dbo.fn_Polar(0, 0, @rr, -@g), '))'), 0);
END;
GO

/* For drawing: the wheel with four crossings, a hub and an arbor hole */
CREATE OR ALTER FUNCTION train.fn_WheelDisplay (@z int, @m float, @rho float, @Profile varchar(10))
RETURNS geometry
AS
BEGIN
    DECLARE @hf float, @pts int;
    SELECT @hf = WheelHf, @pts = DisplayFlankPts FROM train.Form;
    DECLARE @rim float = @m * @z / 2 - @hf * @m - 0.35, @arms geometry;

    SELECT @arms = geometry::UnionAggregate(geometry::STGeomFromText(CONCAT('LINESTRING(0 0, ',
                       dbo.fn_Polar(0, 0, @rim + 0.1, 45e0 + 90e0 * k.value), ')'), 0).STBuffer(0.17))
    FROM GENERATE_SERIES(0, 3) AS k;

    RETURN train.fn_WheelOutline(@z, @m, @rho, @Profile, @pts)
             .STDifference(dbo.fn_Circle(0, 0, @rim, 180).STDifference(dbo.fn_Circle(0, 0, 0.55, 48)).STDifference(@arms))
             .STDifference(dbo.fn_Circle(0, 0, 0.12, 16));
END;
GO

/* =====================================================================
   THE MAPS AND THE PUSH EDGES
   ===================================================================== */
CREATE OR ALTER PROCEDURE train.usp_BuildMaps
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 datetime2 = SYSDATETIME(), @msg nvarchar(300);
    DECLARE @NU int, @NV int, @Refine int, @Rounds int, @ZoneM float, @Pts int, @Tip int, @DTip int, @Wedge float;
    SELECT @NU = NU, @NV = NV, @Refine = Refine, @Rounds = Rounds, @ZoneM = ZoneM,
           @Pts = FlankPts, @Tip = TipStep, @DTip = DisplayTipStep, @Wedge = PinionWedge
    FROM train.Form;

    DELETE train.FramePart; DELETE train.Frame; DELETE train.Run;
    TRUNCATE TABLE train.MeshMap;
    DELETE train.Edge; DELETE train.WheelPose; DELETE train.PinionPose; DELETE train.Shape;

    /* ---- where the arbors go: centre distance = m (z + n) / 2 ---- */
    WITH pos AS (
        SELECT CAST('centre' AS varchar(10)) AS Arbor, 0e0 AS X, 0e0 AS Y
        UNION ALL
        SELECT m.PinionArbor,
               p.X + m.Module * (m.Teeth + m.Leaves) / 2 * COS(RADIANS(m.Direction)),
               p.Y + m.Module * (m.Teeth + m.Leaves) / 2 * SIN(RADIANS(m.Direction))
        FROM pos AS p
        JOIN train.Mesh AS m ON m.WheelArbor = p.Arbor
    )
    UPDATE a SET X = pos.X, Y = pos.Y
    FROM train.Arbor AS a
    JOIN pos ON pos.Arbor = a.Arbor;

    /* ---- the parts ---- */
    INSERT train.Shape (MeshNo, Profile, Part, Geom)
    SELECT m.MeshNo, p.Profile, 'Wheel', train.fn_WheelOutline(m.Teeth, m.Module, m.Module * m.Leaves / 4, p.Profile, @Pts)
    FROM train.Mesh AS m
    CROSS JOIN (VALUES ('cycloidal'), ('straight')) AS p (Profile)
    UNION ALL       -- for contact: only the leaves facing the wheel, for any turn of 0..1 leaf
    SELECT m.MeshNo, '-', 'Pinion', train.fn_LeafOutline(m.Leaves, m.Module, @Tip).STIntersection(
               geometry::STGeomFromText(CONCAT('POLYGON((0 0, ',
                   dbo.fn_Polar(0, 0, m.Module * m.Leaves, w.B0 - @Wedge), ', ',
                   dbo.fn_Polar(0, 0, m.Module * m.Leaves, w.B0), ', ',
                   dbo.fn_Polar(0, 0, m.Module * m.Leaves, w.B0 + @Wedge), ', 0 0))'), 0))
    FROM train.Mesh AS m
    JOIN train.Arbor AS pa ON pa.Arbor = m.PinionArbor
    CROSS APPLY (SELECT m.Direction + 180e0 - pa.Spin * 180e0 / m.Leaves AS B0) AS w
    UNION ALL
    SELECT m.MeshNo, '-', 'PinionDisplay', train.fn_LeafOutline(m.Leaves, m.Module, @DTip)
    FROM train.Mesh AS m
    UNION ALL
    SELECT m.MeshNo, '-', 'Zone', dbo.fn_Circle(a.X, a.Y, m.Module * m.Leaves / 2 + @ZoneM * m.Module, 64)
    FROM train.Mesh AS m
    JOIN train.Arbor AS a ON a.Arbor = m.PinionArbor
    UNION ALL       -- the dial, for the hands: minute track at the centre, small seconds at 6 o'clock
    SELECT 0, '-', t.Part,
           dbo.fn_Circle(0, t.Y, t.R, 180).STDifference(dbo.fn_Circle(0, t.Y, t.R - t.W, 180))
             .STUnion(geometry::STGeomFromText(CONCAT('MULTILINESTRING(', t.Ticks, ')'), 0))
    FROM (
        SELECT d.Part, d.Y, d.R, d.W,
               STRING_AGG(CAST(CONCAT('(',
                   dbo.fn_Polar(0, d.Y, d.R - d.W, 6e0 * k.value), ', ',
                   dbo.fn_Polar(0, d.Y, d.R - d.W - IIF(k.value % 5 = 0, 0.12, 0.05) * d.R, 6e0 * k.value), ')')
                   AS varchar(max)), ', ') AS Ticks
        FROM (VALUES ('Dial', 0e0, 9.9, 0.1), ('SubDial', -4.6e0, 2.75, 0.06)) AS d (Part, Y, R, W)
        CROSS JOIN GENERATE_SERIES(0, 59) AS k
        GROUP BY d.Part, d.Y, d.R, d.W
    ) AS t;

    /* ---- every pose. The wheel is first cut down to the wedge that can
            reach the pinion (a few teeth, not eighty), then turned and put
            in place, then trimmed to the zone round the pinion. ---- */
    INSERT train.WheelPose (MeshNo, Profile, I, Geom)
    SELECT m.MeshNo, s.Profile, i.value,
           dbo.fn_Place(s.Geom.STIntersection(w.Wedge), wa.Spin * (360e0 / m.Teeth) * i.value / @NU, wa.X, wa.Y, 1)
              .STIntersection(z.Geom)
    FROM train.Mesh AS m
    JOIN train.Shape AS s ON s.MeshNo = m.MeshNo AND s.Part = 'Wheel'
    JOIN train.Shape AS z ON z.MeshNo = m.MeshNo AND z.Part = 'Zone'
    JOIN train.Arbor AS wa ON wa.Arbor = m.WheelArbor
    CROSS APPLY (   -- bearing of the pinion, before the wheel turns: +/- 25 deg
        SELECT geometry::STGeomFromText(CONCAT('POLYGON((0 0, ',
                   dbo.fn_Polar(0, 0, m.Module * m.Teeth, m.Direction - wa.Spin * 180e0 / m.Teeth - 25), ', ',
                   dbo.fn_Polar(0, 0, m.Module * m.Teeth, m.Direction - wa.Spin * 180e0 / m.Teeth), ', ',
                   dbo.fn_Polar(0, 0, m.Module * m.Teeth, m.Direction - wa.Spin * 180e0 / m.Teeth + 25), ', 0 0))'), 0) AS Wedge
    ) AS w
    CROSS JOIN GENERATE_SERIES(0, @NU - 1) AS i;

    INSERT train.PinionPose (MeshNo, J, Geom)
    SELECT m.MeshNo, j.value, dbo.fn_Place(s.Geom, pa.Spin * (360e0 / m.Leaves) * j.value / @NV, pa.X, pa.Y, 1)
    FROM train.Mesh AS m
    JOIN train.Shape AS s ON s.MeshNo = m.MeshNo AND s.Part = 'Pinion'
    JOIN train.Arbor AS pa ON pa.Arbor = m.PinionArbor
    CROSS JOIN GENERATE_SERIES(0, @NV - 1) AS j;

    SET @msg = CONCAT('poses built  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    /* ---- the physics, asked once: do they overlap? ---- */
    INSERT train.MeshMap (MeshNo, Profile, I, J, Clear)
    SELECT w.MeshNo, w.Profile, w.I, p.J, IIF(w.Geom.STIntersects(p.Geom) = 1, 0, 1)
    FROM train.WheelPose AS w
    JOIN train.PinionPose AS p ON p.MeshNo = w.MeshNo;

    SET @msg = CONCAT('train.MeshMap: ', @@ROWCOUNT, ' poses  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    /* ---- the push edge: where each row's clear run starts. Exactly one run
            per row, or the mesh jams. ---- */
    WITH starts AS (
        SELECT mm.MeshNo, mm.Profile, mm.I, mm.J
        FROM train.MeshMap AS mm
        JOIN train.MeshMap AS prev
          ON prev.MeshNo = mm.MeshNo AND prev.Profile = mm.Profile AND prev.I = mm.I
         AND prev.J = (mm.J + @NV - 1) % @NV
        WHERE mm.Clear = 1 AND prev.Clear = 0
    ), rows_ AS (
        SELECT w.MeshNo, w.Profile, w.I FROM train.WheelPose AS w
    )
    INSERT train.Edge (MeshNo, Profile, I, Runs, Lo, Hi)
    SELECT r.MeshNo, r.Profile, r.I, COUNT(s.J),
           IIF(COUNT(s.J) = 1, (MIN(s.J) - 1) * (360e0 / m.Leaves) / @NV, NULL),
           IIF(COUNT(s.J) = 1, MIN(s.J) * (360e0 / m.Leaves) / @NV, NULL)
    FROM rows_ AS r
    JOIN train.Mesh AS m ON m.MeshNo = r.MeshNo
    LEFT JOIN starts AS s ON s.MeshNo = r.MeshNo AND s.Profile = r.Profile AND s.I = r.I
    GROUP BY r.MeshNo, r.Profile, r.I, m.Leaves;

    /* ---- home in: split the edge cell, find the first clear split, repeat ---- */
    DECLARE @round int = 0;
    WHILE @round < @Rounds
    BEGIN
        WITH cand AS (
            SELECT e.MeshNo, e.Profile, e.I, k.value AS K,
                   (e.Hi - e.Lo) / @Refine AS Step,
                   e.Lo + k.value * ((e.Hi - e.Lo) / @Refine) AS V
            FROM train.Edge AS e
            CROSS JOIN GENERATE_SERIES(1, @Refine) AS k
            WHERE e.Runs = 1
        ), tested AS (
            SELECT c.*, IIF(w.Geom.STIntersects(dbo.fn_Place(ps.Geom, pa.Spin * c.V, pa.X, pa.Y, 1)) = 1, 0, 1) AS Clear
            FROM cand AS c
            JOIN train.WheelPose AS w ON w.MeshNo = c.MeshNo AND w.Profile = c.Profile AND w.I = c.I
            JOIN train.Mesh AS m ON m.MeshNo = c.MeshNo
            JOIN train.Shape AS ps ON ps.MeshNo = c.MeshNo AND ps.Part = 'Pinion'
            JOIN train.Arbor AS pa ON pa.Arbor = m.PinionArbor
        ), first_clear AS (
            SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.MeshNo, t.Profile, t.I ORDER BY t.K) AS rn
            FROM tested AS t
            WHERE t.Clear = 1
        )
        UPDATE e SET Lo = f.V - f.Step, Hi = f.V
        FROM train.Edge AS e
        JOIN first_clear AS f ON f.MeshNo = e.MeshNo AND f.Profile = e.Profile AND f.I = e.I AND f.rn = 1;

        SET @round += 1;
        SET @msg = CONCAT('refinement ', @round, ' done  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
        RAISERROR(@msg, 0, 1) WITH NOWAIT;
    END;

    /* ---- within one leaf, then unwrapped across the tooth ---- */
    UPDATE e SET EdgeDeg = e.Hi - (360e0 / m.Leaves) * FLOOR(e.Hi / (360e0 / m.Leaves))
    FROM train.Edge AS e
    JOIN train.Mesh AS m ON m.MeshNo = e.MeshNo
    WHERE e.Runs = 1;

    WITH lagged AS (
        SELECT e.MeshNo, e.Profile, e.I, e.EdgeDeg, 360e0 / m.Leaves AS Pv,
               FIRST_VALUE(e.EdgeDeg) OVER (PARTITION BY e.MeshNo, e.Profile ORDER BY e.I) AS E0,
               LAG(e.EdgeDeg) OVER (PARTITION BY e.MeshNo, e.Profile ORDER BY e.I) AS Prev
        FROM train.Edge AS e
        JOIN train.Mesh AS m ON m.MeshNo = e.MeshNo
        WHERE NOT EXISTS (SELECT 1 FROM train.Edge AS j
                          WHERE j.MeshNo = e.MeshNo AND j.Profile = e.Profile AND j.Runs <> 1)
    ), d AS (          -- each step's change, taken the short way round a leaf
        SELECT l.MeshNo, l.Profile, l.I, l.E0,
               IIF(l.Prev IS NULL, 0e0, x.Step - l.Pv * FLOOR(x.Step / l.Pv) - l.Pv / 2) AS Delta
        FROM lagged AS l
        CROSS APPLY (SELECT l.EdgeDeg - l.Prev + l.Pv / 2 AS Step) AS x
    ), u AS (
        SELECT MeshNo, Profile, I,
               E0 + SUM(Delta) OVER (PARTITION BY MeshNo, Profile ORDER BY I ROWS UNBOUNDED PRECEDING) AS Progress
        FROM d
    )
    UPDATE e SET Progress = u.Progress
    FROM train.Edge AS e
    JOIN u ON u.MeshNo = e.MeshNo AND u.Profile = e.Profile AND u.I = e.I;

    SET @msg = CONCAT('push edges done  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;
END;
GO

/* =====================================================================
   TRANSMIT: how far the pinion has turned (deg, forwards) when the wheel
   has turned @U deg forwards - read off the push edge, linearly between
   steps, one leaf further on for every tooth
   ===================================================================== */
CREATE OR ALTER FUNCTION train.fn_Transmit (@MeshNo int, @Profile varchar(10), @U float)
RETURNS TABLE
AS
RETURN
    WITH m AS (
        SELECT 360e0 / ms.Teeth AS Pu, 360e0 / ms.Leaves AS Pv, f.NU
        FROM train.Mesh AS ms CROSS JOIN train.Form AS f
        WHERE ms.MeshNo = @MeshNo
    ), k AS (
        SELECT m.*, FLOOR(@U / m.Pu) AS Teeth FROM m
    ), x AS (
        SELECT k.*, (@U - k.Teeth * k.Pu) / (k.Pu / k.NU) AS Xs FROM k
    ), i AS (
        SELECT x.*, CAST(IIF(FLOOR(x.Xs) > x.NU - 1, x.NU - 1, FLOOR(x.Xs)) AS int) AS I FROM x
    )
    SELECT e0.Progress + (i.Xs - i.I) * (COALESCE(e1.Progress, ez.Progress + i.Pv) - e0.Progress) + i.Teeth * i.Pv AS V
    FROM i
    JOIN train.Edge AS e0 ON e0.MeshNo = @MeshNo AND e0.Profile = @Profile AND e0.I = i.I
    JOIN train.Edge AS ez ON ez.MeshNo = @MeshNo AND ez.Profile = @Profile AND ez.I = 0
    LEFT JOIN train.Edge AS e1 ON e1.MeshNo = @MeshNo AND e1.Profile = @Profile AND e1.I = i.I + 1;
GO

/* =====================================================================
   RUN: the centre arbor turns at its real rate, 0.1 deg a second; every
   other arbor is read through the meshes. Set-based - no loop.
   ===================================================================== */
CREATE OR ALTER PROCEDURE train.usp_Run
    @Profile varchar(10) = 'cycloidal',
    @Seconds float = 60,
    @Frames  int   = 361,
    @Parts   bit   = 1,
    @RunId   int   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 datetime2 = SYSDATETIME(), @msg nvarchar(300);

    IF EXISTS (SELECT 1 FROM train.Edge WHERE Profile = @Profile AND Runs <> 1)
    BEGIN
        SET @msg = CONCAT('The ', @Profile, ' train jams - see train.vMesh');
        RAISERROR(@msg, 16, 1);
        RETURN;
    END;

    INSERT train.Run (Profile, Seconds, Frames) VALUES (@Profile, @Seconds, @Frames);
    SET @RunId = SCOPE_IDENTITY();

    DECLARE @sc smallint = (SELECT Spin FROM train.Arbor WHERE Arbor = 'centre'),
            @st smallint = (SELECT Spin FROM train.Arbor WHERE Arbor = 'third'),
            @sf smallint = (SELECT Spin FROM train.Arbor WHERE Arbor = 'fourth'),
            @se smallint = (SELECT Spin FROM train.Arbor WHERE Arbor = 'escape');

    INSERT train.Frame (RunId, FrameNo, Seconds, CentreDeg, ThirdDeg, FourthDeg, EscapeDeg)
    SELECT @RunId, f.value, t.S, @sc * c.U, @st * m1.V, @sf * m2.V, @se * m3.V
    FROM GENERATE_SERIES(0, @Frames - 1) AS f
    CROSS APPLY (SELECT @Seconds * f.value / (@Frames - 1) AS S) AS t
    CROSS APPLY (SELECT 0.1 * t.S AS U) AS c                         -- centre: one turn an hour
    CROSS APPLY train.fn_Transmit(1, @Profile, c.U)  AS m1           -- third
    CROSS APPLY train.fn_Transmit(2, @Profile, m1.V) AS m2           -- fourth
    CROSS APPLY train.fn_Transmit(3, @Profile, m2.V) AS m3;          -- escape

    SET @msg = CONCAT('run ', @RunId, ': ', @Frames, ' frames  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    IF @Parts = 1
    BEGIN
        /* the parts for drawing, each built once ... */
        DECLARE @shapes TABLE (Part varchar(20) PRIMARY KEY, Arbor varchar(10), Scale float, Geom geometry);
        INSERT @shapes (Part, Arbor, Scale, Geom)
        SELECT CONCAT(UPPER(LEFT(m.WheelArbor, 1)), SUBSTRING(m.WheelArbor, 2, 20), 'Wheel'), m.WheelArbor, 1,
               train.fn_WheelDisplay(m.Teeth, m.Module, m.Module * m.Leaves / 4, @Profile)
        FROM train.Mesh AS m
        UNION ALL
        SELECT CONCAT(UPPER(LEFT(m.PinionArbor, 1)), SUBSTRING(m.PinionArbor, 2, 20), 'Pinion'), m.PinionArbor, 1, s.Geom
        FROM train.Mesh AS m
        JOIN train.Shape AS s ON s.MeshNo = m.MeshNo AND s.Part = 'PinionDisplay'
        UNION ALL
        SELECT 'EscapeWheel', 'escape', 0.22, esc.fn_WheelDisplay();                     -- episode 1's wheel, 2.2 mm

        /* ... and the hands: pressed on so they read 12 at the start */
        DECLARE @minute geometry = geometry::STGeomFromText(
                    'POLYGON((-0.2 -1.4, 0.2 -1.4, 0.13 8.4, 0 9.2, -0.13 8.4, -0.2 -1.4))', 0),
                @second geometry = geometry::STGeomFromText(
                    'POLYGON((-0.06 -0.6, 0.06 -0.6, 0.04 2.2, 0 2.4, -0.04 2.2, -0.06 -0.6))', 0);
        DECLARE @c0 float, @f0 float;
        SELECT @c0 = CentreDeg, @f0 = FourthDeg FROM train.Frame WHERE RunId = @RunId AND FrameNo = 0;

        INSERT train.FramePart (RunId, FrameNo, Part, Geom)
        SELECT f.RunId, f.FrameNo, p.Part,
               dbo.fn_Place(p.Geom, CASE p.Arbor WHEN 'centre' THEN f.CentreDeg WHEN 'third' THEN f.ThirdDeg
                                                 WHEN 'fourth' THEN f.FourthDeg ELSE f.EscapeDeg END,
                            a.X, a.Y, p.Scale)
        FROM train.Frame AS f
        CROSS JOIN @shapes AS p
        JOIN train.Arbor AS a ON a.Arbor = p.Arbor
        WHERE f.RunId = @RunId
        UNION ALL
        SELECT f.RunId, f.FrameNo, h.Part, h.Geom
        FROM train.Frame AS f
        CROSS APPLY (VALUES
            ('MinuteHand', dbo.fn_Place(@minute, f.CentreDeg - @c0, 0, 0, 1)),        -- dial panel: centre
            ('SecondsHand', dbo.fn_Place(@second, f.FourthDeg - @f0, 0, -4.6, 1))     -- small seconds at 6
        ) AS h (Part, Geom)
        WHERE f.RunId = @RunId;

        SET @msg = CONCAT('run ', @RunId, ': shapes stored  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
        RAISERROR(@msg, 0, 1) WITH NOWAIT;
    END;

    UPDATE train.Run SET ComputeSeconds = DATEDIFF(millisecond, @t0, SYSDATETIME()) / 1000e0 WHERE RunId = @RunId;
END;
GO

/* =====================================================================
   WHAT THE TEETH DID
   ===================================================================== */
/* The velocity ratio at each step across one tooth: pinion deg per wheel deg */
CREATE OR ALTER VIEW train.vRatio
AS
SELECT  e.MeshNo, e.Profile, e.I,
        e.I * (360e0 / m.Teeth) / f.NU AS WheelDeg,
        (COALESCE(LEAD(e.Progress) OVER (PARTITION BY e.MeshNo, e.Profile ORDER BY e.I),
                  FIRST_VALUE(e.Progress) OVER (PARTITION BY e.MeshNo, e.Profile ORDER BY e.I) + 360e0 / m.Leaves)
         - e.Progress) / ((360e0 / m.Teeth) / f.NU) AS Ratio
FROM train.Edge AS e
JOIN train.Mesh AS m ON m.MeshNo = e.MeshNo
CROSS JOIN train.Form AS f
WHERE e.Progress IS NOT NULL;
GO

CREATE OR ALTER VIEW train.vMesh
AS
SELECT  m.MeshNo, m.WheelArbor + ' wheel -> ' + m.PinionArbor + ' pinion' AS Mesh,
        CONCAT(m.Teeth, '/', m.Leaves) AS Teeth, p.Profile,
        IIF(j.Jammed > 0, 'JAMS', 'turns')                                AS Verdict,
        CAST(r.MeanRatio AS decimal(8, 4))                                AS MeanRatio,
        CAST(r.MinRatio AS decimal(8, 3))                                 AS MinRatio,
        CAST(r.MaxRatio AS decimal(8, 3))                                 AS MaxRatio,
        CAST(b.MinBacklash AS decimal(6, 2))                              AS MinBacklashDeg,   -- pinion deg
        CAST(b.MaxBacklash AS decimal(6, 2))                              AS MaxBacklashDeg
FROM train.Mesh AS m
CROSS JOIN (VALUES ('cycloidal'), ('straight')) AS p (Profile)
OUTER APPLY (SELECT COUNT(*) AS Jammed FROM train.Edge AS e
             WHERE e.MeshNo = m.MeshNo AND e.Profile = p.Profile AND e.Runs <> 1) AS j
OUTER APPLY (SELECT AVG(Ratio) AS MeanRatio, MIN(Ratio) AS MinRatio, MAX(Ratio) AS MaxRatio
             FROM train.vRatio AS v WHERE v.MeshNo = m.MeshNo AND v.Profile = p.Profile) AS r
OUTER APPLY (SELECT MIN(w) AS MinBacklash, MAX(w) AS MaxBacklash
             FROM (SELECT SUM(CAST(mm.Clear AS int)) * (360e0 / m.Leaves) / f.NV AS w
                   FROM train.MeshMap AS mm CROSS JOIN train.Form AS f
                   WHERE mm.MeshNo = m.MeshNo AND mm.Profile = p.Profile
                   GROUP BY mm.I, f.NV) AS rows_) AS b;
GO
