-- 000_setup.sql
-- Run ONCE, as superuser, with psql (not PyCharm, because \c is psql-only):
--   psql -h localhost -d postgres -f sql/000_setup.sql
-- Then set the password interactively:  \password mikhail

CREATE ROLE mikhail LOGIN;
CREATE DATABASE freddie OWNER mikhail;
\c freddie mikhail
CREATE SCHEMA raw;
CREATE SCHEMA core;
CREATE SCHEMA mart;