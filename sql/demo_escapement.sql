/* =====================================================================
   The Watchmaker  —  demo_escapement.sql
   A guided tour of episode 1. Run a section at a time in SSMS; keep the
   Messages tab open, and the Spatial results tab for the SELECTs of shapes.
   ===================================================================== */
USE Watchmaker;
GO

/* 1. The parts, at rest. Spatial results tab: wheel, fork, stones, pins, balance. */
SELECT Part, Geom FROM esc.Shape WHERE Part <> 'WheelContact';
GO

/* 2. The physics, asked once: ~97,000 STIntersects, about six seconds.
      Watch the Messages tab. */
EXEC esc.usp_BuildMaps;
GO

/* 3. The escapement's whole personality in one table: for every wheel angle
      within a tooth (I, 0.1 deg) and fork angle (J, 0.1 deg), is it clear?
      The free region is a narrow, slanted channel. */
SELECT  CAST(w.Theta AS decimal(4, 1)) AS WheelDeg,
        COUNT(*)                        AS ForkAngles,
        SUM(CAST(wf.Clear AS int))      AS Clear,
        SUM(IIF(wf.Face IN (1, 3), 1, 0)) AS OnALockingFace,
        SUM(IIF(wf.Face IN (2, 4), 1, 0)) AS OnAnImpulseFace
FROM esc.WheelFork AS wf
JOIN esc.WheelPos  AS w ON w.I = wf.I
GROUP BY w.Theta
ORDER BY w.Theta;
GO

/* 4. Run it: the balance is driven back and forth; the fork and wheel go
      wherever the maps let them. Messages tab: every change of phase. */
DECLARE @r int;
EXEC esc.usp_Run @Amplitude = 110, @Beats = 4, @RunId = @r OUTPUT;

/* 5. ... and the database measures its own escapement */
SELECT * FROM esc.vBeat WHERE RunId = @r ORDER BY BeatNo;

/* 6. One frame of it in the Spatial results tab (frame 55: mid-impulse) */
SELECT Part, Geom FROM esc.FramePart WHERE RunId = @r AND FrameNo = 55
UNION ALL
SELECT Part, Geom FROM esc.Shape WHERE Part IN ('BankingPins', 'Roller');
GO

/* 7. Try it: a shallower lock. Change one number, rebuild, run, measure. */
-- UPDATE esc.Spec SET LockDeg = 2.0;      -- default 1.0: higher stone = less lock
-- EXEC esc.usp_BuildMaps;
-- DECLARE @r int; EXEC esc.usp_Run @Parts = 0, @RunId = @r OUTPUT;
-- SELECT * FROM esc.vBeat WHERE RunId = @r;
-- UPDATE esc.Spec SET LockDeg = 1.0; EXEC esc.usp_BuildMaps;
