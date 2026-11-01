/* =====================================================================
   The Watchmaker  —  demo_train.sql
   A guided tour of episode 2, the going train. Run a section at a time in
   SSMS; keep the Messages tab open, and the Spatial results tab for shapes.
   ===================================================================== */
USE Watchmaker;
GO

/* 1. The only numbers: tooth counts, modules, and which way each pinion lies */
SELECT * FROM train.Mesh;
GO

/* 2. Build the teeth, every pose, ~43,000 STIntersects, and home in on the
      push edges (~1 minute; most of it is turning pinions with fn_Affine).
      The arbors' positions come out of the teeth too: m (z + n) / 2. */
EXEC train.usp_BuildMaps;
SELECT * FROM train.Arbor;
GO

/* 3. One mesh in the Spatial results tab: the centre wheel near the third
      pinion, at one wheel step, with the pinion where the push edge puts it */
SELECT 'wheel' AS Part, w.Geom
FROM train.WheelPose AS w WHERE w.MeshNo = 1 AND w.Profile = 'cycloidal' AND w.I = 20
UNION ALL
SELECT 'pinion', dbo.fn_Place(s.Geom, a.Spin * e.Hi, a.X, a.Y, 1)
FROM train.Edge AS e
JOIN train.Shape AS s ON s.MeshNo = 1 AND s.Part = 'Pinion'
JOIN train.Arbor AS a ON a.Arbor = 'third'
WHERE e.MeshNo = 1 AND e.Profile = 'cycloidal' AND e.I = 20;
GO

/* 4. What the teeth did. Nobody typed 8, 7.5 or 10. Cycloidal teeth: a
      steady ratio and constant backlash. Straight teeth: the pinion lurches,
      and the 8-leaf escape pinion jams. */
SELECT * FROM train.vMesh ORDER BY MeshNo, Profile;
GO

/* 5. One minute of the watch: centre arbor at 0.1 deg a second, the rest
      read through the push edges - three CROSS APPLYs, no loop */
DECLARE @r int;
EXEC train.usp_Run @Profile = 'cycloidal', @Seconds = 60, @Frames = 361, @Parts = 0, @RunId = @r OUTPUT;

SELECT  (MAX(FourthDeg) - MIN(FourthDeg)) / (MAX(CentreDeg) - MIN(CentreDeg)) AS FourthPerCentre,   -- the seconds
        (MAX(EscapeDeg) - MIN(EscapeDeg)) / (MAX(CentreDeg) - MIN(CentreDeg)) AS EscapePerCentre,
        MAX(FourthDeg) - MIN(FourthDeg)                                       AS SecondsHandDeg
FROM train.Frame WHERE RunId = @r;
GO

/* 6. Try it: the straight-toothed train refuses to run */
-- EXEC train.usp_Run @Profile = 'straight';
