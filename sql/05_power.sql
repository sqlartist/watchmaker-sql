/* =====================================================================
   The Watchmaker  —  05_power.sql
   Episode 3: power. The mainspring in its barrel, and the ratchet and
   click that stop it unwinding the wrong way.

   power.usp_BuildClick  36-tooth sawtooth ratchet, a click on a pivot.
                         For every ratchet angle in one tooth (0.1 deg) and
                         click angle (0.05 deg): do they overlap?
   power.usp_Click       turns the ratchet a step at a time. The click's
                         spring pushes it as far in as it will go; if the
                         ratchet would hit it, it must be lifted clear, and
                         that is only possible if it can rise where it is.
                         Wind forwards five teeth, then let go. Nothing in
                         here says "one way".
   power.usp_Fill        how far can a barrel turn? Pack the spring coil on
                         coil round the arbor, then against the wall, and
                         find each pack's turns by measuring the drawn
                         spiral with STLength. The difference is all the
                         barrel will ever turn. Swept over spring lengths.
   power.usp_Spring      winds the spring up and lets it run down, frame
                         by frame, with the power reserve that's left.

   Units are millimetres; the barrel arbor is at the origin.
   ===================================================================== */
USE Watchmaker;
GO
IF SCHEMA_ID('power') IS NULL EXEC ('CREATE SCHEMA power');
GO

DROP TABLE IF EXISTS power.FramePart, power.SpringFrame, power.ClickFrame, power.Run, power.Fill,
                     power.ClickMap, power.PawlPos, power.RatchetPos, power.Shape, power.Spec;
GO

CREATE TABLE power.Spec
(
    Id            tinyint PRIMARY KEY CHECK (Id = 1),
    -- ratchet and click
    RatchetTeeth  int   NOT NULL,
    RatchetTip    float NOT NULL,
    RatchetRoot   float NOT NULL,
    PivotX        float NOT NULL,     -- the click's pivot
    PivotY        float NOT NULL,
    NR            int   NOT NULL,     -- ratchet grid, steps per tooth
    PawlMin       float NOT NULL,     -- click grid, deg (positive = further in)
    PawlMax       float NOT NULL,
    PawlStep      float NOT NULL,
    -- barrel and mainspring
    RB            float NOT NULL,     -- drum, inner radius
    RA            float NOT NULL,     -- arbor core radius
    T             float NOT NULL,     -- strip thickness
    L             float NOT NULL,     -- strip length
    PtsPerTurn    int   NOT NULL,
    FreeTurns     float NOT NULL,     -- the free coil between the two packs spans this many turns
    MinPack       float NOT NULL,     -- turns that always stay on the arbor, and on the wall
    BarrelTeeth   int   NOT NULL,     -- the barrel drives the centre pinion, and the centre arbor
    BarrelModule  float NOT NULL,     -- turns once an hour (episode 2): BarrelTeeth / CentreLeaves
    CentreLeaves  int   NOT NULL      -- hours per turn of the barrel
);

CREATE TABLE power.Shape
(
    Part      varchar(20) PRIMARY KEY,
    Geom      geometry NOT NULL
);

CREATE TABLE power.RatchetPos
(
    I         int PRIMARY KEY,
    Deg       float NOT NULL,
    Geom      geometry NOT NULL
);

CREATE TABLE power.PawlPos
(
    J         int PRIMARY KEY,
    Deg       float NOT NULL,
    Geom      geometry NOT NULL
);

CREATE TABLE power.ClickMap
(
    I         int NOT NULL,
    J         int NOT NULL,
    Clear     bit NOT NULL,
    CONSTRAINT PK_ClickMap PRIMARY KEY (I, J)
);

CREATE TABLE power.Fill                          -- how far a barrel turns, by spring length
(
    LengthMm      float PRIMARY KEY,
    WoundTurns    float NOT NULL,                 -- packed round the arbor
    LetDownTurns  float NOT NULL,                 -- packed against the wall
    BarrelTurns   float NOT NULL,                 -- the difference
    Fits          bit NOT NULL,                   -- does either pack run into the other side?
    FilledPct     float NOT NULL                  -- how much of the space between arbor and wall the strip fills
);

CREATE TABLE power.Run
(
    RunId     int IDENTITY PRIMARY KEY,
    Kind      varchar(10) NOT NULL,               -- click | spring
    Started   datetime2(3) NOT NULL DEFAULT SYSDATETIME(),
    Note      nvarchar(200) NULL
);

