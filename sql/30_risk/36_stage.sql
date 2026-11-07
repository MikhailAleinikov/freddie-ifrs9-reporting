-- 36_stage.sql
-- IFRS 9 stage per loan and quarter-end >> mart.stage
-- Rules, applied in priority order (first match wins, stored as stage_reason):
--   Stage 3 (credit-impaired = in default, CRR Art. 178):
--     S3_DPD90           90+ days past due
--     S3_PROBATION       cured from 90+ less than 3 months ago (EBA GL on the definition of default: min. 3-month probation)
--     S3_DISTRESSED_MOD  modified within the last 12 months after a delinquency in the last 12 months
--                        (distressed restructuring = unlikeliness to pay, Art. 178(3)(d); approximation, see assumptions)
--   Stage 2 (significant increase in credit risk since initial recognition):
--     S2_DPD30           30+ days past due (IFRS 9 5.5.11 rebuttable backstop)
--     S2_FORBEARANCE     currently in a forbearance plan or disaster relief (includes COVID forbearance)
--     S2_FORBORNE_PROB   modified within the last 24 months (mirrors the EBA 2-year forborne probation)
--     S2_PD_SICR         12m PD >= 3x PD at initial recognition AND at least +0.5 pp
--                        (PD at initial recognition = PD at the loan's first snapshot)
--   Stage 1: everything else
-- Depends on: core.snapshot, mart.pd_score
-- Run from the repo root:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/30_risk/36_stage.sql

BEGIN;

SET LOCAL work_mem = '256MB';

DROP TABLE IF EXISTS mart.stage CASCADE;

CREATE TABLE mart.stage AS
WITH base AS (
    SELECT s.loan_seq_no,
           s.snapshot_date,
           s.ead,
           COALESCE(s.delinquency_months, 0)                  AS dpd_months,
           s.months_since_last_90,
           s.months_since_last_mod,
           s.max_delinq_12m,
           COALESCE(s.is_forbearance, false)                  AS is_forbearance,
           p.grade,
           p.pd_12m,
           first_value(p.pd_12m) OVER (PARTITION BY s.loan_seq_no
                                       ORDER BY s.snapshot_date) AS pd_orig
    FROM core.snapshot s
    JOIN mart.pd_score p USING (loan_seq_no, snapshot_date)
),
staged AS (
    SELECT b.*,
           CASE
               WHEN b.dpd_months >= 3                                       THEN 'S3_DPD90'
               WHEN b.months_since_last_90 < 3                              THEN 'S3_PROBATION'
               WHEN b.months_since_last_mod < 12
                AND COALESCE(b.max_delinq_12m, 0) >= 1                      THEN 'S3_DISTRESSED_MOD'
               WHEN b.dpd_months >= 1                                       THEN 'S2_DPD30'
               WHEN b.is_forbearance                                        THEN 'S2_FORBEARANCE'
               WHEN b.months_since_last_mod < 24                            THEN 'S2_FORBORNE_PROB'
               WHEN b.pd_12m >= 3 * b.pd_orig
                AND b.pd_12m - b.pd_orig >= 0.005                           THEN 'S2_PD_SICR'
               ELSE                                                              'S1'
           END AS stage_reason
    FROM base b
)
SELECT loan_seq_no,
       snapshot_date,
       substring(stage_reason FROM 2 FOR 1)::int AS stage,
       stage_reason,
       ead,
       dpd_months,
       grade,
       pd_12m,
       pd_orig,
       stage_reason LIKE 'S3%'                    AS is_npe
FROM staged;

ALTER TABLE mart.stage ADD PRIMARY KEY (loan_seq_no, snapshot_date);
CREATE INDEX stage_date_idx ON mart.stage (snapshot_date);
ANALYZE mart.stage;

COMMIT;

-- Report 1: stage mix by exposure at every Q4 (expect Stage 3 peak ~2009-2011, Stage 2 spike 2020)
SELECT snapshot_date,
       count(*)                                                                    AS loans,
       round(100.0 * sum(ead) FILTER (WHERE stage = 1) / sum(ead), 2)              AS s1_pct_ead,
       round(100.0 * sum(ead) FILTER (WHERE stage = 2) / sum(ead), 2)              AS s2_pct_ead,
       round(100.0 * sum(ead) FILTER (WHERE stage = 3) / sum(ead), 2)              AS s3_pct_ead
FROM mart.stage
WHERE extract(month FROM snapshot_date) = 12
   OR snapshot_date = (SELECT max(snapshot_date) FROM mart.stage)
GROUP BY snapshot_date
ORDER BY snapshot_date;

-- Report 2: stage reasons at the reporting date
SELECT stage, stage_reason, count(*) AS loans, round(sum(ead)) AS ead
FROM mart.stage
WHERE snapshot_date = (SELECT max(snapshot_date) FROM mart.stage)
GROUP BY stage, stage_reason
ORDER BY stage, stage_reason;

-- Report 3: SICR threshold sensitivity at the reporting date (share of loans that would be Stage 2 via PD)
SELECT round(100.0 * avg((pd_12m >= 2 * pd_orig AND pd_12m - pd_orig >= 0.005)::int), 2) AS pd_sicr_2x_pct,
       round(100.0 * avg((pd_12m >= 3 * pd_orig AND pd_12m - pd_orig >= 0.005)::int), 2) AS pd_sicr_3x_pct
FROM mart.stage
WHERE snapshot_date = (SELECT max(snapshot_date) FROM mart.stage)
  AND stage_reason IN ('S1', 'S2_PD_SICR');