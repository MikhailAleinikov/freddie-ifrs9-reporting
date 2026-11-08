-- 41_ecl_cube.sql
-- Tableau source: ECL cube at quarter-end x stage x stage reason x grade x vintage.
-- Small enough to export and publish (aggregated, no loan-level data), detailed enough to slice in Tableau.
-- Depends on: mart.ecl, mart.stage, core.orig
-- Run from the repo root:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/40_reporting/41_ecl_cube.sql

BEGIN;

DROP TABLE IF EXISTS mart.rpt_ecl_cube CASCADE;
CREATE TABLE mart.rpt_ecl_cube AS
SELECT e.snapshot_date,
       e.stage,
       s.stage_reason,
       s.grade,
       o.vintage,
       count(*)              AS loans,
       sum(e.ead)            AS gross_carrying_amount,
       sum(e.ecl)            AS ecl,
       sum(e.pd_12m * e.ead) AS pd_12m_x_ead,
       sum(e.lgd * e.ead)    AS lgd_x_ead
FROM mart.ecl e
JOIN mart.stage s USING (loan_seq_no, snapshot_date)
JOIN core.orig o USING (loan_seq_no)
GROUP BY e.snapshot_date, e.stage, s.stage_reason, s.grade, o.vintage;

COMMIT;

SELECT count(*) AS cube_rows,
       round((sum(ecl) / 1e6)::numeric, 1) AS ecl_mn_all_dates
FROM mart.rpt_ecl_cube;
