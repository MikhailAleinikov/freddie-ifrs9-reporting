-- 40_reports.sql
-- Reporting marts on top of the risk layer:
--   mart.reporting_dates     reporting date (latest quarter-end) and comparison date (previous quarter-end)
--   mart.rpt_ifrs9_stage     loans, gross carrying amount (EAD), ECL and coverage per quarter-end and stage
--   mart.rpt_stage_migration stage transfers between comparison and reporting date (incl. new / derecognised)
--   mart.rpt_f18_npe         FINREP F 18-style performing / non-performing breakdown at the reporting date
--   mart.rpt_pd_grade        master scale with the reporting-date book per grade
--   mart.rpt_vintage_curves  cumulative 12m-definition default rate by vintage and months since first payment
-- Gross carrying amount is approximated by EAD (current UPB); accumulated impairment by ECL.
-- Depends on: mart.ecl, mart.stage, mart.pd_grade, core.default_event, core.orig, core.perf
-- Run from the repo root:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/40_reporting/40_reports.sql

BEGIN;

-- 1. Reporting dates
DROP TABLE IF EXISTS mart.reporting_dates CASCADE;
CREATE TABLE mart.reporting_dates AS
WITH d AS (
    SELECT DISTINCT snapshot_date FROM mart.ecl ORDER BY snapshot_date DESC LIMIT 2
)
SELECT max(snapshot_date) AS reporting_date,
       min(snapshot_date) AS comparison_date
FROM d;

-- 2. Stage summary over time
DROP TABLE IF EXISTS mart.rpt_ifrs9_stage CASCADE;
CREATE TABLE mart.rpt_ifrs9_stage AS
SELECT snapshot_date,
       stage,
       count(*)                               AS loans,
       sum(ead)                               AS gross_carrying_amount,
       sum(ecl)                               AS ecl,
       sum(ecl) / NULLIF(sum(ead), 0)         AS coverage
FROM mart.ecl
GROUP BY snapshot_date, stage;

ALTER TABLE mart.rpt_ifrs9_stage ADD PRIMARY KEY (snapshot_date, stage);

-- 3. Stage migration: comparison date -> reporting date
DROP TABLE IF EXISTS mart.rpt_stage_migration CASCADE;
CREATE TABLE mart.rpt_stage_migration AS
WITH a AS (
    SELECT e.loan_seq_no, e.stage, e.ead
    FROM mart.ecl e, mart.reporting_dates r
    WHERE e.snapshot_date = r.comparison_date
),
b AS (
    SELECT e.loan_seq_no, e.stage, e.ead
    FROM mart.ecl e, mart.reporting_dates r
    WHERE e.snapshot_date = r.reporting_date
)
SELECT COALESCE('Stage ' || a.stage, 'New')                AS from_stage,
       COALESCE('Stage ' || b.stage, 'Derecognised')       AS to_stage,
       count(*)                                            AS loans,
       sum(COALESCE(b.ead, a.ead))                         AS ead
FROM a
FULL JOIN b USING (loan_seq_no)
GROUP BY 1, 2;

-- 4. FINREP F 18-style breakdown at the reporting date
DROP TABLE IF EXISTS mart.rpt_f18_npe CASCADE;
CREATE TABLE mart.rpt_f18_npe AS
WITH x AS (
    SELECT s.dpd_months,
           s.is_npe,
           e.ead,
           e.ecl
    FROM mart.stage s
    JOIN mart.ecl e USING (loan_seq_no, snapshot_date)
    JOIN mart.reporting_dates r ON s.snapshot_date = r.reporting_date
),
b AS (
    SELECT CASE
               WHEN NOT is_npe AND dpd_months = 0  THEN '1 Performing: not past due or <= 30 days'
               WHEN NOT is_npe                     THEN '2 Performing: past due > 30 <= 90 days'
               WHEN dpd_months < 3                 THEN '3 Non-performing: unlikely to pay, <= 90 days'
               WHEN dpd_months < 6                 THEN '4 Non-performing: past due > 90 <= 180 days'
               WHEN dpd_months < 12                THEN '5 Non-performing: past due > 180 days <= 1 year'
               ELSE                                     '6 Non-performing: past due > 1 year'
           END AS category,
           ead, ecl
    FROM x
)
SELECT category,
       count(*)                       AS loans,
       sum(ead)                       AS gross_carrying_amount,
       sum(ecl)                       AS accumulated_impairment,
       sum(ecl) / NULLIF(sum(ead), 0) AS coverage
