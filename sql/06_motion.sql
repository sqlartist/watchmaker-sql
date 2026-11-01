/* =====================================================================
   The Watchmaker  —  06_motion.sql
   Episode 4: the motion works, minute hand to hour hand.

       cannon pinion 12 leaves (centre arbor, minute hand) -> minute wheel 36   (m 0.125)
       minute pinion 10 leaves (minute wheel's arbor)      -> hour wheel   40   (m 0.12, hour hand)

   The tooth counts are the only numbers; nothing says 3, 4 or 12. Here
   pinions drive wheels, so every gear gets the full cycloidal form: its
   addendum is the epicycloid rolled by a circle half its partner's pitch
   radius, its dedendum radial.

   And the hour wheel rides on the cannon pinion: both meshes must be the
   same length, or it won't go back round to the centre. The modules are
   chosen so they are - 0.125 x 48 / 2 = 0.12 x 50 / 2 = 3 mm - and
   motion.vCoaxial checks where the hour wheel actually lands.

   Same machinery as episode 2: a clear/blocked map per mesh, the push
   edge homed in on, the hands read through it with CROSS APPLY.
   ===================================================================== */
USE Watchmaker;
GO
IF SCHEMA_ID('motion') IS NULL EXEC ('CREATE SCHEMA motion');
GO

DROP TABLE IF EXISTS motion.FramePart, motion.Frame, motion.Run, motion.Edge, motion.MeshMap,
                     motion.DrivenPose, motion.DriverPose, motion.Shape, motion.Mesh, motion.Arbor, motion.Form;
GO

CREATE TABLE motion.Form
(
    Id        tinyint PRIMARY KEY CHECK (Id = 1),
    ToothS    float NOT NULL,     -- thickness on the pitch circle, modules
    ToothHa   float NOT NULL,     -- addendum
    ToothHf   float NOT NULL,     -- dedendum
    FlankPts  int   NOT NULL,
    DisplayFlankPts int NOT NULL,
    ZoneM     float NOT NULL,     -- the gears can only touch within this many modules of the pitch point
    NU        int   NOT NULL,     -- driver grid, steps per tooth
    NV        int   NOT NULL,     -- driven grid, steps per tooth
    Refine    int   NOT NULL,
    Rounds    int   NOT NULL
);

CREATE TABLE motion.Arbor
(
    Arbor     varchar(10) PRIMARY KEY,
    Spin      smallint NOT NULL,  -- +1 anticlockwise, seen from the dial
    X         float NULL,
    Y         float NULL
);

CREATE TABLE motion.Mesh
(
    MeshNo      int PRIMARY KEY,
    DriverArbor varchar(10) NOT NULL REFERENCES motion.Arbor(Arbor),
    DriverTeeth int   NOT NULL,
    DrivenArbor varchar(10) NOT NULL REFERENCES motion.Arbor(Arbor),
    DrivenTeeth int   NOT NULL,
    Module      float NOT NULL,
    Direction   float NOT NULL    -- bearing from the driver's arbor to the driven's, deg
);

CREATE TABLE motion.Shape
(
    MeshNo    int NOT NULL,       -- 0 = the dial
    Part      varchar(20) NOT NULL,
    Geom      geometry NOT NULL,
    CONSTRAINT PK_MotionShape PRIMARY KEY (MeshNo, Part)
);

CREATE TABLE motion.DriverPose
(
    MeshNo    int NOT NULL,
    I         int NOT NULL,
    Geom      geometry NOT NULL,
    CONSTRAINT PK_DriverPose PRIMARY KEY (MeshNo, I)
);

CREATE TABLE motion.DrivenPose
(
    MeshNo    int NOT NULL,
    J         int NOT NULL,
    Geom      geometry NOT NULL,
    CONSTRAINT PK_DrivenPose PRIMARY KEY (MeshNo, J)
);

CREATE TABLE motion.MeshMap
(
    MeshNo    int NOT NULL,
    I         int NOT NULL,
    J         int NOT NULL,
    Clear     bit NOT NULL,
    CONSTRAINT PK_MotionMeshMap PRIMARY KEY (MeshNo, I, J)
);

