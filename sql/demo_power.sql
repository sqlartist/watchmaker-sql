/* =====================================================================
   The Watchmaker  —  demo_power.sql
   A guided tour of episode 3, power. Run a section at a time in SSMS; keep
   the Messages tab open, and the Spatial results tab for shapes.
   ===================================================================== */
USE Watchmaker;
GO

/* 1. The ratchet and the click, at rest (Spatial results tab) */
EXEC power.usp_BuildClick;            -- 36,100 STIntersects, about a second
SELECT Part, Geom FROM power.Shape WHERE Part IN ('Ratchet', 'Pawl');
GO

/* 2. Wind five teeth, hold, let go. Messages: how far it slipped back before
      the click caught it. Nothing in the procedure says "one way". */
DECLARE @r int;
EXEC power.usp_Click @Forward = 200, @Hold = 30, @Back = 160, @RunId = @r OUTPUT;
SELECT Event, COUNT(*) AS Steps, MIN(RatchetDeg) AS FromDeg, MAX(RatchetDeg) AS ToDeg
FROM power.ClickFrame WHERE RunId = @r GROUP BY Event ORDER BY MIN(FrameNo);
GO

/* 3. A whole turn of winding: count the clicks */
DECLARE @r int;
EXEC power.usp_Click @Forward = 3600, @Hold = 0, @Back = 160, @RunId = @r OUTPUT;
SELECT * FROM power.vClick WHERE RunId = @r;          -- a click every 10 deg: 36 a turn
GO

/* 4. How far can a barrel turn? Pack the spring tight on the arbor, then
      against the wall; measure each with STLength. Best at half full. */
EXEC power.usp_Fill;                   -- 25 lengths, ~12 s
SELECT LengthMm, CAST(WoundTurns AS decimal(6, 2)) AS Wound, CAST(LetDownTurns AS decimal(6, 2)) AS LetDown,
       CAST(BarrelTurns AS decimal(6, 2)) AS BarrelTurns, CAST(FilledPct AS decimal(5, 1)) AS FilledPct
FROM power.Fill ORDER BY BarrelTurns DESC;
GO

/* 5. Wind it up and let it run down. The power reserve comes out at the end. */
DECLARE @r int;
EXEC power.usp_Spring @Frames = 120, @Parts = 0, @RunId = @r OUTPUT;

/* 6. The spring in the Spatial results tab: let down, half wound, wound */
SELECT FrameNo, Phase, CAST(Hours AS decimal(5, 1)) AS Hours, power.fn_SpringLine(ArborDeg, Wound) AS Spring
FROM power.SpringFrame WHERE RunId = @r AND FrameNo IN (0, 60, 120);
GO