FROM b
GROUP BY category
ORDER BY category;

-- 5. Master scale with the reporting-date book
DROP TABLE IF EXISTS mart.rpt_pd_grade CASCADE;
CREATE TABLE mart.rpt_pd_grade AS
SELECT g.grade,
       g.score_lo,
       g.score_hi,
       g.dr_train,
       g.dr_oot,
       g.pd_ttc,
       g.pd_pit,
       count(s.loan_seq_no) AS loans_reporting_date,
       sum(s.ead)           AS ead_reporting_date
FROM mart.pd_grade g
LEFT JOIN mart.stage s
  ON s.grade = g.grade
 AND s.snapshot_date = (SELECT reporting_date FROM mart.reporting_dates)
GROUP BY g.grade, g.score_lo, g.score_hi, g.dr_train, g.dr_oot, g.pd_ttc, g.pd_pit
ORDER BY g.grade;

-- 6. Vintage curves: cumulative share of loans defaulted by months since first payment
DROP TABLE IF EXISTS mart.rpt_vintage_curves CASCADE;
CREATE TABLE mart.rpt_vintage_curves AS
WITH data_end AS (
    SELECT max(period) AS d FROM core.perf
),
loans AS (
    SELECT o.vintage,
           count(*)                                    AS n_loans,
           max(o.first_payment_date)                   AS last_first_payment
    FROM core.orig o
    GROUP BY o.vintage
),
defaults AS (
    SELECT o.vintage,
           (extract(year  FROM age(de.default_date, o.first_payment_date)) * 12
          + extract(month FROM age(de.default_date, o.first_payment_date)))::int AS mob
    FROM core.default_event de
    JOIN core.orig o USING (loan_seq_no)
),
grid AS (   -- months on book observable for every loan of the vintage
    SELECT l.vintage, l.n_loans, m.mob
    FROM loans l
    CROSS JOIN data_end e
    CROSS JOIN LATERAL generate_series(0, 240, 3) AS m(mob)
    WHERE m.mob <= (extract(year  FROM age(e.d, l.last_first_payment)) * 12
                  + extract(month FROM age(e.d, l.last_first_payment)))
)
SELECT g.vintage,
       g.mob                                                     AS months_on_book,
       g.n_loans,
       count(d.mob)                                              AS cum_defaults,
       count(d.mob)::double precision / g.n_loans                AS cum_default_rate
FROM grid g
LEFT JOIN defaults d
  ON d.vintage = g.vintage AND d.mob <= g.mob
GROUP BY g.vintage, g.mob, g.n_loans
ORDER BY g.vintage, g.mob;

COMMIT;

-- Report 1: reporting dates
SELECT * FROM mart.reporting_dates;

-- Report 2: stage migration matrix by loans
SELECT from_stage,
       sum(loans) FILTER (WHERE to_stage = 'Stage 1')      AS to_stage1,
       sum(loans) FILTER (WHERE to_stage = 'Stage 2')      AS to_stage2,
       sum(loans) FILTER (WHERE to_stage = 'Stage 3')      AS to_stage3,
       sum(loans) FILTER (WHERE to_stage = 'Derecognised') AS derecognised
FROM mart.rpt_stage_migration
GROUP BY from_stage
ORDER BY from_stage;

-- Report 3: F 18-style table
SELECT category,
       loans,
       round((gross_carrying_amount / 1e6)::numeric, 1)  AS gca_mn,
       round((accumulated_impairment / 1e6)::numeric, 2) AS impairment_mn,
       round((100 * coverage)::numeric, 2)               AS coverage_pct
FROM mart.rpt_f18_npe
ORDER BY category;

-- Report 4: NPE ratio at the reporting date
SELECT round((100 * sum(gross_carrying_amount) FILTER (WHERE category LIKE '_ Non-performing%')
             / sum(gross_carrying_amount))::numeric, 2) AS npe_ratio_pct
FROM mart.rpt_f18_npe;