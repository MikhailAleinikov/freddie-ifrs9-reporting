-- 37_lgd.sql
-- Loss given default from observed default resolutions.
--   mart.lgd_obs   : one row per defaulted loan (core.default_event) with its workout outcome and realised LGD
--   mart.lgd_table : LGD per original-LTV band (+ 'ALL' fallback row), used by 38_ecl.sql
-- Outcome of each default (from the loan's last monthly record):
--   DEFECT      loss transferred to the seller (underwriting defect)          -> excluded
--   LIQUIDATED  zero balance 02/03/09/15 with actual_loss reported           -> LGD = actual_loss / EAD at default
--   CURED       paid off after default (ZB 01), reperforming loan sale (ZB 16),
--               or still active, current, and 12+ months since the last 90+ month -> LGD = 0
--   UNRESOLVED  everything else (still in workout, loss not yet reported)     -> excluded (resolution bias, see assumptions)
-- LGD of a liquidation is discounted to the default date at the loan's note rate over the workout period
-- (IFRS 9 discounts at the effective interest rate), floored at 0 and capped at 100%.
-- LGD = (1 - cure rate) x average liquidation LGD (LGL); floored at 5% (CRR3 retail residential floor, prudence).
-- No house-price indexation: segmentation by ORIGINAL LTV (limitation, see assumptions).
-- Depends on: core.default_event, core.loan_month, core.orig
-- Run from the repo root:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/30_risk/37_lgd.sql

BEGIN;

DROP TABLE IF EXISTS mart.lgd_obs CASCADE;

CREATE TABLE mart.lgd_obs AS
WITH last_row AS (
    SELECT DISTINCT ON (lm.loan_seq_no)
           lm.loan_seq_no,
           lm.period            AS last_period,
           lm.zero_balance_code,
           lm.zero_balance_date,
           lm.actual_loss,
           lm.delinquency_months,
           lm.last_90_period
    FROM core.loan_month lm
    WHERE lm.loan_seq_no IN (SELECT loan_seq_no FROM core.default_event)
    ORDER BY lm.loan_seq_no, lm.period DESC
),
classified AS (
    SELECT de.loan_seq_no,
           o.vintage,
           de.default_date,
           de.default_trigger,
           de.ead_at_default,
           o.orig_ltv,
           o.orig_interest_rate,
           COALESCE(o.mi_pct, 0) > 0                            AS has_mi,
           CASE WHEN o.orig_ltv IS NULL OR o.orig_ltv BETWEEN 61 AND 80 THEN '61-80'
                WHEN o.orig_ltv <= 60 THEN '<=60'
                ELSE '81+' END                                   AS ltv_band,
           lr.zero_balance_code,
           lr.actual_loss,
           CASE
               WHEN de.loan_has_defect                                      THEN 'DEFECT'
               WHEN lr.zero_balance_code IN ('02','03','09','15')
                AND lr.actual_loss IS NOT NULL                              THEN 'LIQUIDATED'
               WHEN lr.zero_balance_code IN ('01','16')                     THEN 'CURED'
               WHEN lr.zero_balance_code IS NULL
                AND COALESCE(lr.delinquency_months, 0) = 0
                AND lr.last_period >= lr.last_90_period + interval '12 months' THEN 'CURED'
               ELSE                                                              'UNRESOLVED'
           END                                                   AS outcome,
           (extract(year  FROM age(COALESCE(lr.zero_balance_date, lr.last_period), de.default_date)) * 12
          + extract(month FROM age(COALESCE(lr.zero_balance_date, lr.last_period), de.default_date)))::int
                                                                 AS workout_months
    FROM core.default_event de
    JOIN core.orig o     USING (loan_seq_no)
    JOIN last_row lr     USING (loan_seq_no)
)
SELECT c.*,
       CASE c.outcome
           WHEN 'CURED'      THEN 0
           WHEN 'LIQUIDATED' THEN least(1, greatest(0,
                   c.actual_loss / NULLIF(c.ead_at_default, 0)
                   / power(1 + c.orig_interest_rate / 1200, greatest(c.workout_months, 0))))
       END                                                       AS lgd_realised
FROM classified c;

ALTER TABLE mart.lgd_obs ADD PRIMARY KEY (loan_seq_no);

DROP TABLE IF EXISTS mart.lgd_table CASCADE;

CREATE TABLE mart.lgd_table AS
WITH seg AS (
    SELECT ltv_band, outcome, lgd_realised FROM mart.lgd_obs
    UNION ALL
    SELECT 'ALL',    outcome, lgd_realised FROM mart.lgd_obs
)
SELECT ltv_band,
       count(*) FILTER (WHERE outcome IN ('CURED', 'LIQUIDATED'))          AS n_resolved,
       count(*) FILTER (WHERE outcome = 'CURED')                           AS n_cured,
       count(*) FILTER (WHERE outcome = 'LIQUIDATED')                      AS n_liquidated,
       count(*) FILTER (WHERE outcome = 'UNRESOLVED')                      AS n_unresolved,
       count(*) FILTER (WHERE outcome = 'DEFECT')                          AS n_defect,
       count(*) FILTER (WHERE outcome = 'CURED')::double precision
         / NULLIF(count(*) FILTER (WHERE outcome IN ('CURED', 'LIQUIDATED')), 0)          AS cure_rate,
       avg(lgd_realised) FILTER (WHERE outcome = 'LIQUIDATED')             AS lgl,
       greatest(
           (1 - count(*) FILTER (WHERE outcome = 'CURED')::double precision
                / NULLIF(count(*) FILTER (WHERE outcome IN ('CURED', 'LIQUIDATED')), 0))
           * avg(lgd_realised) FILTER (WHERE outcome = 'LIQUIDATED'),
           0.05
       )                                                                   AS lgd
FROM seg
GROUP BY ltv_band;

ALTER TABLE mart.lgd_table ADD PRIMARY KEY (ltv_band);

COMMIT;

-- Report 1: what happened to the defaults, by era
SELECT CASE WHEN vintage::int <= 2008 THEN 'crisis' ELSE 'modern' END AS era,
       outcome,
       count(*)                                   AS loans,
       round(avg(lgd_realised)::numeric, 3)       AS avg_lgd,
       round(avg(workout_months)::numeric, 1)     AS avg_workout_months
FROM mart.lgd_obs
GROUP BY 1, 2
ORDER BY 1, 2;

-- Report 2: LGD table used for ECL
SELECT ltv_band, n_resolved, n_cured, n_liquidated, n_unresolved, n_defect,
       round(cure_rate::numeric, 3) AS cure_rate,
       round(lgl::numeric, 3)       AS lgl,
       round(lgd::numeric, 3)       AS lgd
FROM mart.lgd_table
ORDER BY ltv_band;