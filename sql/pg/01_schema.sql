/* =====================================================================
   The Watchmaker, Part 2  —  pg/01_schema.sql
   PostgreSQL 18 + PostGIS 3.6. The whole movement, in three dimensions.

   One frame for everything, the same as Part 1's drawings:
     x, y   seen from the dial: 12 o'clock is +y, the crown is at +x
     z      out of the dial (right-handed)
   The mainplate fills z 0 .. 1.2. The going train, the barrel and the
   bridges are behind it, at negative z (the back of the watch); the motion
   works, the dial and the hands are in front, at z > 1.2. Units: mm.

   Every part is a set of pieces. A piece is a prism: a 2D profile slid
   along the part's axis from z0 to z1. That is how a watch part is made
   (cut from flat stock), and it keeps every 3D question honest: the
   database builds the solid, places it and tests it.
   ===================================================================== */
CREATE EXTENSION IF NOT EXISTS postgis;

DROP SCHEMA IF EXISTS movement CASCADE;
CREATE SCHEMA movement;

/* Tooth forms, in modules (the same numbers as Part 1) */
CREATE TABLE movement.form
(
    kind      text PRIMARY KEY,       -- wheel | leaf | motion
    s         float8 NOT NULL,        -- thickness on the pitch circle
    ha        float8,                 -- addendum
    hf        float8 NOT NULL,        -- dedendum
    flank_pts int,                    -- points per addendum flank (display quality)
    tip_step  int                     -- deg between points on a leaf's round tip
);
INSERT INTO movement.form VALUES
    ('wheel',  1.50, 1.40, 1.60, 6, NULL),
    ('leaf',   1.20, NULL, 1.65, NULL, 20),
    ('motion', 1.40, 1.40, 1.65, 6, NULL);

/* Part 1's escapement, in its own units (escape wheel tip radius R = 10),
   and how big it is in this watch */
CREATE TABLE movement.esc_spec
(
    id         int PRIMARY KEY CHECK (id = 1),
    r          float8, rr float8, teeth int, club_rise float8, lever float8,
    rj         float8, jewel_r float8, lock_deg float8, lift_deg float8, draw_deg float8,
    bank_deg   float8, stone_w float8, entry_lock float8, exit_lock float8,
    scale      float8,                -- mm per escapement unit
    theta0     float8,                -- the rest pose Part 1 started from:
    phi0       float8,                --   wheel, fork and balance angles (deg)
    beta0      float8
);
INSERT INTO movement.esc_spec VALUES
    (1, 10.0, 7.2, 15, 0.20, 13.0, 3.0, 0.35, 1.0, 6.0, 12.0, 6.0, 7.0, 56.5, 116.5,
     0.22, 8.6, -6.0, 110.0);

/* Where the arbors are: each one a bearing and a distance from another.
   The distances are not typed in: they come from the teeth (m (z1 + z2) / 2)
   or from the escapement's own geometry. */
CREATE TABLE movement.arbor
(
    arbor      text PRIMARY KEY,
    from_arbor text REFERENCES movement.arbor,
    bearing    float8,               -- deg, anticlockwise from +x, seen from the dial
    distance   float8,
    x          float8,
    y          float8
);

/* Other places: screw holes, bridge feet. Also a bearing and a distance
   from an arbor. */
CREATE TABLE movement.spot
(
    spot       text PRIMARY KEY,
    from_arbor text NOT NULL REFERENCES movement.arbor,
    bearing    float8 NOT NULL,
    distance   float8 NOT NULL,
    x          float8,
    y          float8
);

/* Pivot radius of each arbor's ends; the jewel holes are 0.01 bigger */
CREATE TABLE movement.pivot
(
    arbor      text PRIMARY KEY REFERENCES movement.arbor,
    r          float8 NOT NULL
);

CREATE TABLE movement.setting
(
    name       text PRIMARY KEY,
    value      float8 NOT NULL
);

/* The gear pairs. `moves` says which side is turned to find a clear rest
   angle, in `seq` order, starting from the escapement's pose. */
CREATE TABLE movement.mesh
(
    mesh_no      int PRIMARY KEY,
    driver_arbor text NOT NULL REFERENCES movement.arbor,
    driver_part  text NOT NULL,
    driver_piece text NOT NULL,
    driver_teeth int  NOT NULL,
    driven_arbor text NOT NULL REFERENCES movement.arbor,
    driven_part  text NOT NULL,
    driven_piece text NOT NULL,
    driven_teeth int  NOT NULL,
    module       float8 NOT NULL,
    moves        text NOT NULL CHECK (moves IN ('driver', 'driven')),
    seq          int  NOT NULL,
    driver_kind  text NOT NULL,      -- tooth form: wheel | leaf | motion
    driven_kind  text NOT NULL
);

CREATE TABLE movement.part
(
    part      text PRIMARY KEY,
    arbor     text REFERENCES movement.arbor,   -- turns about this arbor (NULL: built where it sits)
    phase     float8 NOT NULL DEFAULT 0,        -- its rest angle about the arbor, deg
    axis      char(1) NOT NULL DEFAULT 'z' CHECK (axis IN ('z', 'x')),   -- the direction it slides along
    is_base   boolean NOT NULL DEFAULT false    -- the mainplate: everything is taken off it
);

CREATE TABLE movement.piece
(
    part      text NOT NULL REFERENCES movement.part ON DELETE CASCADE,
    piece     text NOT NULL,
    material  text NOT NULL,
    profile   geometry NOT NULL,     -- 2D, built about the part's arbor (or in place)
    z0        float8 NOT NULL,       -- along the axis
    z1        float8 NOT NULL CHECK (z1 > z0),
    world     geometry,              -- the profile where it really is: x y for axis z, y z for axis x
    mesh      geometry,              -- the solid's surface: TIN Z, in the watch's frame
    PRIMARY KEY (part, piece)
);

/* The order the watch comes apart in, worked out by sliding parts out */
CREATE TABLE movement.removal
(
    part      text PRIMARY KEY REFERENCES movement.part ON DELETE CASCADE,
    round     int NOT NULL,          -- 1 = first off
    dx        float8 NOT NULL,       -- the way it leaves
    dy        float8 NOT NULL,
    dz        float8 NOT NULL,
    level     int                    -- how many layers out it sits in the exploded view
);
