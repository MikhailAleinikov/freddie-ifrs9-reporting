-- 34_snapshot_woe.sql
-- Applies the final bins and TRAIN WoE to EVERY row of core.snapshot >> mart.snapshot_woe
--   (all quarter-ends, all loans, including the reporting date and already-defaulted loans),
--   so that the same table feeds model fitting (joined to mart.pd_sample) and scoring of the book.
-- WoE always comes from mart.binning (TRAIN only), never from the scored period: fit on TRAIN, apply everywhere.
-- Features (final scorecard candidates): credit_score, orig_ltv, orig_dti, sato, num_borrowers,
--   delinq_history, loan_purpose. sato and delinq_history use the same definitions as 30_pd_sample.sql.
-- A bin with no TRAIN rows has no WoE in mart.binning; such rows get WoE 0 (= average risk).
-- Bin assignment below mirrors mart.bin_def; the reconciliation query at the end proves it
--   (TRAIN counts per bin must equal mart.binning.n exactly). If you change bin_def, change the CASEs too.
-- Depends on: core.snapshot, core.orig, mart.binning, mart.pd_sample
-- Run from the repo root:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/30_risk/34_snapshot_woe.sql

BEGIN;

SET LOCAL work_mem = '256MB';

DROP TABLE IF EXISTS mart.snapshot_woe CASCADE;

CREATE TABLE mart.snapshot_woe AS
WITH orig_q AS (
    SELECT substring(loan_seq_no FROM 2 FOR 4)                             AS orig_qtr,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY orig_interest_rate) AS median_rate
    FROM core.orig
    GROUP BY 1
),
f AS (
    SELECT s.loan_seq_no,
           s.snapshot_date,
           s.credit_score,
           s.orig_ltv,
           s.orig_dti,
           round((s.orig_interest_rate - q.median_rate)::numeric, 2) AS sato,
           s.num_borrowers,
           CASE
               WHEN s.max_delinq_12m >= 2           THEN 4
               WHEN s.max_delinq_12m  = 1           THEN 3
               WHEN s.months_since_last_del IS NULL THEN 0
               WHEN s.months_since_last_del >= 25   THEN 1
               ELSE                                      2
           END                                                      AS delinq_history,
           s.loan_purpose
    FROM core.snapshot s
    LEFT JOIN orig_q q ON q.orig_qtr = substring(s.loan_seq_no FROM 2 FOR 4)
),
b AS (
    SELECT f.*,
           CASE WHEN f.credit_score IS NULL OR f.credit_score < 620 THEN 1
                WHEN f.credit_score < 660 THEN 2
                WHEN f.credit_score < 700 THEN 3
                WHEN f.credit_score < 740 THEN 4
                WHEN f.credit_score < 780 THEN 5
                ELSE 6 END                                          AS bin_credit_score,
           CASE WHEN f.orig_ltv IS NULL THEN 2
                WHEN f.orig_ltv < 61 THEN 1
                WHEN f.orig_ltv < 81 THEN 2
                WHEN f.orig_ltv < 96 THEN 3
                ELSE 4 END                                          AS bin_orig_ltv,
           CASE WHEN f.orig_dti IS NULL THEN 2
                WHEN f.orig_dti < 30 THEN 1
                WHEN f.orig_dti < 37 THEN 2
                WHEN f.orig_dti < 44 THEN 3
                WHEN f.orig_dti < 51 THEN 4
                ELSE 5 END                                          AS bin_orig_dti,
           CASE WHEN f.sato IS NULL THEN 0
                WHEN f.sato < -0.25 THEN 1
                WHEN f.sato < 0     THEN 2
                WHEN f.sato < 0.25  THEN 3
                WHEN f.sato < 0.5   THEN 4
                ELSE 5 END                                          AS bin_sato,
           CASE WHEN f.num_borrowers IS NULL OR f.num_borrowers >= 2 THEN 2
                ELSE 1 END                                          AS bin_num_borrowers,
           f.delinq_history                                         AS bin_delinq_history,
           CASE WHEN f.loan_purpose = 'C' THEN 2
                ELSE 1 END                                          AS bin_loan_purpose
    FROM f
)
SELECT b.loan_seq_no,
       b.snapshot_date,
       b.sato,
       b.delinq_history,
       b.bin_credit_score,
       b.bin_orig_ltv,
       b.bin_orig_dti,
       b.bin_sato,
       b.bin_num_borrowers,
       b.bin_delinq_history,
       b.bin_loan_purpose,
       COALESCE(w1.woe, 0) AS woe_credit_score,
       COALESCE(w2.woe, 0) AS woe_orig_ltv,
       COALESCE(w3.woe, 0) AS woe_orig_dti,
       COALESCE(w4.woe, 0) AS woe_sato,
       COALESCE(w5.woe, 0) AS woe_num_borrowers,
       COALESCE(w6.woe, 0) AS woe_delinq_history,
       COALESCE(w7.woe, 0) AS woe_loan_purpose