CREATE TABLE motion.Edge
(
    MeshNo    int NOT NULL,
    I         int NOT NULL,
    Runs      int NOT NULL,
    Lo        float NULL,
    Hi        float NULL,
    EdgeDeg   float NULL,
    Progress  float NULL,
    CONSTRAINT PK_MotionEdge PRIMARY KEY (MeshNo, I)
);

CREATE TABLE motion.Run
(
    RunId     int IDENTITY PRIMARY KEY,
    Started   datetime2(3) NOT NULL DEFAULT SYSDATETIME(),
    Hours     float NOT NULL,
    Frames    int NOT NULL
);

CREATE TABLE motion.Frame
(
    RunId     int NOT NULL REFERENCES motion.Run(RunId),
    FrameNo   int NOT NULL,
    Hours     float NOT NULL,
    CentreDeg float NOT NULL,     -- cannon pinion and minute hand
    MinuteDeg float NOT NULL,     -- minute wheel and pinion
    HourDeg   float NOT NULL,     -- hour wheel and hour hand
    CONSTRAINT PK_MotionFrame PRIMARY KEY (RunId, FrameNo)
);

CREATE TABLE motion.FramePart
(
    RunId     int NOT NULL,
    FrameNo   int NOT NULL,
    Part      varchar(20) NOT NULL,
    Geom      geometry NOT NULL,
    CONSTRAINT PK_MotionFramePart PRIMARY KEY (RunId, FrameNo, Part),
    CONSTRAINT FK_MotionFramePart FOREIGN KEY (RunId, FrameNo) REFERENCES motion.Frame(RunId, FrameNo)
);
GO

INSERT motion.Form (Id, ToothS, ToothHa, ToothHf, FlankPts, DisplayFlankPts, ZoneM, NU, NV, Refine, Rounds)
VALUES (1, 1.40, 1.40, 1.65, 40, 6, 6.0, 60, 120, 16, 2);

INSERT motion.Arbor (Arbor, Spin) VALUES ('centre', -1), ('minute', 1), ('hour', -1);

INSERT motion.Mesh (MeshNo, DriverArbor, DriverTeeth, DrivenArbor, DrivenTeeth, Module, Direction)
VALUES (1, 'centre', 12, 'minute', 36, 0.125, -135.0),      -- cannon pinion -> minute wheel
       (2, 'minute', 10, 'hour',   40, 0.12,    45.0);      -- minute pinion -> hour wheel, back towards the centre
GO

/* =====================================================================
   TEETH
   ===================================================================== */
/* How far to roll the epicycloid: to the addendum circle ('R') or the
   tooth's centre line ('A'). Never more than a quarter turn of the base
   circle - past that, for a big rolling circle, the curve's angle wraps. */
CREATE OR ALTER FUNCTION motion.fn_EpiEnd (@A float, @rho float, @Ra float, @g float, @Mode char(1))
RETURNS float
AS
BEGIN
    DECLARE @lo float = 0, @hi float = IIF(PI() * @rho / @A < PI() / 2, PI() * @rho / @A, PI() / 2);
    DECLARE @mid float, @x float, @y float, @i int = 0, @k float = (@A + @rho) / @rho;
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

/* A gear of @z teeth, module @m, centred on the origin, tooth 0 on 0 deg:
   epicycloid addendum rolled by @rho, radial dedendum */