CREATE TABLE power.ClickFrame
(
    RunId       int NOT NULL REFERENCES power.Run(RunId),
    FrameNo     int NOT NULL,
    RatchetDeg  float NOT NULL,
    PawlDeg     float NOT NULL,
    Event       varchar(10) NOT NULL,             -- rest | lift | ride | drop | click | hold | back | locked
    CONSTRAINT PK_ClickFrame PRIMARY KEY (RunId, FrameNo)
);

CREATE TABLE power.SpringFrame
(
    RunId       int NOT NULL REFERENCES power.Run(RunId),
    FrameNo     int NOT NULL,
    Phase       varchar(10) NOT NULL,             -- winding | running
    Wound       float NOT NULL,                   -- turns of spring from arbor hook to barrel hook
    ArborDeg    float NOT NULL,
    BarrelDeg   float NOT NULL,
    InnerTurns  float NOT NULL,
    OuterTurns  float NOT NULL,
    LengthMm    float NOT NULL,                   -- STLength of the spring as drawn
    Hours       float NOT NULL,                   -- power reserve left
    CONSTRAINT PK_SpringFrame PRIMARY KEY (RunId, FrameNo)
);

CREATE TABLE power.FramePart
(
    RunId     int NOT NULL REFERENCES power.Run(RunId),
    FrameNo   int NOT NULL,
    Part      varchar(20) NOT NULL,
    Geom      geometry NOT NULL,
    CONSTRAINT PK_PowerFramePart PRIMARY KEY (RunId, FrameNo, Part)
);
GO

INSERT power.Spec (Id, RatchetTeeth, RatchetTip, RatchetRoot, PivotX, PivotY, NR, PawlMin, PawlMax, PawlStep,
                   RB, RA, T, L, PtsPerTurn, FreeTurns, MinPack, BarrelTeeth, BarrelModule, CentreLeaves)
VALUES (1, 36, 4.40, 3.95, 5.7, -3.4, 100, -14.0, 4.0, 0.05,
        5.0, 1.6, 0.10, 350.0, 48, 1.25, 1.0, 80, 0.14, 10);
GO

/* =====================================================================
   RATCHET AND CLICK
   ===================================================================== */
/* Sawtooth, walked anticlockwise: up the radial (locking) face, down the long slope */
CREATE OR ALTER FUNCTION power.fn_RatchetOutline ()
RETURNS geometry
AS
BEGIN
    DECLARE @n int, @tip float, @root float, @pts varchar(max);
    SELECT @n = RatchetTeeth, @tip = RatchetTip, @root = RatchetRoot FROM power.Spec;

    SELECT @pts = STRING_AGG(CAST(dbo.fn_Polar(0, 0, v.R, k.value * (360e0 / @n) + v.D) AS varchar(max)), ', ')
                  WITHIN GROUP (ORDER BY k.value, v.Seq)
    FROM GENERATE_SERIES(0, @n - 1) AS k
    CROSS JOIN (VALUES (1, 0e0, @root), (2, 0.4e0, @tip)) AS v (Seq, D, R);

    RETURN geometry::STGeomFromText(CONCAT('POLYGON((', @pts, ', ', dbo.fn_Polar(0, 0, @root, 0), '))'), 0);
END;
GO

/* The click at rest: a head whose tip sits in the gap against a tooth's
   radial face, an arm to the pivot, a boss */
