-- 31_pd_sample.sql
-- Development sample for the PD scorecard: performing loans with a full 12-month outcome window.
--   TRAIN / TEST : snapshots before 2019 (outcome windows end before COVID); 30% of LOANS held out as TEST
--   COVID        : snapshots 2019Q1-2021Q4 (windows overlap forbearance) -> stress test only
--   OOT          : snapshots from 2022Q1 -> out-of-time validation
-- Holdout uses md5 of loan_seq_no: deterministic, version-independent, same loan never in both TRAIN and TEST.
-- Run from the repo root:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/30_risk/31_pd_sample.sql

DROP TABLE IF EXISTS mart.pd_sample CASCADE;

CREATE TABLE mart.pd_sample AS
WITH s AS (
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
    END                         AS sample_split,
    s.defaults_next_12m         AS target,
    s.vintage,
    s.months_on_books,
    s.ead,
    s.delinquency_months,
    s.dpd_bucket,
    s.max_delinq_12m,
    s.months_since_last_del,
    s.months_since_last_90,
    s.is_forbearance,
    s.ever_modified,
    s.ever_deferred,
    s.current_ltv,
    s.credit_score,
    s.orig_ltv,
    s.orig_dti,
    s.orig_interest_rate,
    s.occupancy_status,
    s.loan_purpose,
    s.property_state,
    s.channel,
    s.num_borrowers,
    s.first_time_homebuyer
FROM s;

ALTER TABLE mart.pd_sample ADD PRIMARY KEY (loan_seq_no, snapshot_date);
CREATE INDEX pd_sample_split_idx ON mart.pd_sample (sample_split);
ANALYZE mart.pd_sample;