CREATE OR ALTER FUNCTION motion.fn_GearOutline (@z int, @m float, @rho float, @N int)
RETURNS geometry
AS
BEGIN
    DECLARE @S float, @ha float, @hf float;
    SELECT @S = ToothS, @ha = ToothHa, @hf = ToothHf FROM motion.Form;

    DECLARE @A float = @m * @z / 2;
    DECLARE @Ra float = @A + @ha * @m, @Rr float = @A - @hf * @m;
    DECLARE @g float = DEGREES(@S * @m / 2 / @A);
    DECLARE @pitch float = 360e0 / @z;
    DECLARE @tr float = motion.fn_EpiEnd(@A, @rho, @Ra, @g, 'R'),
            @ta float = motion.fn_EpiEnd(@A, @rho, @Ra, @g, 'A');
    DECLARE @tend float = IIF(@ta < @tr, @ta, @tr), @pointed bit = IIF(@ta <= @tr, 1, 0);

    DECLARE @flank TABLE (K int PRIMARY KEY, D float, R float);
    INSERT @flank (K, D, R)
    SELECT k.value, -@g + DEGREES(ATN2(e.Y, e.X)), SQRT(e.X * e.X + e.Y * e.Y)
    FROM GENERATE_SERIES(0, @N) AS k
    CROSS APPLY train.fn_Epi(@tend * k.value / @N, @A, @rho) AS e;

    DECLARE @tooth TABLE (Seq int IDENTITY PRIMARY KEY, D float, R float);
    INSERT @tooth (D, R) VALUES (-@g, @Rr);
    INSERT @tooth (D, R) SELECT D, R FROM @flank ORDER BY K;
    IF @pointed = 0
        INSERT @tooth (D, R)
        SELECT x.a0 + (x.a1 - x.a0) * k.value / 4, @Ra
        FROM GENERATE_SERIES(1, 3) AS k
        CROSS APPLY (SELECT f.D AS a0, -f.D AS a1 FROM @flank AS f WHERE f.K = @N) AS x
        ORDER BY k.value;
    INSERT @tooth (D, R) SELECT -D, R FROM @flank WHERE @pointed = 0 OR K < @N ORDER BY K DESC;
    INSERT @tooth (D, R) VALUES (@g, @Rr);
    INSERT @tooth (D, R)
    SELECT @g + (@pitch - 2 * @g) * k.value / 4, @Rr FROM GENERATE_SERIES(1, 3) AS k ORDER BY k.value;

    DECLARE @pts varchar(max);
    SELECT @pts = STRING_AGG(CAST(dbo.fn_Polar(0, 0, t.R, k.value * @pitch + t.D) AS varchar(max)), ', ')
                  WITHIN GROUP (ORDER BY k.value, t.Seq)
    FROM GENERATE_SERIES(0, @z - 1) AS k
    CROSS JOIN @tooth AS t;

    RETURN geometry::STGeomFromText(CONCAT('POLYGON((', @pts, ', ', dbo.fn_Polar(0, 0, @Rr, -@g), '))'), 0);
END;
GO

/* A fan from the origin, @Bearing +/- @Half deg: the part of a gear that can
   reach its partner. NULL (keep everything) if it's the whole gear. */
CREATE OR ALTER FUNCTION motion.fn_Wedge (@Bearing float, @Half float, @Radius float)
RETURNS geometry
AS
BEGIN
    IF @Half >= 180 RETURN NULL;
    DECLARE @n int = IIF(CEILING(2 * @Half / 30) > 2, CAST(CEILING(2 * @Half / 30) AS int), 2), @pts varchar(max);
    SELECT @pts = STRING_AGG(CAST(dbo.fn_Polar(0, 0, @Radius, @Bearing - @Half + 2 * @Half * k.value / @n) AS varchar(max)), ', ')
                  WITHIN GROUP (ORDER BY k.value)
    FROM GENERATE_SERIES(0, @n) AS k;
    RETURN geometry::STGeomFromText(CONCAT('POLYGON((0 0, ', @pts, ', 0 0))'), 0);
END;
GO

/* =====================================================================
   THE MAPS AND THE PUSH EDGES
   ===================================================================== */