CREATE OR ALTER FUNCTION power.fn_PawlOutline ()
RETURNS geometry
AS
BEGIN
    DECLARE @px float, @py float;
    SELECT @px = PivotX, @py = PivotY FROM power.Spec;

    DECLARE @head geometry = geometry::STGeomFromText(CONCAT('POLYGON((',
        dbo.fn_Polar(0, 0, 4.00, -0.6), ', ', dbo.fn_Polar(0, 0, 4.62, -0.6), ', ', dbo.fn_Polar(0, 0, 5.05, -1.5), ', ',
        dbo.fn_Polar(0, 0, 4.75, -4.6), ', ', dbo.fn_Polar(0, 0, 4.30, -4.0), ', ', dbo.fn_Polar(0, 0, 4.00, -0.6), '))'), 0);

    -- the arm: a bar 0.6 wide from the head to the pivot, rounded at the head end
    DECLARE @ax float = 4.72 * COS(RADIANS(-3e0)), @ay float = 4.72 * SIN(RADIANS(-3e0));
    DECLARE @ux float = @px - @ax, @uy float = @py - @ay;
    DECLARE @n float = SQRT(@ux * @ux + @uy * @uy);
    DECLARE @nx float = -@uy / @n * 0.3, @ny float = @ux / @n * 0.3;
    DECLARE @arm geometry = geometry::STGeomFromText(CONCAT('POLYGON((',
        dbo.fmt(@ax + @nx), ' ', dbo.fmt(@ay + @ny), ', ', dbo.fmt(@px + @nx), ' ', dbo.fmt(@py + @ny), ', ',
        dbo.fmt(@px - @nx), ' ', dbo.fmt(@py - @ny), ', ', dbo.fmt(@ax - @nx), ' ', dbo.fmt(@ay - @ny), ', ',
        dbo.fmt(@ax + @nx), ' ', dbo.fmt(@ay + @ny), '))'), 0);

    RETURN @head.STUnion(@arm).STUnion(dbo.fn_Circle(@ax, @ay, 0.3, 32)).STUnion(dbo.fn_Circle(@px, @py, 0.6, 32))
                .STDifference(dbo.fn_Circle(@px, @py, 0.18, 16));
END;
GO

