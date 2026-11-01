/* =====================================================================
   The Watchmaker  —  01_schema.sql
   Part 1: the core principles of a mechanical watch, in SQL Server 2025
   geometry. Episode 1 is the Swiss lever escapement.

   Everything physical is a 2D shape in the drawing plane (units: escape
   wheel tip radius = 10). The physics is one spatial question — does this
   shape touch that one? — asked once for every pose on a grid and stored.
   After that, running the watch is a relational search over those maps.
   ===================================================================== */
IF DB_ID('Watchmaker') IS NULL
    CREATE DATABASE Watchmaker;
GO
USE Watchmaker;
GO
ALTER DATABASE CURRENT SET COMPATIBILITY_LEVEL = 170;
GO
IF SCHEMA_ID('esc') IS NULL EXEC ('CREATE SCHEMA esc');
GO

DROP TABLE IF EXISTS esc.FramePart, esc.Frame, esc.Run,
                     esc.JewelFork, esc.WheelFork, esc.JewelPos, esc.ForkPos, esc.WheelPos,
                     esc.Shape, esc.Spec;
GO

/* One row of dimensions. Change a number, rebuild the maps, run it again. */
CREATE TABLE esc.Spec
(
    Id          tinyint PRIMARY KEY CHECK (Id = 1),
    R           float NOT NULL,     -- escape wheel tip radius (the heel of each club)
    RR          float NOT NULL,     -- root radius
    Teeth       int   NOT NULL,     -- 15 -> a 24 deg pitch
    ClubRise    float NOT NULL,     -- club slopes up from locking corner (R - ClubRise) to heel (R)
    Lever       float NOT NULL,     -- pallet arbor -> balance staff
    RJ          float NOT NULL,     -- roller jewel (impulse pin) radius from the staff
    JewelR      float NOT NULL,
    LockDeg     float NOT NULL,     -- stone's locking corner sits this many deg of fork above R at neutral
    LiftDeg     float NOT NULL,     -- rise of a stone's impulse face, in deg of fork
    DrawDeg     float NOT NULL,     -- locking face leans forward so a tooth pulls the stone in
    BankDeg     float NOT NULL,     -- banking pins stop the fork at +/- this
    StoneW      float NOT NULL,     -- stone width, deg of wheel
    EntryLock   float NOT NULL,     -- angle about the wheel of the entry stone's locking corner
    ExitLock    float NOT NULL,     -- ... and the exit stone's: 2.5 teeth further on
    -- grids
    ThetaStep   float NOT NULL,     -- wheel, over one pitch
    PhiStep     float NOT NULL,     -- fork
    PhiMin      float NOT NULL,
    PhiMax      float NOT NULL,
    BetaStep    float NOT NULL,     -- balance
    BetaMax     float NOT NULL      -- beyond this the jewel can't reach the fork
);

/* Base shapes, each in its rest position. Poses are rotations of these. */
CREATE TABLE esc.Shape
(
    Part        varchar(20) PRIMARY KEY,
    Geom        geometry NOT NULL
);

/* ---------------------------------------------------------------------
   The grids: every pose each moving part can take, as geometry
   --------------------------------------------------------------------- */
CREATE TABLE esc.WheelPos               -- escape wheel (contact zone only), 0 .. 24 deg
(
    I           int PRIMARY KEY,
    Theta       float NOT NULL,
    Geom        geometry NOT NULL
);

CREATE TABLE esc.ForkPos                -- pallet fork, -8 .. +8 deg
(
    J           int PRIMARY KEY,
    Phi         float NOT NULL,
    Geom        geometry NOT NULL,      -- steel + both stones: what the wheel can hit
    LeverGeom   geometry NOT NULL,      -- what the jewel can hit
    EntryLockFace    geometry NOT NULL, -- the four working faces, as lines
    EntryImpulseFace geometry NOT NULL,
    ExitLockFace     geometry NOT NULL,
    ExitImpulseFace  geometry NOT NULL,
    PinClear    bit NOT NULL            -- 1 = clear of both banking pins
);

CREATE TABLE esc.JewelPos               -- impulse jewel, -45 .. +45 deg of balance
(
    B           int PRIMARY KEY,
    Beta        float NOT NULL,
    Geom        geometry NOT NULL
);

/* ---------------------------------------------------------------------
   The maps: the physics, asked once
   --------------------------------------------------------------------- */
CREATE TABLE esc.WheelFork              -- the escapement's configuration space
(
    I           int NOT NULL,
    J           int NOT NULL,
    Clear       bit NOT NULL,           -- wheel at I and fork at J don't touch
    Face        tinyint NOT NULL,       -- face the wheel would hit one step on:
                                        -- 0 none, 1 entry lock, 2 entry impulse, 3 exit lock, 4 exit impulse
    CONSTRAINT PK_WheelFork PRIMARY KEY (I, J)
);

CREATE TABLE esc.JewelFork
(
    B           int NOT NULL,
    J           int NOT NULL,
    Clear       bit NOT NULL,
    CONSTRAINT PK_JewelFork PRIMARY KEY (B, J)
);

/* ---------------------------------------------------------------------
   Runs: the balance is driven, everything else goes where the metal lets it
   --------------------------------------------------------------------- */
CREATE TABLE esc.Run
(
    RunId       int IDENTITY PRIMARY KEY,
    Started     datetime2(3) NOT NULL DEFAULT SYSDATETIME(),
    Amplitude   float NOT NULL,
    Beats       int NOT NULL,
    WheelCap    int NOT NULL,
    Seconds     float NULL               -- how long the run took to compute
);

CREATE TABLE esc.Frame
(
    RunId       int NOT NULL REFERENCES esc.Run(RunId),
    FrameNo     int NOT NULL,
    Beta        float NOT NULL,          -- balance, deg
    Phi         float NOT NULL,          -- fork, deg
    Theta       float NOT NULL,          -- wheel, deg (unbounded: it keeps going round)
    Phase       varchar(10) NOT NULL,    -- locked | unlocking | impulse | drop
    Stone       varchar(5) NULL,         -- entry | exit (what the wheel is touching)
    Face        varchar(7) NULL,         -- lock | impulse
    CONSTRAINT PK_Frame PRIMARY KEY (RunId, FrameNo)
);

CREATE TABLE esc.FramePart
(
    RunId       int NOT NULL,
    FrameNo     int NOT NULL,
    Part        varchar(20) NOT NULL,    -- Wheel | Fork | EntryStone | ExitStone | Balance | Jewel | Hairspring
    Geom        geometry NOT NULL,
    CONSTRAINT PK_FramePart PRIMARY KEY (RunId, FrameNo, Part),
    CONSTRAINT FK_FramePart_Frame FOREIGN KEY (RunId, FrameNo) REFERENCES esc.Frame(RunId, FrameNo)
);
GO

INSERT esc.Spec
    (Id, R, RR, Teeth, ClubRise, Lever, RJ, JewelR, LockDeg, LiftDeg, DrawDeg, BankDeg, StoneW,
     EntryLock, ExitLock, ThetaStep, PhiStep, PhiMin, PhiMax, BetaStep, BetaMax)
VALUES
    (1, 10.0, 7.2, 15, 0.2, 13.0, 3.0, 0.35, 1.0, 6.0, 12.0, 6.0, 7.0,
     56.5, 116.5, 0.1, 0.1, -8.0, 8.0, 0.25, 45.0);
GO
