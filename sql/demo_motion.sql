/* =====================================================================
   The Watchmaker  —  demo_motion.sql
   A guided tour of episode 4, the motion works. Run a section at a time in
   SSMS; keep the Messages tab open, and the Spatial results tab for shapes.
   ===================================================================== */
USE Watchmaker;
GO

/* 1. The only numbers: tooth counts, modules, and which way each mesh points */
SELECT * FROM motion.Mesh;
GO

/* 2. Build the teeth, every pose, ~14,000 STIntersects, and the push edges
      (~80 s; most of it is turning the driven wheels with fn_Affine) */
EXEC motion.usp_BuildMaps;
GO

/* 3. Does the hour wheel come back round onto the centre arbor? Two meshes,
      two modules, one centre distance. */
SELECT * FROM motion.vCoaxial;
GO

/* 4. Both levels in the Spatial results tab, at rest */
SELECT s.MeshNo, s.Part, dbo.fn_Place(s.Geom, 0, a.X, a.Y, 1) AS Geom
FROM motion.Shape AS s
JOIN motion.Mesh AS m ON m.MeshNo = s.MeshNo
JOIN motion.Arbor AS a ON a.Arbor = IIF(s.Part = 'DriverDisplay', m.DriverArbor, m.DrivenArbor)
WHERE s.Part IN ('DriverDisplay', 'DrivenDisplay');
GO

/* 5. What the teeth did: a third, a quarter, and dead steady - full
      cycloids on both gears */
SELECT * FROM motion.vMesh;
GO

/* 6. Twelve hours, set-based: the minute hand once an hour, the hour hand
      read through both meshes */
DECLARE @r int;
EXEC motion.usp_Run @Hours = 12, @Frames = 361, @Parts = 0, @RunId = @r OUTPUT;
SELECT (MIN(CentreDeg) - MAX(CentreDeg)) / (MIN(HourDeg) - MAX(HourDeg)) AS MinuteTurnsPerHourTurn
FROM motion.Frame WHERE RunId = @r;
GO
