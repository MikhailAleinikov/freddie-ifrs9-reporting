-- 22_snapshot.sql
-- makes quarterly snapshots of the ongoing loan
-- Run from the repo root:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/20_core/22_snapshot.sql
-- Column roles (core.snapshot):
--   KEY        loan_seq_no, snapshot_date
--   FEATURES   point-in-time only: everything known at snapshot_date
--              vintage, months_on_books, ead, delinquency_months, dpd_bucket,
--              max_delinq_12m, months_since_last_del, is_forbearance,
--              ever_modified, ever_deferred, current_ltv, credit_score,
--              orig_ltv, orig_dti, orig_interest_rate, occupancy_status,
--              loan_purpose, property_state, channel, num_borrowers,
--              first_time_homebuyer
--   LABEL      defaults_next_12m (first default within months t+1..t+12)
--   FILTERS    has_defaulted      -> scorecard sample uses has_defaulted = false
--              target_observable  -> scorecard sample uses target_observable = true
--   DEBUG ONLY default_date, default_trigger
--              LOOK-AHEAD: may describe events after snapshot_date.
--              Never use as model features.


DROP TABLE IF EXISTS core.snapshot CASCADE;

CREATE TABLE core.snapshot AS
WITH q AS (
    SELECT d::date AS snapshot_date
    FROM generate_series(
        (SELECT date_trunc('quarter', min(period)::timestamp) + interval '2 months' FROM core.perf),
        (SELECT max(period)::timestamp FROM core.perf),
        interval '3 months'
    ) AS d
),
cutoff AS (
    SELECT max(period) AS max_period FROM core.perf
)
SELECT
    loan_seq_no,
    q.snapshot_date,
    o.vintage,
    CASE WHEN lm.period >= o.first_payment_date - interval '1 month'
         THEN (extract(year  FROM age(lm.period, o.first_payment_date)) * 12
             + extract(month FROM age(lm.period, o.first_payment_date)))::int + 1
    END                                                       AS months_on_books,
    lm.current_upb                                            AS ead,
    lm.delinquency_months,
    lm.dpd_bucket,
    lm.max_delinq_12m,
    (extract(year  FROM age(lm.period, lm.last_delinq_period)) * 12
   + extract(month FROM age(lm.period, lm.last_delinq_period)))::int AS months_since_last_del,
    lm.is_forbearance,
    lm.ever_modified,
    lm.ever_deferred,
    lm.current_ltv,
    o.credit_score,
    o.orig_ltv,
    o.orig_dti,
    o.occupancy_status,
    o.loan_purpose,
    o.property_state,
    o.channel,
    o.num_borrowers,
    o.first_time_homebuyer,
    o.orig_interest_rate,
    COALESCE(de.default_date <= q.snapshot_date, false)       AS has_defaulted,
    COALESCE(de.default_date >  q.snapshot_date
         AND de.default_date <= q.snapshot_date + interval '12 months', false) AS defaults_next_12m,
    q.snapshot_date + interval '12 months' <= c.max_period    AS target_observable,
    de.default_date,
    de.default_trigger
FROM q
CROSS JOIN cutoff c
JOIN core.loan_month lm ON lm.period = q.snapshot_date
JOIN core.orig o USING (loan_seq_no)
LEFT JOIN core.default_event de USING (loan_seq_no)
WHERE lm.zero_balance_code IS NULL
  AND NOT lm.is_reo_acq;

ALTER TABLE core.snapshot ADD PRIMARY KEY (loan_seq_no, snapshot_date);
CREATE INDEX snapshot_date_idx ON core.snapshot (snapshot_date);
ANALYZE core.snapshot;