FROM b
LEFT JOIN mart.binning w1 ON w1.feature = 'credit_score'   AND w1.bin_id = b.bin_credit_score
LEFT JOIN mart.binning w2 ON w2.feature = 'orig_ltv'       AND w2.bin_id = b.bin_orig_ltv
LEFT JOIN mart.binning w3 ON w3.feature = 'orig_dti'       AND w3.bin_id = b.bin_orig_dti
LEFT JOIN mart.binning w4 ON w4.feature = 'sato'           AND w4.bin_id = b.bin_sato
LEFT JOIN mart.binning w5 ON w5.feature = 'num_borrowers'  AND w5.bin_id = b.bin_num_borrowers
LEFT JOIN mart.binning w6 ON w6.feature = 'delinq_history' AND w6.bin_id = b.bin_delinq_history
LEFT JOIN mart.binning w7 ON w7.feature = 'loan_purpose'   AND w7.bin_id = b.bin_loan_purpose;

ALTER TABLE mart.snapshot_woe ADD PRIMARY KEY (loan_seq_no, snapshot_date);
ANALYZE mart.snapshot_woe;

COMMIT;

-- Reconciliation: TRAIN counts per bin must equal mart.binning.n. Must return no rows.
-- A row here means a CASE above disagrees with mart.bin_def.
WITH train AS (
    SELECT w.*
    FROM mart.snapshot_woe w
    JOIN mart.pd_sample ps USING (loan_seq_no, snapshot_date)
    WHERE ps.sample_split = 'TRAIN'
),
counts AS (
    SELECT 'credit_score' AS feature, bin_credit_score AS bin_id, count(*) AS n FROM train GROUP BY 2
    UNION ALL SELECT 'orig_ltv',       bin_orig_ltv,       count(*) FROM train GROUP BY 2
    UNION ALL SELECT 'orig_dti',       bin_orig_dti,       count(*) FROM train GROUP BY 2
    UNION ALL SELECT 'sato',           bin_sato,           count(*) FROM train GROUP BY 2
    UNION ALL SELECT 'num_borrowers',  bin_num_borrowers,  count(*) FROM train GROUP BY 2
    UNION ALL SELECT 'delinq_history', bin_delinq_history, count(*) FROM train GROUP BY 2
    UNION ALL SELECT 'loan_purpose',   bin_loan_purpose,   count(*) FROM train GROUP BY 2
)
SELECT COALESCE(c.feature, b.feature) AS feature,
       COALESCE(c.bin_id,  b.bin_id)  AS bin_id,
       c.n AS n_here, b.n AS n_binning
FROM counts c
FULL JOIN (SELECT feature, bin_id, n FROM mart.binning WHERE n > 0) b
  ON b.feature = c.feature AND b.bin_id = c.bin_id
WHERE c.n IS DISTINCT FROM b.n
ORDER BY 1, 2;