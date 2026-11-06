-- 30_pd_sample.sql
-- Development sample for the PD scorecard: performing loans with a full 12-month outcome window.
--   TRAIN / TEST : snapshots before 2019 (outcome windows end before COVID); 30% of LOANS held out as TEST
--   COVID        : snapshots 2019Q1-2021Q4 (windows overlap forbearance) -> stress test only
--   OOT          : snapshots from 2022Q1 -> out-of-time validation
-- Holdout uses md5 of loan_seq_no: deterministic, version-independent, same loan never in both TRAIN and TEST.
-- Derived features (defined ONCE here, reused by binning and scoring):
--   sato           : orig_interest_rate minus the median rate of the same origination quarter (pp)
--   delinq_history : 0 never late | 1 last late 25m+ | 2 last late 12-24m | 3 worst 30 DPD in 12m | 4 worst 60 DPD in 12m
-- Run from the repo root:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/30_risk/30_pd_sample.sql

BEGIN;

DROP TABLE IF EXISTS mart.pd_sample CASCADE;

CREATE TABLE mart.pd_sample AS
WITH orig_q AS (
    SELECT substring(loan_seq_no FROM 2 FOR 4)                             AS orig_qtr,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY orig_interest_rate) AS median_rate
    FROM core.orig
    GROUP BY 1
),
s AS (
    SELECT ss.*,
           ('x' || left(md5(ss.loan_seq_no), 7))::bit(28)::int % 10 AS loan_bucket
    FROM core.snapshot ss
    WHERE NOT ss.has_defaulted
      AND ss.target_observable
)
SELECT
    s.loan_seq_no,
    s.snapshot_date,
    CASE
        WHEN s.snapshot_date <  DATE '2019-01-01' AND s.loan_bucket < 3 THEN 'TEST'
        WHEN s.snapshot_date <  DATE '2019-01-01'                       THEN 'TRAIN'
        WHEN s.snapshot_date <  DATE '2022-01-01'                       THEN 'COVID'
        ELSE 'OOT'
    END                                                         AS sample_split,
    s.defaults_next_12m                                         AS target,
    s.vintage,
    s.months_on_books,
    s.ead,
    s.delinquency_months,
    s.dpd_bucket,
    s.max_delinq_12m,
    s.months_since_last_del,
    CASE
        WHEN s.max_delinq_12m >= 2             THEN 4
        WHEN s.max_delinq_12m  = 1             THEN 3
        WHEN s.months_since_last_del IS NULL   THEN 0
        WHEN s.months_since_last_del >= 25     THEN 1
        ELSE                                        2
    END                                                         AS delinq_history,
    s.is_forbearance,
    s.ever_modified,
    s.ever_deferred,
    s.current_ltv,
    s.credit_score,
    s.orig_ltv,
    s.orig_dti,
    s.orig_interest_rate,
    round((s.orig_interest_rate - q.median_rate)::numeric, 2)  AS sato,
    s.occupancy_status,
    s.loan_purpose,
    s.property_state,
    s.channel,
    s.num_borrowers,
    s.first_time_homebuyer
FROM s
LEFT JOIN orig_q q ON q.orig_qtr = substring(s.loan_seq_no FROM 2 FOR 4);

ALTER TABLE mart.pd_sample ADD PRIMARY KEY (loan_seq_no, snapshot_date);
CREATE INDEX pd_sample_split_idx ON mart.pd_sample (sample_split);
ANALYZE mart.pd_sample;

COMMIT;