/* The Watchmaker, Part 2: build the whole movement from nothing, and run it for a minute.

     cd sql/pg
     psql -h localhost -p 5432 -U postgres -d watchmaker -f build.sql
*/
\set ON_ERROR_STOP 1
\timing on
\i 01_schema.sql
\i 02_profiles.sql
\i 03_calibre.sql
\i 04_solids.sql
\i 05_take_apart.sql
\i 06_laws.sql
\i 07_escapement.sql
\i 08_run.sql