CREATE OR ALTER PROCEDURE power.usp_BuildClick
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 datetime2 = SYSDATETIME(), @msg nvarchar(200);
    DECLARE @n int, @NR int, @pmin float, @pmax float, @pstep float, @px float, @py float;
    SELECT @n = RatchetTeeth, @NR = NR, @pmin = PawlMin, @pmax = PawlMax, @pstep = PawlStep, @px = PivotX, @py = PivotY
    FROM power.Spec;
    DECLARE @NC int = ROUND((@pmax - @pmin) / @pstep, 0) + 1;

    DELETE power.FramePart; DELETE power.ClickFrame; DELETE power.SpringFrame; DELETE power.Run;
    TRUNCATE TABLE power.ClickMap;
    DELETE power.RatchetPos; DELETE power.PawlPos; DELETE power.Shape;

    INSERT power.Shape (Part, Geom)
    VALUES ('Ratchet', power.fn_RatchetOutline()),
           ('Pawl',    power.fn_PawlOutline()),
           ('Zone',    dbo.fn_Circle(4.2, -0.5, 2.2, 64));          -- the only place the two can meet

    DECLARE @ratchet geometry = (SELECT Geom FROM power.Shape WHERE Part = 'Ratchet'),
            @pawl    geometry = (SELECT Geom FROM power.Shape WHERE Part = 'Pawl'),
            @zone    geometry = (SELECT Geom FROM power.Shape WHERE Part = 'Zone');

    INSERT power.RatchetPos (I, Deg, Geom)
    SELECT i.value, 360e0 / @n * i.value / @NR,
           dbo.fn_Rotate(@ratchet, 360e0 / @n * i.value / @NR, 0, 0).STIntersection(@zone)
    FROM GENERATE_SERIES(0, @NR - 1) AS i;

    INSERT power.PawlPos (J, Deg, Geom)
    SELECT j.value, @pmin + j.value * @pstep, dbo.fn_Rotate(@pawl, @pmin + j.value * @pstep, @px, @py)
    FROM GENERATE_SERIES(0, @NC - 1) AS j;

    /* the physics, asked once */
    INSERT power.ClickMap (I, J, Clear)
    SELECT r.I, p.J, IIF(r.Geom.STIntersects(p.Geom) = 1, 0, 1)
    FROM power.RatchetPos AS r
    CROSS JOIN power.PawlPos AS p;

    SET @msg = CONCAT('power.ClickMap: ', @@ROWCOUNT, ' poses  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;
END;
GO

/* Top of the clear run containing click step @J at ratchet step @I: the
   click spring pushes the click in (towards higher J) until it touches */
CREATE OR ALTER FUNCTION power.fn_RunTop (@I int, @J int)
RETURNS int
AS
BEGIN
    DECLARE @top int = (SELECT MIN(J) FROM power.ClickMap WHERE I = @I AND J > @J AND Clear = 0);
    RETURN IIF(@top IS NULL, (SELECT MAX(J) FROM power.ClickMap WHERE I = @I), @top - 1);
END;
GO

CREATE OR ALTER PROCEDURE power.usp_Click
    @Forward int = 200,       -- steps of 0.1 deg: five teeth
    @Hold    int = 30,
    @Back    int = 160,
    @RunId   int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @n int, @NR int, @pmin float, @pstep float;
    SELECT @n = RatchetTeeth, @NR = NR, @pmin = PawlMin, @pstep = PawlStep FROM power.Spec;
    DECLARE @pitch float = 360e0 / @n;

    INSERT power.Run (Kind, Note) VALUES ('click', CONCAT('forward ', @Forward, ', hold ', @Hold, ', back ', @Back));
    SET @RunId = SCOPE_IDENTITY();

    DECLARE @i int = 0, @teeth int = 0, @f int = 0, @k int, @d int, @i2 int, @j2 int, @ev varchar(10), @msg nvarchar(200);
    DECLARE @j int = power.fn_RunTop(0, ROUND((0 - @pmin) / @pstep, 0));

    INSERT power.ClickFrame VALUES (@RunId, 0, 0, @pmin + @j * @pstep, 'rest');

    SET @k = 0;
    WHILE @k < @Forward + @Hold + @Back
    BEGIN
        SET @f += 1;
        IF @k >= @Forward AND @k < @Forward + @Hold
            SET @ev = 'hold';
        ELSE
        BEGIN
            SET @d = IIF(@k < @Forward, 1, -1);
            SET @i2 = (@i + @d + @NR) % @NR;
            SET @ev = NULL;

            IF (SELECT Clear FROM power.ClickMap WHERE I = @i2 AND J = @j) = 1
            BEGIN       -- the ratchet moves under the click; its spring drops it in as far as it will go
                SET @j2 = power.fn_RunTop(@i2, @j);
                SET @ev = CASE WHEN (@j2 - @j) * @pstep > 1 THEN 'click' WHEN @j2 > @j THEN 'drop' ELSE 'ride' END;
            END
            ELSE
            BEGIN       -- it must be lifted: to the nearest clear angle, if it can rise to it where it is now
                SET @j2 = (SELECT MAX(J) FROM power.ClickMap WHERE I = @i2 AND J < @j AND Clear = 1);
                IF @j2 IS NOT NULL
                   AND NOT EXISTS (SELECT 1 FROM power.ClickMap WHERE I = @i AND J BETWEEN @j2 AND @j AND Clear = 0)
                    SELECT @j2 = power.fn_RunTop(@i2, @j2), @ev = 'lift';
            END;

            IF @ev IS NULL
                SET @ev = 'locked';                       -- nowhere to go: the ratchet stays put
            ELSE
            BEGIN
                SET @teeth += CASE WHEN @d = 1 AND @i2 < @i THEN 1 WHEN @d = -1 AND @i2 > @i THEN -1 ELSE 0 END;
                SELECT @i = @i2, @j = @j2;
                IF @d = -1 SET @ev = 'back';
            END;
        END;

        INSERT power.ClickFrame VALUES (@RunId, @f, @teeth * @pitch + @pitch * @i / @NR, @pmin + @j * @pstep, @ev);
        SET @k += 1;
    END;

    SELECT @msg = CONCAT('run ', @RunId, ': ', COUNT(*), ' frames, ', SUM(IIF(Event = 'click', 1, 0)), ' clicks winding, ',
                         'slipped back ', FORMAT(MAX(IIF(Event IN ('lift', 'click', 'drop', 'ride', 'hold'), RatchetDeg, NULL))
                                                 - MIN(IIF(Event = 'locked', RatchetDeg, NULL)), '0.0'),
                         ' deg before it locked')
    FROM power.ClickFrame WHERE RunId = @RunId;
    RAISERROR(@msg, 0, 1) WITH NOWAIT;
END;
GO

/* =====================================================================
   MAINSPRING
   ===================================================================== */
/* Archimedean spiral points: radius @r0 + @dr * s after s turns, angle @a0 + @dir * 360 s */
CREATE OR ALTER FUNCTION power.fn_SpiralPts (@r0 float, @dr float, @a0 float, @turns float, @dir int)
RETURNS TABLE
AS
RETURN
    WITH n AS (
        SELECT IIF(CEILING(@turns * PtsPerTurn) + 1 > 2, CAST(CEILING(@turns * PtsPerTurn) AS int) + 1, 2) AS N
        FROM power.Spec
    )
    SELECT k.value AS K,
           (@r0 + @dr * s.S) * COS(RADIANS(@a0 + @dir * 360e0 * s.S)) AS X,
           (@r0 + @dr * s.S) * SIN(RADIANS(@a0 + @dir * 360e0 * s.S)) AS Y
    FROM n
    CROSS APPLY GENERATE_SERIES(0, n.N - 1) AS k
    CROSS APPLY (SELECT @turns * k.value / (n.N - 1) AS S) AS s;
GO

CREATE OR ALTER FUNCTION power.fn_Spiral (@r0 float, @dr float, @a0 float, @turns float, @dir int)
RETURNS geometry
AS
BEGIN
    DECLARE @pts varchar(max);
    SELECT @pts = STRING_AGG(CAST(CONCAT(dbo.fmt(X), ' ', dbo.fmt(Y)) AS varchar(max)), ', ') WITHIN GROUP (ORDER BY K)
    FROM power.fn_SpiralPts(@r0, @dr, @a0, @turns, @dir);
    RETURN geometry::STGeomFromText(CONCAT('LINESTRING(', @pts, ')'), 0);
END;
GO

/* How many turns a strip of @Length makes packed coil on coil round the
   arbor (@Inner = 1) or against the wall: measure the drawn spiral with
   STLength, and halve the search forty times */
CREATE OR ALTER FUNCTION power.fn_PackTurns (@Length float, @Inner bit)
RETURNS float
AS
BEGIN
    DECLARE @RB float, @RA float, @T float;
    SELECT @RB = RB, @RA = RA, @T = T FROM power.Spec;
    DECLARE @r0 float = IIF(@Inner = 1, @RA + @T / 2, @RB - @T / 2), @dr float = IIF(@Inner = 1, @T, -@T);
    DECLARE @lo float = 0, @hi float = @Length / (2 * PI() * @RA), @mid float, @i int = 0;
    WHILE @i < 40
    BEGIN
        SET @mid = (@lo + @hi) / 2;
        IF power.fn_Spiral(@r0, @dr, 0, @mid, 1).STLength() >= @Length
            SET @hi = @mid;
        ELSE
            SET @lo = @mid;
        SET @i += 1;
    END;
    RETURN @hi;
END;
GO

CREATE OR ALTER PROCEDURE power.usp_Fill
    @From float = 50, @To float = 650, @Step float = 25
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 datetime2 = SYSDATETIME(), @msg nvarchar(200);
    DECLARE @RB float, @RA float, @T float;
    SELECT @RB = RB, @RA = RA, @T = T FROM power.Spec;

    DELETE power.Fill;
    INSERT power.Fill (LengthMm, WoundTurns, LetDownTurns, BarrelTurns, Fits, FilledPct)
    SELECT x.L, x.NIn, x.NOut, x.NIn - x.NOut,
           IIF(@RA + @T * x.NIn + @T <= @RB AND @RB - @T * x.NOut - @T >= @RA, 1, 0),
           100 * x.L * @T / (PI() * (@RB * @RB - @RA * @RA))
    FROM GENERATE_SERIES(0, CAST((@To - @From) / @Step AS int)) AS k
    CROSS APPLY (SELECT @From + k.value * @Step AS L) AS l
    CROSS APPLY (SELECT l.L, power.fn_PackTurns(l.L, 1) AS NIn, power.fn_PackTurns(l.L, 0) AS NOut) AS x;

    SET @msg = CONCAT('power.Fill: ', @@ROWCOUNT, ' spring lengths  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;
END;
GO

/* The length of a spring with @NIn turns on the arbor, @NOut on the wall,
   and the free coil between (Archimedean packs, summed exactly) */
CREATE OR ALTER FUNCTION power.fn_ShapeLen (@NIn float, @NOut float)
RETURNS float
AS
BEGIN
    DECLARE @RB float, @RA float, @T float, @F float;
    SELECT @RB = RB, @RA = RA, @T = T, @F = FreeTurns FROM power.Spec;
    DECLARE @r1 float = @RA + @T / 2 + @T * @NIn, @r2 float = @RB - @T / 2 - @T * @NOut;
    RETURN 2 * PI() * @NIn * ((@RA + @T / 2) + @T * @NIn / 2)
         + 2 * PI() * @NOut * ((@RB - @T / 2) + -@T * @NOut / 2)
         + PI() * @F * (@r1 + @r2);
END;
GO

/* Split @Wound turns (packs + free coil) between the packs so the length is L */
CREATE OR ALTER FUNCTION power.fn_InnerTurns (@Wound float)
RETURNS float
AS
BEGIN
    DECLARE @L float, @F float;
    SELECT @L = L, @F = FreeTurns FROM power.Spec;
    DECLARE @s float = @Wound - @F, @lo float = 0, @hi float, @mid float, @i int = 0;
    SET @hi = @s;
    WHILE @i < 60          -- more on the arbor = less length for the same turns
    BEGIN
        SET @mid = (@lo + @hi) / 2;
        IF power.fn_ShapeLen(@mid, @s - @mid) > @L SET @lo = @mid; ELSE SET @hi = @mid;
        SET @i += 1;
    END;
    RETURN @hi;
END;
GO

/* Total turns of the spring let down (@LetDown = 1: MinPack on the arbor)
   or fully wound (MinPack left on the wall) */
CREATE OR ALTER FUNCTION power.fn_WoundLimit (@LetDown bit)
RETURNS float
AS
BEGIN
    DECLARE @L float, @F float, @M float, @RB float, @RA float, @T float;
    SELECT @L = L, @F = FreeTurns, @M = MinPack, @RB = RB, @RA = RA, @T = T FROM power.Spec;
    DECLARE @lo float = 0, @hi float = (@RB - @RA) / @T - @M - @F, @mid float, @i int = 0;
    WHILE @i < 60
    BEGIN
        SET @mid = (@lo + @hi) / 2;
        IF IIF(@LetDown = 1, power.fn_ShapeLen(@M, @mid), power.fn_ShapeLen(@mid, @M)) > @L
            SET @hi = @mid;
        ELSE
            SET @lo = @mid;
        SET @i += 1;
    END;
    RETURN IIF(@LetDown = 1, @M + @hi + @F, @hi + @M + @F);
END;
GO

/* The spring as one line: inner pack from the arbor hook, the free coil,
   the outer pack to the wall. It winds outwards clockwise, so winding the
   arbor anticlockwise tightens it. */
CREATE OR ALTER FUNCTION power.fn_SpringLine (@ArborDeg float, @Wound float)
RETURNS geometry
AS
BEGIN
    DECLARE @RB float, @RA float, @T float, @F float;
    SELECT @RB = RB, @RA = RA, @T = T, @F = FreeTurns FROM power.Spec;
    DECLARE @nin float = power.fn_InnerTurns(@Wound);
    DECLARE @nout float = @Wound - @F - @nin;
    DECLARE @r1 float = @RA + @T / 2 + @T * @nin, @r2 float = @RB - @T / 2 - @T * @nout;

    DECLARE @pts varchar(max);
    WITH seg AS (
        SELECT 1 AS Seg, K, X, Y FROM power.fn_SpiralPts(@RA + @T / 2, @T, @ArborDeg, @nin, -1)
        UNION ALL
        SELECT 2, K, X, Y FROM power.fn_SpiralPts(@r1, (@r2 - @r1) / @F, @ArborDeg - 360e0 * @nin, @F, -1) WHERE K > 0
        UNION ALL
        SELECT 3, K, X, Y FROM power.fn_SpiralPts(@r2, @T, @ArborDeg - 360e0 * @nin - 360e0 * @F, @nout, -1) WHERE K > 0
    )
    SELECT @pts = STRING_AGG(CAST(CONCAT(dbo.fmt(X), ' ', dbo.fmt(Y)) AS varchar(max)), ', ') WITHIN GROUP (ORDER BY Seg, K)
    FROM seg;

    RETURN geometry::STGeomFromText(CONCAT('LINESTRING(', @pts, ')'), 0);
END;
GO

CREATE OR ALTER PROCEDURE power.usp_Spring
    @Frames int = 120,        -- per phase
    @Parts  bit = 1,
    @RunId  int = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 datetime2 = SYSDATETIME(), @msg nvarchar(300);
    DECLARE @RB float, @RA float, @hpt float, @bt int, @bm float, @cl int;
    SELECT @RB = RB, @RA = RA, @bt = BarrelTeeth, @bm = BarrelModule, @cl = CentreLeaves FROM power.Spec;
    SET @hpt = 1e0 * @bt / @cl;                        -- the centre arbor turns once an hour
    DECLARE @w0 float = power.fn_WoundLimit(1), @w1 float = power.fn_WoundLimit(0);

    INSERT power.Run (Kind, Note) VALUES ('spring', CONCAT('let down ', FORMAT(@w0, '0.000'), ' turns, wound ',
                                                            FORMAT(@w1, '0.000'), ' turns'));
    SET @RunId = SCOPE_IDENTITY();

    INSERT power.SpringFrame (RunId, FrameNo, Phase, Wound, ArborDeg, BarrelDeg, InnerTurns, OuterTurns, LengthMm, Hours)
    SELECT @RunId, w.FrameNo, w.Phase, w.Wound,
           IIF(w.Phase = 'winding', 360e0 * (w.Wound - @w0), 360e0 * (@w1 - @w0)),     -- winding: the arbor turns
           IIF(w.Phase = 'winding', 0e0, 360e0 * (@w1 - w.Wound)),                       -- running: the barrel turns
           i.NIn, w.Wound - sp.FreeTurns - i.NIn,
           power.fn_SpringLine(IIF(w.Phase = 'winding', 360e0 * (w.Wound - @w0), 360e0 * (@w1 - @w0)), w.Wound).STLength(),
           (w.Wound - @w0) * @hpt
    FROM (
        SELECT p.Ord * (@Frames + 1) + f.value AS FrameNo, p.Phase,
               IIF(p.Phase = 'winding', @w0 + (@w1 - @w0) * (1e0 * f.value / @Frames),
                                        @w1 - (@w1 - @w0) * (1e0 * f.value / @Frames)) AS Wound
        FROM (VALUES (0, 'winding'), (1, 'running')) AS p (Ord, Phase)
        CROSS JOIN GENERATE_SERIES(0, @Frames) AS f
    ) AS w
    CROSS JOIN power.Spec AS sp
    CROSS APPLY (SELECT power.fn_InnerTurns(w.Wound) AS NIn) AS i;

    SET @msg = CONCAT('run ', @RunId, ': let down ', FORMAT(@w0, '0.00'), ' turns, wound ', FORMAT(@w1, '0.00'),
                      ' -> the barrel can turn ', FORMAT(@w1 - @w0, '0.00'), ' times = ',
                      FORMAT((@w1 - @w0) * @hpt, '0.0'), ' hours  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    IF @Parts = 1
    BEGIN
        -- the barrel: drum and teeth (episode 2's cycloidal teeth), with the hook the spring's outer end catches on
        DECLARE @hook float = -360e0 * @w0;
        DECLARE @barrel geometry = train.fn_WheelOutline(@bt, @bm, @bm * @cl / 4, 'cycloidal', 4)
                                     .STDifference(dbo.fn_Circle(0, 0, @RB, 180))
                                     .STDifference(geometry::STGeomFromText(CONCAT('POLYGON((',
                                         dbo.fn_Polar(0, 0, @RB - 0.05, @hook - 5), ', ', dbo.fn_Polar(0, 0, @RB + 0.12, @hook), ', ',
                                         dbo.fn_Polar(0, 0, @RB - 0.05, @hook + 1), ', ', dbo.fn_Polar(0, 0, @RB - 0.05, @hook - 5), '))'), 0));
        DECLARE @arbor geometry = dbo.fn_Circle(0, 0, @RA, 96).STUnion(geometry::STGeomFromText(CONCAT('POLYGON((',
                                         dbo.fn_Polar(0, 0, @RA - 0.02, -10), ', ', dbo.fn_Polar(0, 0, @RA + 0.13, 0), ', ',
                                         dbo.fn_Polar(0, 0, @RA - 0.02, 6), ', ', dbo.fn_Polar(0, 0, @RA - 0.02, -10), '))'), 0))
                                     .STDifference(dbo.fn_Circle(0, 0, 0.45, 24));

        INSERT power.FramePart (RunId, FrameNo, Part, Geom)
        SELECT f.RunId, f.FrameNo, v.Part, v.Geom
        FROM power.SpringFrame AS f
        CROSS APPLY (VALUES
            ('Barrel', dbo.fn_Rotate(@barrel, f.BarrelDeg, 0, 0)),
            ('Arbor',  dbo.fn_Rotate(@arbor, f.ArborDeg, 0, 0)),
            ('Spring', power.fn_SpringLine(f.ArborDeg, f.Wound))
        ) AS v (Part, Geom)
        WHERE f.RunId = @RunId;

        SET @msg = CONCAT('run ', @RunId, ': shapes stored  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
        RAISERROR(@msg, 0, 1) WITH NOWAIT;
    END;
END;
GO

/* The click's shapes for drawing: the ratchet (with its square), the click,
   and the click spring bent to wherever the click is */
CREATE OR ALTER PROCEDURE power.usp_ClickParts @RunId int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @px float, @py float;
    SELECT @px = PivotX, @py = PivotY FROM power.Spec;
    DECLARE @ratchet geometry = (SELECT Geom FROM power.Shape WHERE Part = 'Ratchet')
                                  .STDifference(geometry::STGeomFromText('POLYGON((-0.65 -0.65, 0.65 -0.65, 0.65 0.65, -0.65 0.65, -0.65 -0.65))', 0)),
            @pawl geometry = (SELECT Geom FROM power.Shape WHERE Part = 'Pawl');

    DELETE power.FramePart WHERE RunId = @RunId;

    WITH tip AS (       -- where the click spring presses on the back of the click
        SELECT f.RunId, f.FrameNo, f.RatchetDeg, f.PawlDeg,
               dbo.fn_Rotate(geometry::Point(5.05 * COS(RADIANS(-1.5e0)), 5.05 * SIN(RADIANS(-1.5e0)), 0),
                             f.PawlDeg, @px, @py) AS Tip
        FROM power.ClickFrame AS f
        WHERE f.RunId = @RunId
    ), leaf AS (        -- the spring: a curved leaf from its foot to that point
        SELECT t.FrameNo,
               STRING_AGG(CAST(CONCAT(dbo.fmt(b.X), ' ', dbo.fmt(b.Y)) AS varchar(max)), ', ') WITHIN GROUP (ORDER BY b.U) AS Pts
        FROM tip AS t
        CROSS JOIN (SELECT k.value / 24e0 AS U FROM GENERATE_SERIES(0, 24) AS k) AS u
        CROSS APPLY (SELECT u.U,
                            (1 - u.U) * (1 - u.U) * 7.6 + 2 * (1 - u.U) * u.U * 7.4 + u.U * u.U * t.Tip.STX AS X,
                            (1 - u.U) * (1 - u.U) * 1.9 + 2 * (1 - u.U) * u.U * 0.2 + u.U * u.U * t.Tip.STY AS Y) AS b
        GROUP BY t.FrameNo
    )
    INSERT power.FramePart (RunId, FrameNo, Part, Geom)
    SELECT t.RunId, t.FrameNo, v.Part, v.Geom
    FROM tip AS t
    JOIN leaf AS l ON l.FrameNo = t.FrameNo
    CROSS APPLY (VALUES
        ('Ratchet', dbo.fn_Rotate(@ratchet, t.RatchetDeg, 0, 0)),
        ('Pawl',    dbo.fn_Rotate(@pawl, t.PawlDeg, @px, @py)),
        ('ClickSpring', geometry::STGeomFromText(CONCAT('LINESTRING(', l.Pts, ')'), 0).STBuffer(0.07))
    ) AS v (Part, Geom);
END;
GO

/* =====================================================================
   WHAT THE CLICK DID
   ===================================================================== */
CREATE OR ALTER VIEW power.vClick
AS
SELECT  r.RunId,
        SUM(IIF(f.Event = 'click', 1, 0))                                          AS Clicks,
        CAST((MAX(IIF(f.Event = 'click', f.RatchetDeg, NULL)) - MIN(IIF(f.Event = 'click', f.RatchetDeg, NULL)))
             / NULLIF(SUM(IIF(f.Event = 'click', 1, 0)) - 1, 0) AS decimal(6, 2)) AS DegBetweenClicks,
        CAST(360 / NULLIF((MAX(IIF(f.Event = 'click', f.RatchetDeg, NULL)) - MIN(IIF(f.Event = 'click', f.RatchetDeg, NULL)))
             / NULLIF(SUM(IIF(f.Event = 'click', 1, 0)) - 1, 0), 0) AS decimal(6, 2)) AS ClicksPerTurn,
        CAST(MAX(f.PawlDeg) - MIN(f.PawlDeg) AS decimal(6, 2))                     AS ClickTravelDeg,
        CAST(MAX(IIF(f.Event IN ('lift', 'click', 'drop', 'ride', 'hold'), f.RatchetDeg, NULL))
             - MIN(IIF(f.Event = 'locked', f.RatchetDeg, NULL)) AS decimal(6, 2))  AS SlipBackDeg,
        SUM(IIF(f.Event = 'locked', 1, 0))                                         AS StepsRefused
FROM power.Run AS r
JOIN power.ClickFrame AS f ON f.RunId = r.RunId
WHERE r.Kind = 'click'
GROUP BY r.RunId;
GO