CREATE OR ALTER PROCEDURE motion.usp_BuildMaps
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 datetime2 = SYSDATETIME(), @msg nvarchar(300);
    DECLARE @NU int, @NV int, @Refine int, @Rounds int, @ZoneM float, @Pts int, @DPts int, @ha float;
    SELECT @NU = NU, @NV = NV, @Refine = Refine, @Rounds = Rounds, @ZoneM = ZoneM,
           @Pts = FlankPts, @DPts = DisplayFlankPts, @ha = ToothHa
    FROM motion.Form;

    DELETE motion.FramePart; DELETE motion.Frame; DELETE motion.Run;
    TRUNCATE TABLE motion.MeshMap;
    DELETE motion.Edge; DELETE motion.DriverPose; DELETE motion.DrivenPose; DELETE motion.Shape;

    /* ---- where the arbors go: each mesh is m (z1 + z2) / 2 long ---- */
    UPDATE motion.Arbor SET X = NULL, Y = NULL;
    WITH pos AS (
        SELECT CAST('centre' AS varchar(10)) AS Arbor, 0e0 AS X, 0e0 AS Y, 0 AS Depth
        UNION ALL
        SELECT m.DrivenArbor,
               p.X + m.Module * (m.DriverTeeth + m.DrivenTeeth) / 2 * COS(RADIANS(m.Direction)),
               p.Y + m.Module * (m.DriverTeeth + m.DrivenTeeth) / 2 * SIN(RADIANS(m.Direction)),
               p.Depth + 1
        FROM pos AS p
        JOIN motion.Mesh AS m ON m.DriverArbor = p.Arbor
    )
    UPDATE a SET X = pos.X, Y = pos.Y
    FROM motion.Arbor AS a
    JOIN pos ON pos.Arbor = a.Arbor;

    /* ---- the gears: each cut down at rest to the teeth that can ever meet the other ---- */
    WITH g AS (
        SELECT m.*, m.Module * m.DriverTeeth / 2 AS Ad, m.Module * m.DrivenTeeth / 2 AS An,
               @ZoneM * m.Module AS Zr, da.Spin AS Sd, na.Spin AS Sn, da.X AS DX, da.Y AS DY
        FROM motion.Mesh AS m
        JOIN motion.Arbor AS da ON da.Arbor = m.DriverArbor
        JOIN motion.Arbor AS na ON na.Arbor = m.DrivenArbor
    ), w AS (
        SELECT g.*,
               motion.fn_Wedge(g.Direction - g.Sd * (360e0 / g.DriverTeeth) / 2,
                               DEGREES(ASIN(IIF(g.Zr / g.Ad > 1, 1e0, g.Zr / g.Ad))) + 360e0 / g.DriverTeeth + 5,
                               2 * (g.Ad + @ha * g.Module)) AS DriverWedge,
               motion.fn_Wedge(g.Direction + 180 - g.Sn * (360e0 / g.DrivenTeeth) / 2,
                               DEGREES(ASIN(IIF(g.Zr / g.An > 1, 1e0, g.Zr / g.An))) + 360e0 / g.DrivenTeeth + 5,
                               2 * (g.An + @ha * g.Module)) AS DrivenWedge
        FROM g
    ), parts AS (
        SELECT w.MeshNo,
               motion.fn_GearOutline(w.DriverTeeth, w.Module, w.An / 2, @Pts) AS Driver,   -- rolled by half the partner
               motion.fn_GearOutline(w.DrivenTeeth, w.Module, w.Ad / 2, @Pts) AS Driven,
               motion.fn_GearOutline(w.DriverTeeth, w.Module, w.An / 2, @DPts) AS DriverDisplay,
               motion.fn_GearOutline(w.DrivenTeeth, w.Module, w.Ad / 2, @DPts) AS DrivenDisplay,
               w.DriverWedge, w.DrivenWedge,
               dbo.fn_Circle(w.DX + w.Ad * COS(RADIANS(w.Direction)), w.DY + w.Ad * SIN(RADIANS(w.Direction)), w.Zr, 64) AS Zone
        FROM w
    )
    INSERT motion.Shape (MeshNo, Part, Geom)
    SELECT p.MeshNo, v.Part, v.Geom
    FROM parts AS p
    CROSS APPLY (VALUES
        ('Driver', IIF(p.DriverWedge IS NULL, p.Driver, p.Driver.STIntersection(p.DriverWedge))),
        ('Driven', IIF(p.DrivenWedge IS NULL, p.Driven, p.Driven.STIntersection(p.DrivenWedge))),
        ('DriverDisplay', p.DriverDisplay),
        ('DrivenDisplay', p.DrivenDisplay),
        ('Zone', p.Zone)
    ) AS v (Part, Geom);

    /* the dial: twelve hour marks, sixty minute ticks */
    INSERT motion.Shape (MeshNo, Part, Geom)
    SELECT 0, 'Dial',
           dbo.fn_Circle(0, 0, 9.9, 180).STDifference(dbo.fn_Circle(0, 0, 9.8, 180))
             .STUnion(geometry::STGeomFromText(CONCAT('MULTILINESTRING(', t.Ticks, ')'), 0))
             .STUnion(h.Marks)
    FROM (
        SELECT STRING_AGG(CAST(CONCAT('(', dbo.fn_Polar(0, 0, 9.8, 6e0 * k.value), ', ',
                                           dbo.fn_Polar(0, 0, 9.35, 6e0 * k.value), ')') AS varchar(max)), ', ') AS Ticks
        FROM GENERATE_SERIES(0, 59) AS k
    ) AS t
    CROSS APPLY (
        SELECT geometry::UnionAggregate(geometry::STGeomFromText(CONCAT('LINESTRING(',
                   dbo.fn_Polar(0, 0, 9.8, 30e0 * k.value), ', ', dbo.fn_Polar(0, 0, 8.4, 30e0 * k.value), ')'), 0)
                   .STBuffer(0.22)) AS Marks
        FROM GENERATE_SERIES(0, 11) AS k
    ) AS h;

    /* ---- every pose ---- */
    INSERT motion.DriverPose (MeshNo, I, Geom)
    SELECT m.MeshNo, i.value,
           dbo.fn_Place(s.Geom, a.Spin * (360e0 / m.DriverTeeth) * i.value / @NU, a.X, a.Y, 1).STIntersection(z.Geom)
    FROM motion.Mesh AS m
    JOIN motion.Shape AS s ON s.MeshNo = m.MeshNo AND s.Part = 'Driver'
    JOIN motion.Shape AS z ON z.MeshNo = m.MeshNo AND z.Part = 'Zone'
    JOIN motion.Arbor AS a ON a.Arbor = m.DriverArbor
    CROSS JOIN GENERATE_SERIES(0, @NU - 1) AS i;

    INSERT motion.DrivenPose (MeshNo, J, Geom)
    SELECT m.MeshNo, j.value, dbo.fn_Place(s.Geom, a.Spin * (360e0 / m.DrivenTeeth) * j.value / @NV, a.X, a.Y, 1)
    FROM motion.Mesh AS m
    JOIN motion.Shape AS s ON s.MeshNo = m.MeshNo AND s.Part = 'Driven'
    JOIN motion.Arbor AS a ON a.Arbor = m.DrivenArbor
    CROSS JOIN GENERATE_SERIES(0, @NV - 1) AS j;

    SET @msg = CONCAT('poses built  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    /* ---- the physics, asked once ---- */
    INSERT motion.MeshMap (MeshNo, I, J, Clear)
    SELECT d.MeshNo, d.I, n.J, IIF(d.Geom.STIntersects(n.Geom) = 1, 0, 1)
    FROM motion.DriverPose AS d
    JOIN motion.DrivenPose AS n ON n.MeshNo = d.MeshNo;

    SET @msg = CONCAT('motion.MeshMap: ', @@ROWCOUNT, ' poses  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    /* ---- the push edge: where each row's clear run starts ---- */
    WITH starts AS (
        SELECT mm.MeshNo, mm.I, mm.J
        FROM motion.MeshMap AS mm
        JOIN motion.MeshMap AS prev
          ON prev.MeshNo = mm.MeshNo AND prev.I = mm.I AND prev.J = (mm.J + @NV - 1) % @NV
        WHERE mm.Clear = 1 AND prev.Clear = 0
    )
    INSERT motion.Edge (MeshNo, I, Runs, Lo, Hi)
    SELECT d.MeshNo, d.I, COUNT(s.J),
           IIF(COUNT(s.J) = 1, (MIN(s.J) - 1) * (360e0 / m.DrivenTeeth) / @NV, NULL),
           IIF(COUNT(s.J) = 1, MIN(s.J) * (360e0 / m.DrivenTeeth) / @NV, NULL)
    FROM motion.DriverPose AS d
    JOIN motion.Mesh AS m ON m.MeshNo = d.MeshNo
    LEFT JOIN starts AS s ON s.MeshNo = d.MeshNo AND s.I = d.I
    GROUP BY d.MeshNo, d.I, m.DrivenTeeth;

    DECLARE @round int = 0;
    WHILE @round < @Rounds
    BEGIN
        WITH cand AS (
            SELECT e.MeshNo, e.I, k.value AS K,
                   (e.Hi - e.Lo) / @Refine AS Step,
                   e.Lo + k.value * ((e.Hi - e.Lo) / @Refine) AS V
            FROM motion.Edge AS e
            CROSS JOIN GENERATE_SERIES(1, @Refine) AS k
            WHERE e.Runs = 1
        ), tested AS (
            SELECT c.*, IIF(d.Geom.STIntersects(dbo.fn_Place(s.Geom, a.Spin * c.V, a.X, a.Y, 1)) = 1, 0, 1) AS Clear
            FROM cand AS c
            JOIN motion.DriverPose AS d ON d.MeshNo = c.MeshNo AND d.I = c.I
            JOIN motion.Mesh AS m ON m.MeshNo = c.MeshNo
            JOIN motion.Shape AS s ON s.MeshNo = c.MeshNo AND s.Part = 'Driven'
            JOIN motion.Arbor AS a ON a.Arbor = m.DrivenArbor
        ), first_clear AS (
            SELECT t.*, ROW_NUMBER() OVER (PARTITION BY t.MeshNo, t.I ORDER BY t.K) AS rn
            FROM tested AS t
            WHERE t.Clear = 1
        )
        UPDATE e SET Lo = f.V - f.Step, Hi = f.V
        FROM motion.Edge AS e
        JOIN first_clear AS f ON f.MeshNo = e.MeshNo AND f.I = e.I AND f.rn = 1;

        SET @round += 1;
        SET @msg = CONCAT('refinement ', @round, ' done  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
        RAISERROR(@msg, 0, 1) WITH NOWAIT;
    END;

    UPDATE e SET EdgeDeg = e.Hi - (360e0 / m.DrivenTeeth) * FLOOR(e.Hi / (360e0 / m.DrivenTeeth))
    FROM motion.Edge AS e
    JOIN motion.Mesh AS m ON m.MeshNo = e.MeshNo
    WHERE e.Runs = 1;

    WITH lagged AS (
        SELECT e.MeshNo, e.I, e.EdgeDeg, 360e0 / m.DrivenTeeth AS Pv,
               FIRST_VALUE(e.EdgeDeg) OVER (PARTITION BY e.MeshNo ORDER BY e.I) AS E0,
               LAG(e.EdgeDeg) OVER (PARTITION BY e.MeshNo ORDER BY e.I) AS Prev
        FROM motion.Edge AS e
        JOIN motion.Mesh AS m ON m.MeshNo = e.MeshNo
        WHERE NOT EXISTS (SELECT 1 FROM motion.Edge AS j WHERE j.MeshNo = e.MeshNo AND j.Runs <> 1)
    ), d AS (
        SELECT l.MeshNo, l.I, l.E0,
               IIF(l.Prev IS NULL, 0e0, x.Step - l.Pv * FLOOR(x.Step / l.Pv) - l.Pv / 2) AS Delta
        FROM lagged AS l
        CROSS APPLY (SELECT l.EdgeDeg - l.Prev + l.Pv / 2 AS Step) AS x
    ), u AS (
        SELECT MeshNo, I, E0 + SUM(Delta) OVER (PARTITION BY MeshNo ORDER BY I ROWS UNBOUNDED PRECEDING) AS Progress
        FROM d
    )
    UPDATE e SET Progress = u.Progress
    FROM motion.Edge AS e
    JOIN u ON u.MeshNo = e.MeshNo AND u.I = e.I;

    SET @msg = CONCAT('push edges done  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;
END;
GO

CREATE OR ALTER FUNCTION motion.fn_Transmit (@MeshNo int, @U float)
RETURNS TABLE
AS
RETURN
    WITH m AS (
        SELECT 360e0 / ms.DriverTeeth AS Pu, 360e0 / ms.DrivenTeeth AS Pv, f.NU
        FROM motion.Mesh AS ms CROSS JOIN motion.Form AS f
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
    JOIN motion.Edge AS e0 ON e0.MeshNo = @MeshNo AND e0.I = i.I
    JOIN motion.Edge AS ez ON ez.MeshNo = @MeshNo AND ez.I = 0
    LEFT JOIN motion.Edge AS e1 ON e1.MeshNo = @MeshNo AND e1.I = i.I + 1;
GO

/* =====================================================================
   RUN: twelve hours. The cannon pinion turns with the minute hand, 360 deg
   an hour; the minute wheel and the hour wheel are read through the meshes.
   ===================================================================== */
CREATE OR ALTER PROCEDURE motion.usp_Run
    @Hours  float = 12,
    @Frames int   = 361,
    @Parts  bit   = 1,
    @RunId  int   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 datetime2 = SYSDATETIME(), @msg nvarchar(300);

    INSERT motion.Run (Hours, Frames) VALUES (@Hours, @Frames);
    SET @RunId = SCOPE_IDENTITY();

    DECLARE @sc smallint = (SELECT Spin FROM motion.Arbor WHERE Arbor = 'centre'),
            @sm smallint = (SELECT Spin FROM motion.Arbor WHERE Arbor = 'minute'),
            @sh smallint = (SELECT Spin FROM motion.Arbor WHERE Arbor = 'hour');

    INSERT motion.Frame (RunId, FrameNo, Hours, CentreDeg, MinuteDeg, HourDeg)
    SELECT @RunId, f.value, t.H, @sc * c.U, @sm * m1.V, @sh * m2.V
    FROM GENERATE_SERIES(0, @Frames - 1) AS f
    CROSS APPLY (SELECT @Hours * f.value / (@Frames - 1) AS H) AS t
    CROSS APPLY (SELECT 360e0 * t.H AS U) AS c                     -- the minute hand: once an hour
    CROSS APPLY motion.fn_Transmit(1, c.U)  AS m1                  -- minute wheel
    CROSS APPLY motion.fn_Transmit(2, m1.V) AS m2;                 -- hour wheel

    SET @msg = CONCAT('run ', @RunId, ': ', @Frames, ' frames  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    IF @Parts = 1
    BEGIN
        DECLARE @shapes TABLE (Part varchar(20) PRIMARY KEY, Arbor varchar(10), Geom geometry);
        INSERT @shapes (Part, Arbor, Geom)
        SELECT 'CannonPinion', 'centre',
               (SELECT Geom FROM motion.Shape WHERE MeshNo = 1 AND Part = 'DriverDisplay').STDifference(dbo.fn_Circle(0, 0, 0.18, 24))
        UNION ALL SELECT 'MinuteWheel', 'minute',
               (SELECT Geom FROM motion.Shape WHERE MeshNo = 1 AND Part = 'DrivenDisplay').STDifference(dbo.fn_Circle(0, 0, 0.15, 24))
        UNION ALL SELECT 'MinutePinion', 'minute',
               (SELECT Geom FROM motion.Shape WHERE MeshNo = 2 AND Part = 'DriverDisplay').STDifference(dbo.fn_Circle(0, 0, 0.15, 24))
        UNION ALL SELECT 'HourWheel', 'hour',
               (SELECT Geom FROM motion.Shape WHERE MeshNo = 2 AND Part = 'DrivenDisplay').STDifference(dbo.fn_Circle(0, 0, 0.5, 48));

        -- the hands, pressed on so they read twelve o'clock at the start
        DECLARE @minute geometry = geometry::STGeomFromText(
                    'POLYGON((-0.22 -1.4, 0.22 -1.4, 0.14 8.6, 0 9.3, -0.14 8.6, -0.22 -1.4))', 0),
                @hour geometry = geometry::STGeomFromText(
                    'POLYGON((-0.32 -1.2, 0.32 -1.2, 0.26 5.4, 0 6.2, -0.26 5.4, -0.32 -1.2))', 0);
        DECLARE @c0 float, @h0 float;
        SELECT @c0 = CentreDeg, @h0 = HourDeg FROM motion.Frame WHERE RunId = @RunId AND FrameNo = 0;

        INSERT motion.FramePart (RunId, FrameNo, Part, Geom)
        SELECT f.RunId, f.FrameNo, p.Part,
               dbo.fn_Place(p.Geom, CASE p.Arbor WHEN 'centre' THEN f.CentreDeg WHEN 'minute' THEN f.MinuteDeg
                                                 ELSE f.HourDeg END, a.X, a.Y, 1)
        FROM motion.Frame AS f
        CROSS JOIN @shapes AS p
        JOIN motion.Arbor AS a ON a.Arbor = p.Arbor
        WHERE f.RunId = @RunId
        UNION ALL
        SELECT f.RunId, f.FrameNo, h.Part, h.Geom
        FROM motion.Frame AS f
        CROSS APPLY (VALUES
            ('MinuteHand', dbo.fn_Place(@minute, f.CentreDeg - @c0, 0, 0, 1)),
            ('HourHand',   dbo.fn_Place(@hour,   f.HourDeg - @h0,   0, 0, 1))
        ) AS h (Part, Geom)
        WHERE f.RunId = @RunId;

        SET @msg = CONCAT('run ', @RunId, ': shapes stored  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
        RAISERROR(@msg, 0, 1) WITH NOWAIT;
    END;
END;
GO

/* =====================================================================
   WHAT THE TEETH DID
   ===================================================================== */
CREATE OR ALTER VIEW motion.vRatio
AS
SELECT  e.MeshNo, e.I,
        e.I * (360e0 / m.DriverTeeth) / f.NU AS DriverDeg,
        (COALESCE(LEAD(e.Progress) OVER (PARTITION BY e.MeshNo ORDER BY e.I),
                  FIRST_VALUE(e.Progress) OVER (PARTITION BY e.MeshNo ORDER BY e.I) + 360e0 / m.DrivenTeeth)
         - e.Progress) / ((360e0 / m.DriverTeeth) / f.NU) AS Ratio
FROM motion.Edge AS e
JOIN motion.Mesh AS m ON m.MeshNo = e.MeshNo
CROSS JOIN motion.Form AS f
WHERE e.Progress IS NOT NULL;
GO

CREATE OR ALTER VIEW motion.vMesh
AS
SELECT  m.MeshNo,
        CONCAT(m.DriverArbor, ' ', m.DriverTeeth, ' -> ', m.DrivenArbor, ' ', m.DrivenTeeth) AS Mesh,
        IIF(j.Jammed > 0, 'JAMS', 'turns')               AS Verdict,
        CAST(r.MeanRatio AS decimal(10, 6))              AS MeanRatio,     -- driven deg per driver deg
        CAST(r.MinRatio  AS decimal(10, 6))              AS MinRatio,
        CAST(r.MaxRatio  AS decimal(10, 6))              AS MaxRatio,
        CAST(b.Backlash  AS decimal(6, 2))               AS BacklashDeg    -- of the driven gear
FROM motion.Mesh AS m
OUTER APPLY (SELECT COUNT(*) AS Jammed FROM motion.Edge AS e WHERE e.MeshNo = m.MeshNo AND e.Runs <> 1) AS j
OUTER APPLY (SELECT AVG(Ratio) AS MeanRatio, MIN(Ratio) AS MinRatio, MAX(Ratio) AS MaxRatio
             FROM motion.vRatio AS v WHERE v.MeshNo = m.MeshNo) AS r
OUTER APPLY (SELECT MIN(w) AS Backlash
             FROM (SELECT SUM(CAST(mm.Clear AS int)) * (360e0 / m.DrivenTeeth) / f.NV AS w
                   FROM motion.MeshMap AS mm CROSS JOIN motion.Form AS f
                   WHERE mm.MeshNo = m.MeshNo
                   GROUP BY mm.I, f.NV) AS rows_) AS b;
GO

/* Does the hour wheel come back round onto the centre arbor? */
CREATE OR ALTER VIEW motion.vCoaxial
AS
SELECT  m1.Module * (m1.DriverTeeth + m1.DrivenTeeth) / 2                         AS CannonToMinuteMm,
        m2.Module * (m2.DriverTeeth + m2.DrivenTeeth) / 2                         AS MinuteToHourMm,
        geometry::Point(h.X, h.Y, 0).STDistance(geometry::Point(c.X, c.Y, 0))     AS HourWheelOffCentreMm
FROM motion.Mesh AS m1
JOIN motion.Mesh AS m2 ON m2.MeshNo = 2
JOIN motion.Arbor AS h ON h.Arbor = 'hour'
JOIN motion.Arbor AS c ON c.Arbor = 'centre'
WHERE m1.MeshNo = 1;
GO
