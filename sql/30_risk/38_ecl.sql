-- 38_ecl.sql
-- IFRS 9 expected credit loss per loan and quarter-end >> mart.ecl (+ mart.ecl_params)
--   Stage 1: 12-month ECL   = PD12 x LGD x EAD x DF(0.5y)
--   Stage 2: lifetime ECL   = sum over remaining years t=1..T of  S(t-1) x PD12 x LGD x EAD x DF(t-0.5)
--            with survival S(t) = [(1 - PD12) x (1 - CPR)]^t  (survive default AND prepayment)
--            closed form: PD12 x LGD x EAD x DF(0.5) x (1 - (s*d)^T) / (1 - s*d),  s = (1-PD12)(1-CPR), d = 1/(1+r)
--   Stage 3: ECL            = LGD x EAD (PD = 1)
-- Simplifications (see assumptions): constant annual PD over the lifetime, no amortisation of EAD,
--   one portfolio-wide prepayment rate (CPR) from the last 8 observable quarter-ends,
--   discounting at the loan's original note rate, remaining life capped at 30 years.
-- LGD by original-LTV band from mart.lgd_table ('ALL' row as fallback).
-- Depends on: mart.stage, core.snapshot, core.orig, core.perf, mart.lgd_table
-- Run from the repo root:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/30_risk/38_ecl.sql

BEGIN;

SET LOCAL work_mem = '256MB';

-- 1. Annual voluntary prepayment rate: share of active loans paying off in full (ZB 01) within 12 months
DROP TABLE IF EXISTS mart.ecl_params CASCADE;
CREATE TABLE mart.ecl_params AS
WITH prepay AS (
    SELECT loan_seq_no, min(period) AS prepay_date
    FROM core.perf
    WHERE zero_balance_code = '01'
    GROUP BY loan_seq_no
),
recent AS (
    SELECT DISTINCT snapshot_date
    FROM core.snapshot
    WHERE target_observable
    ORDER BY snapshot_date DESC
    LIMIT 8
)
SELECT avg(COALESCE(p.prepay_date >  s.snapshot_date
                 AND p.prepay_date <= s.snapshot_date + interval '12 months', false)::int)::double precision AS cpr,
       min(s.snapshot_date) AS cpr_window_from,
       max(s.snapshot_date) AS cpr_window_to
FROM core.snapshot s
LEFT JOIN prepay p USING (loan_seq_no)
WHERE s.snapshot_date IN (SELECT snapshot_date FROM recent);

-- 2. ECL per loan and quarter-end
DROP TABLE IF EXISTS mart.ecl CASCADE;
CREATE TABLE mart.ecl AS
WITH base AS (
    SELECT st.loan_seq_no,
           st.snapshot_date,
           st.stage,
           COALESCE(st.ead, 0)                                       AS ead,
           st.pd_12m,
           COALESCE(l.lgd, la.lgd)                                   AS lgd,
           o.orig_interest_rate / 100                                AS r,
           least(30, greatest(1, ceil(
               ((extract(year  FROM age(o.maturity_date, st.snapshot_date)) * 12
               + extract(month FROM age(o.maturity_date, st.snapshot_date))) / 12.0)::numeric
           )))::int                                                  AS years_left,
           ep.cpr
    FROM mart.stage st
    JOIN core.orig o USING (loan_seq_no)
    CROSS JOIN mart.ecl_params ep
    LEFT JOIN mart.lgd_table l
      ON l.ltv_band = CASE WHEN o.orig_ltv IS NULL OR o.orig_ltv BETWEEN 61 AND 80 THEN '61-80'
                           WHEN o.orig_ltv <= 60 THEN '<=60'
                           ELSE '81+' END
    LEFT JOIN mart.lgd_table la ON la.ltv_band = 'ALL'
),
f AS (
    SELECT b.*,
           1 / (1 + b.r)                                 AS d,
           (1 - b.pd_12m) * (1 - b.cpr)                  AS s
    FROM base b
)
SELECT f.loan_seq_no,
       f.snapshot_date,
       f.stage,
       f.ead,
       CASE WHEN f.stage = 3 THEN 1 ELSE f.pd_12m END                AS pd_12m,
       CASE WHEN f.stage = 3 THEN 1
            ELSE f.pd_12m * (1 - power(f.s, f.years_left)) / (1 - f.s)
       END                                                           AS pd_lifetime,
       f.lgd,
       f.years_left,
       CASE f.stage
           WHEN 1 THEN f.pd_12m * f.lgd * f.ead * sqrt(f.d)
           WHEN 2 THEN f.pd_12m * f.lgd * f.ead * sqrt(f.d)
                       * (1 - power(f.s * f.d, f.years_left)) / (1 - f.s * f.d)
           WHEN 3 THEN f.lgd * f.ead
       END                                                           AS ecl
FROM f;

ALTER TABLE mart.ecl ADD PRIMARY KEY (loan_seq_no, snapshot_date);
CREATE INDEX ecl_date_idx ON mart.ecl (snapshot_date);
ANALYZE mart.ecl;

COMMIT;

-- Report 1: prepayment rate used
SELECT round(cpr::numeric, 4) AS cpr, cpr_window_from, cpr_window_to FROM mart.ecl_params;

-- Report 2: ECL by stage at the reporting date
SELECT stage,
       count(*)                                        AS loans,
       round((sum(ead) / 1e6)::numeric, 1)            AS ead_mn,
       round((sum(ecl) / 1e6)::numeric, 2)            AS ecl_mn,
       round((100 * sum(ecl) / NULLIF(sum(ead), 0))::numeric, 3) AS coverage_pct
FROM mart.ecl
WHERE snapshot_date = (SELECT max(snapshot_date) FROM mart.ecl)
GROUP BY ROLLUP (stage)
ORDER BY stage NULLS LAST;

-- Report 3: total ECL and coverage at every Q4 (+ reporting date)
SELECT snapshot_date,
       round((sum(ead) / 1e6)::numeric)               AS ead_mn,
       round((sum(ecl) / 1e6)::numeric, 1)            AS ecl_mn,
       round((100 * sum(ecl) / NULLIF(sum(ead), 0))::numeric, 2) AS coverage_pct
FROM mart.ecl
WHERE extract(month FROM snapshot_date) = 12
   OR snapshot_date = (SELECT max(snapshot_date) FROM mart.ecl)
GROUP BY snapshot_date
ORDER BY snapshot_date;