/* =====================================================================
   The Watchmaker  —  03_escapement.sql
   The Swiss lever escapement.

   esc.usp_BuildMaps  asks the only physical question there is — does this
                      shape touch that one? — for every pose on the grids,
                      and stores the answers:
                        esc.WheelFork  240 wheel angles x 161 fork angles
                        esc.JewelFork  361 balance angles x 161 fork angles
   esc.usp_Run        drives the balance back and forth and lets the fork
                      and wheel go wherever those maps allow, logging every
                      frame to esc.Frame and its shapes to esc.FramePart.
   esc.vBeat          measures lock, lift, recoil, impulse and drop per beat.

   Nothing in here says "lock", "impulse" or "drop" until the run is over and
   we look at which face the wheel ended up touching. The phases fall out of
   the metal.
   ===================================================================== */
USE Watchmaker;
GO

CREATE OR ALTER PROCEDURE esc.usp_BuildMaps
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 datetime2 = SYSDATETIME(), @msg nvarchar(200);

    DECLARE @Teeth int, @ThetaStep float, @PhiStep float, @PhiMin float, @PhiMax float,
            @BetaStep float, @BetaMax float, @Entry float, @Exit float;
    SELECT @Teeth = Teeth, @ThetaStep = ThetaStep, @PhiStep = PhiStep, @PhiMin = PhiMin, @PhiMax = PhiMax,
           @BetaStep = BetaStep, @BetaMax = BetaMax, @Entry = EntryLock, @Exit = ExitLock
    FROM esc.Spec;

    DECLARE @Px float, @Py float;
    SELECT @Px = Px, @Py = Py FROM esc.fn_Places();

    DECLARE @NT int = ROUND(360e0 / @Teeth / @ThetaStep, 0),
            @NP int = ROUND((@PhiMax - @PhiMin) / @PhiStep, 0) + 1,
            @NB int = ROUND(2 * @BetaMax / @BetaStep, 0) + 1;

    -- new maps, so old runs no longer mean anything
    DELETE esc.FramePart; DELETE esc.Frame; DELETE esc.Run;
    TRUNCATE TABLE esc.WheelFork; TRUNCATE TABLE esc.JewelFork;
    DELETE esc.WheelPos; DELETE esc.ForkPos; DELETE esc.JewelPos; DELETE esc.Shape;

    /* ---- the parts, at rest ---- */
    INSERT esc.Shape (Part, Geom)
    VALUES ('Wheel',        esc.fn_WheelDisplay()),
           ('WheelContact', esc.fn_WheelContact()),
           ('Steel',        esc.fn_PalletBody().STUnion(esc.fn_Lever())),
           ('Lever',        esc.fn_Lever()),
           ('EntryStone',   esc.fn_Stone(@Entry, 'Stone')),
           ('ExitStone',    esc.fn_Stone(@Exit,  'Stone')),
           ('BankingPins',  esc.fn_BankingPins()),
           ('Balance',      esc.fn_Balance()),
           ('Roller',       dbo.fn_Circle((SELECT BalX FROM esc.fn_Places()), (SELECT BalY FROM esc.fn_Places()), 2.0, 96));

    DECLARE @wc    geometry = (SELECT Geom FROM esc.Shape WHERE Part = 'WheelContact'),
            @fork  geometry = (SELECT geometry::UnionAggregate(Geom) FROM esc.Shape
                               WHERE Part IN ('Steel', 'EntryStone', 'ExitStone')),
            @lever geometry = (SELECT Geom FROM esc.Shape WHERE Part = 'Lever'),
            @pins  geometry = (SELECT Geom FROM esc.Shape WHERE Part = 'BankingPins'),
            @eL geometry = esc.fn_Stone(@Entry, 'Lock'), @eI geometry = esc.fn_Stone(@Entry, 'Impulse'),
            @xL geometry = esc.fn_Stone(@Exit,  'Lock'), @xI geometry = esc.fn_Stone(@Exit,  'Impulse');

    /* ---- every pose ---- */
    INSERT esc.WheelPos (I, Theta, Geom)
    SELECT i.value, i.value * @ThetaStep, dbo.fn_Rotate(@wc, i.value * @ThetaStep, 0, 0)
    FROM GENERATE_SERIES(0, @NT - 1) AS i;

    INSERT esc.ForkPos (J, Phi, Geom, LeverGeom, EntryLockFace, EntryImpulseFace, ExitLockFace, ExitImpulseFace, PinClear)
    SELECT j.value, a.Phi,
           dbo.fn_Rotate(@fork,  a.Phi, @Px, @Py),
           dbo.fn_Rotate(@lever, a.Phi, @Px, @Py),
           dbo.fn_Rotate(@eL, a.Phi, @Px, @Py), dbo.fn_Rotate(@eI, a.Phi, @Px, @Py),
           dbo.fn_Rotate(@xL, a.Phi, @Px, @Py), dbo.fn_Rotate(@xI, a.Phi, @Px, @Py),
           1
    FROM GENERATE_SERIES(0, @NP - 1) AS j
    CROSS APPLY (SELECT @PhiMin + j.value * @PhiStep AS Phi) AS a;

    UPDATE esc.ForkPos SET PinClear = IIF(Geom.STIntersects(@pins) = 1, 0, 1);

    INSERT esc.JewelPos (B, Beta, Geom)
    SELECT b.value, -@BetaMax + b.value * @BetaStep, esc.fn_Jewel(-@BetaMax + b.value * @BetaStep)
    FROM GENERATE_SERIES(0, @NB - 1) AS b;

    SET @msg = CONCAT('poses built: ', @NT, ' wheel, ', @NP, ' fork, ', @NB, ' balance  (',
                      DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    /* ---- the physics, asked once ---- */
    -- Clear: do the wheel and fork overlap?  Face: which stone face would the
    -- wheel hit if it turned one more step? (lock faces win at a shared corner)
    INSERT esc.WheelFork (I, J, Clear, Face)
    SELECT w.I, f.J,
           IIF(w.Geom.STIntersects(f.Geom) = 1, 0, 1),
           CASE WHEN nx.Geom.STIntersects(f.EntryLockFace)    = 1 THEN 1
                WHEN nx.Geom.STIntersects(f.EntryImpulseFace) = 1 THEN 2
                WHEN nx.Geom.STIntersects(f.ExitLockFace)     = 1 THEN 3
                WHEN nx.Geom.STIntersects(f.ExitImpulseFace)  = 1 THEN 4
                ELSE 0 END
    FROM esc.WheelPos AS w
    JOIN esc.WheelPos AS nx ON nx.I = (w.I + 1) % @NT       -- the wheel repeats every pitch
    CROSS JOIN esc.ForkPos AS f;

    SET @msg = CONCAT('esc.WheelFork: ', @@ROWCOUNT, ' poses  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    INSERT esc.JewelFork (B, J, Clear)
    SELECT jp.B, f.J, IIF(jp.Geom.STIntersects(f.LeverGeom) = 1, 0, 1)
    FROM esc.JewelPos AS jp
    CROSS JOIN esc.ForkPos AS f;

    SET @msg = CONCAT('esc.JewelFork: ', @@ROWCOUNT, ' poses  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;
END;
GO

/* =====================================================================
   RUN THE WATCH
   ===================================================================== */
CREATE OR ALTER PROCEDURE esc.usp_Run
    @Amplitude float = 110,     -- balance swing, deg either side
    @Beats     int   = 4,       -- two beats per swing
    @WheelCap  int   = 15,      -- most grid steps the wheel may turn in one frame
    @Parts     bit   = 1,       -- also store every frame's shapes for drawing
    @RunId     int   = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 datetime2 = SYSDATETIME(), @msg nvarchar(300);

    DECLARE @Teeth int, @ThetaStep float, @PhiStep float, @PhiMin float, @PhiMax float,
            @BetaStep float, @BetaMax float, @Bank float;
    SELECT @Teeth = Teeth, @ThetaStep = ThetaStep, @PhiStep = PhiStep, @PhiMin = PhiMin, @PhiMax = PhiMax,
           @BetaStep = BetaStep, @BetaMax = BetaMax, @Bank = BankDeg
    FROM esc.Spec;

    DECLARE @NT int = ROUND(360e0 / @Teeth / @ThetaStep, 0),
            @NP int = ROUND((@PhiMax - @PhiMin) / @PhiStep, 0) + 1,
            @NB int = ROUND(2 * @BetaMax / @BetaStep, 0) + 1;

    INSERT esc.Run (Amplitude, Beats, WheelCap) VALUES (@Amplitude, @Beats, @WheelCap);
    SET @RunId = SCOPE_IDENTITY();

    /* ---- the balance, frame by frame: a sine swing filmed in slow motion
            while it is near the middle (where the escapement does its work) ---- */
    DECLARE @sched TABLE (FrameNo int PRIMARY KEY, Beta float NOT NULL);
    DECLARE @Slow float = 30, @Fine float = 0.75, @Coarse float = 6;
    DECLARE @beta float = @Amplitude, @dir int = -1, @k int = 0, @beat int = 0, @turned bit;

    WHILE @beat < @Beats
    BEGIN
        SET @turned = 0;
        WHILE @turned = 0
        BEGIN
            INSERT @sched VALUES (@k, ROUND(@beta, 4));
            SET @k += 1;
            SET @beta += @dir * IIF(ABS(@beta) < @Slow, @Fine, @Coarse);
            IF ABS(@beta) >= @Amplitude
            BEGIN
                SET @beta = @dir * @Amplitude;
                SET @dir = -@dir;
                SET @turned = 1;
            END;
        END;
        SET @beat += 1;
    END;
    INSERT @sched VALUES (@k, ROUND(@beta, 4));

    /* ---- start: entry stone locked, fork on its banking, a tooth at 50 deg ---- */
    DECLARE @j int = ROUND((-@Bank - @PhiMin) / @PhiStep, 0),
            @n int = ROUND(2e0 / @ThetaStep, 0);
    WHILE (SELECT Clear FROM esc.WheelFork WHERE I = ((@n + 1) % @NT + @NT) % @NT AND J = @j) = 1
        SET @n += 1;

    DECLARE @push int = -1, @prevFace varchar(7) = 'lock',
            @f int = 0, @frames int = @k + 1,
            @b int, @n0 int, @shoved bit, @jj int, @back int,
            @it int, @moved bit, @code tinyint, @drift int, @next int,
            @phase varchar(10), @stone varchar(5), @face varchar(7), @lastPhase varchar(10) = '';

    WHILE @f < @frames
    BEGIN
        SELECT @beta = Beta FROM @sched WHERE FrameNo = @f;
        SET @b = ROUND((@beta + @BetaMax) / @BetaStep, 0);
        IF @b < 0 OR @b >= @NB SET @b = NULL;            -- jewel too far round to reach the fork
        SELECT @n0 = @n, @shoved = 0;

        /* 1. the jewel shoves the fork to the nearest angle clear of it ... */
        IF @b IS NOT NULL AND (SELECT Clear FROM esc.JewelFork WHERE B = @b AND J = @j) = 0
        BEGIN
            SET @jj = NULL;
            SELECT TOP (1) @jj = jf.J
            FROM esc.JewelFork AS jf
            JOIN esc.ForkPos AS fp ON fp.J = jf.J
            WHERE jf.B = @b AND jf.Clear = 1 AND fp.PinClear = 1
            ORDER BY ABS(jf.J - @j), jf.J;

            IF @jj IS NOT NULL
                SELECT @push = SIGN(@jj - @j), @j = @jj, @shoved = 1;

            /* ... and a stone that lands in a tooth drives the wheel back (recoil) */
            SET @back = 0;
            WHILE @back < 200 AND (SELECT Clear FROM esc.WheelFork WHERE I = (@n % @NT + @NT) % @NT AND J = @j) = 0
                SELECT @n = @n - 1, @back = @back + 1;
        END;

        /* 2. the fork drifts the way the tooth pushes it: back towards its banking
              while the tooth sits on a locking face (draw), onwards while it rides
              an impulse face, until the jewel, a pin or the wheel stops it.
           3. the wheel turns forward until it touches a stone.            repeat. */
        SELECT @it = 0, @moved = 1;
        WHILE @moved = 1 AND @it < 200
        BEGIN
            SELECT @moved = 0, @it = @it + 1;

            SELECT @code = Face FROM esc.WheelFork WHERE I = (@n % @NT + @NT) % @NT AND J = @j;
            SET @drift = CASE @code WHEN 1 THEN -1 WHEN 3 THEN 1 ELSE @push END;
            SET @next = @j + @drift;

            IF @next BETWEEN 0 AND @NP - 1
               AND (SELECT PinClear FROM esc.ForkPos WHERE J = @next) = 1
               AND (@b IS NULL OR (SELECT Clear FROM esc.JewelFork WHERE B = @b AND J = @next) = 1)
               AND (SELECT Clear FROM esc.WheelFork WHERE I = (@n % @NT + @NT) % @NT AND J = @next) = 1
                SELECT @j = @next, @push = @drift, @moved = 1;

            WHILE @n - @n0 < @WheelCap
                  AND (SELECT Clear FROM esc.WheelFork WHERE I = ((@n + 1) % @NT + @NT) % @NT AND J = @j) = 1
                SELECT @n = @n + 1, @moved = 1;
        END;

        /* what is the wheel touching now? that names the phase */
        SELECT @code = Face FROM esc.WheelFork WHERE I = (@n % @NT + @NT) % @NT AND J = @j;
        SELECT @face  = CASE WHEN @code IN (1, 3) THEN 'lock' WHEN @code IN (2, 4) THEN 'impulse' END,
               @stone = CASE WHEN @code IN (1, 2) THEN 'entry' WHEN @code IN (3, 4) THEN 'exit' END;
        SET @phase = CASE WHEN @n < @n0 OR (@shoved = 1 AND @n = @n0) THEN 'unlocking'
                          WHEN @n = @n0                               THEN 'locked'
                          WHEN @face = 'impulse'                      THEN 'impulse'
                          WHEN @face = 'lock' AND @prevFace = 'lock'  THEN 'locked'     -- drawn in to the banking
                          ELSE 'drop' END;
        SET @prevFace = @face;

        INSERT esc.Frame (RunId, FrameNo, Beta, Phi, Theta, Phase, Stone, Face)
        VALUES (@RunId, @f, @beta, @PhiMin + @j * @PhiStep, @n * @ThetaStep, @phase, @stone, @face);

        IF @phase <> @lastPhase
        BEGIN
            SET @msg = CONCAT('frame ', FORMAT(@f, '000'), '  ', LEFT(@phase + '          ', 10),
                              ' balance ', FORMAT(@beta, '0.00;-0.00'), '  fork ', FORMAT(@PhiMin + @j * @PhiStep, '0.0;-0.0'),
                              '  wheel ', FORMAT(@n * @ThetaStep, '0.0'),
                              IIF(@stone IS NULL, '', CONCAT('  (', @stone, ' ', @face, ' face)')));
            RAISERROR(@msg, 0, 1) WITH NOWAIT;
            SET @lastPhase = @phase;
        END;

        SET @f += 1;
    END;

    SET @msg = CONCAT('run ', @RunId, ': ', @frames, ' frames solved  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
    RAISERROR(@msg, 0, 1) WITH NOWAIT;

    /* ---- every frame's shapes, turned to where the run put them ---- */
    IF @Parts = 1
    BEGIN
        DECLARE @Px float, @Py float, @BalX float, @BalY float;
        SELECT @Px = Px, @Py = Py, @BalX = BalX, @BalY = BalY FROM esc.fn_Places();
        DECLARE @wheel   geometry = (SELECT Geom FROM esc.Shape WHERE Part = 'Wheel'),
                @steel   geometry = (SELECT Geom FROM esc.Shape WHERE Part = 'Steel'),
                @entry   geometry = (SELECT Geom FROM esc.Shape WHERE Part = 'EntryStone'),
                @exit    geometry = (SELECT Geom FROM esc.Shape WHERE Part = 'ExitStone'),
                @balance geometry = (SELECT Geom FROM esc.Shape WHERE Part = 'Balance');

        INSERT esc.FramePart (RunId, FrameNo, Part, Geom)
        SELECT f.RunId, f.FrameNo, v.Part, v.Geom
        FROM esc.Frame AS f
        CROSS APPLY (VALUES
            ('Wheel',      dbo.fn_Rotate(@wheel,   f.Theta, 0, 0)),
            ('Fork',       dbo.fn_Rotate(@steel,   f.Phi, @Px, @Py)),
            ('EntryStone', dbo.fn_Rotate(@entry,   f.Phi, @Px, @Py)),
            ('ExitStone',  dbo.fn_Rotate(@exit,    f.Phi, @Px, @Py)),
            ('Balance',    dbo.fn_Rotate(@balance, f.Beta, @BalX, @BalY)),
            ('Jewel',      esc.fn_Jewel(f.Beta)),
            ('Hairspring', esc.fn_Hairspring(f.Beta))
        ) AS v (Part, Geom)
        WHERE f.RunId = @RunId;

        SET @msg = CONCAT('run ', @RunId, ': shapes stored  (', DATEDIFF(millisecond, @t0, SYSDATETIME()), ' ms)');
        RAISERROR(@msg, 0, 1) WITH NOWAIT;
    END;

    UPDATE esc.Run SET Seconds = DATEDIFF(millisecond, @t0, SYSDATETIME()) / 1000e0 WHERE RunId = @RunId;
END;
GO

/* =====================================================================
   MEASURE IT: one row per beat (a beat starts when a locked stone starts
   to be unlocked). Fork angles in deg of fork, wheel angles in deg of wheel.
   ===================================================================== */
CREATE OR ALTER VIEW esc.vBeat
AS
WITH f AS (
    SELECT  fr.*,
            LAG(fr.Phase) OVER (PARTITION BY fr.RunId ORDER BY fr.FrameNo) AS PrevPhase,
            LAG(fr.Theta) OVER (PARTITION BY fr.RunId ORDER BY fr.FrameNo) AS PrevTheta,
            LAG(fr.Phi)   OVER (PARTITION BY fr.RunId ORDER BY fr.FrameNo) AS PrevPhi,
            LAG(fr.Stone) OVER (PARTITION BY fr.RunId ORDER BY fr.FrameNo) AS PrevStone
    FROM esc.Frame AS fr
), s AS (
    SELECT  f.*,
            SUM(IIF(f.Phase = 'unlocking' AND f.PrevPhase = 'locked', 1, 0))
                OVER (PARTITION BY f.RunId ORDER BY f.FrameNo ROWS UNBOUNDED PRECEDING) AS BeatNo
    FROM f
), starts AS (
    SELECT RunId, BeatNo, PrevStone AS Stone, PrevTheta AS Theta0, PrevPhi AS PhiLocked
    FROM s
    WHERE Phase = 'unlocking' AND PrevPhase = 'locked'
)
SELECT  st.RunId, st.BeatNo, st.Stone,
        CAST(ABS(ul.Phi - st.PhiLocked) AS decimal(6, 2))                             AS LockDeg,
        CAST(ABS(im.Phi - ul.Phi) AS decimal(6, 2))                                   AS LiftDeg,
        CAST((SELECT MIN(Theta) FROM s WHERE s.RunId = st.RunId AND s.BeatNo = st.BeatNo
                                          AND s.Phase = 'unlocking') - st.Theta0 AS decimal(6, 2)) AS RecoilDeg,
        CAST((SELECT SUM(Theta - PrevTheta) FROM s WHERE s.RunId = st.RunId AND s.BeatNo = st.BeatNo
                                                     AND s.Phase = 'impulse') AS decimal(6, 2)) AS ImpulseDeg,
        CAST((SELECT SUM(Theta - PrevTheta) FROM s WHERE s.RunId = st.RunId AND s.BeatNo = st.BeatNo
                                                     AND s.Phase = 'drop') AS decimal(6, 2)) AS DropDeg,
        CAST(ld.Theta - st.Theta0 AS decimal(6, 2))                                   AS AdvanceDeg
FROM starts AS st
OUTER APPLY (SELECT TOP (1) Phi FROM s WHERE s.RunId = st.RunId AND s.BeatNo = st.BeatNo
                                         AND s.Phase = 'unlocking' ORDER BY s.FrameNo DESC) AS ul
OUTER APPLY (SELECT TOP (1) Phi FROM s WHERE s.RunId = st.RunId AND s.BeatNo = st.BeatNo
                                         AND s.Phase = 'impulse' ORDER BY s.FrameNo DESC) AS im
OUTER APPLY (SELECT TOP (1) Theta FROM s WHERE s.RunId = st.RunId AND s.BeatNo = st.BeatNo
                                           AND s.Phase = 'locked' AND s.PrevPhase <> 'locked'
             ORDER BY s.FrameNo DESC) AS ld;
GO
