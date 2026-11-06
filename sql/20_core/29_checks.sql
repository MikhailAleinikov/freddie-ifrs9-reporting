-- 29_checks.sql
-- Data quality checks for the core layer (Phase 3):
--   core.loan_month, core.default_event, core.snapshot
-- Requires 20_loan_month.sql, 21_default_event.sql and 22_snapshot.sql to have run.
-- Run from the repo root:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/20_core/29_checks.sql
--
-- Part 1: hard checks. Every row should show status OK.
--         FAIL = result differs from expected. INFO = no fixed expectation, just look at it.
-- Part 2: plausibility tables. No pass/fail; read them and compare with the expectations in the comments.


-- =====================================================================
-- Part 1: hard checks
-- =====================================================================

WITH defect_loans AS (
    SELECT DISTINCT loan_seq_no
    FROM core.perf
    WHERE is_defect
),
checks AS (

    -- loan_month ---------------------------------------------------------

    -- the join to core.orig must not duplicate or drop rows
    SELECT 'loan_month: row count = perf row count' AS check_name,
           (SELECT count(*) FROM core.loan_month)
         - (SELECT count(*) FROM core.perf)          AS result,
           0                                         AS expected

    UNION ALL
    -- known reporting gaps; alert if the number changes after a reload
    SELECT 'perf: loans with missing months',
           (SELECT count(*) FROM (
                SELECT loan_seq_no
                FROM core.perf
                GROUP BY loan_seq_no
                HAVING count(*) <> (extract(year  FROM age(max(period), min(period))) * 12
                                  + extract(month FROM age(max(period), min(period))))::int + 1
           ) g),
           77

    -- default_event ------------------------------------------------------

    UNION ALL
    SELECT 'default_event: one row per loan',
           (SELECT count(*) - count(DISTINCT loan_seq_no) FROM core.default_event),
           0


    UNION ALL
    -- every default_date must be a month the loan actually reported
    SELECT 'default_event: default_date matches a perf row',
           (SELECT count(*)
            FROM core.default_event de
            WHERE NOT EXISTS (SELECT 1 FROM core.perf p
                              WHERE p.loan_seq_no = de.loan_seq_no
                                AND p.period      = de.default_date)),
           0

    UNION ALL
    SELECT 'default_event: trigger populated',
           (SELECT count(*) FROM core.default_event WHERE default_trigger IS NULL),
           0

    -- snapshot -----------------------------------------------------------

    UNION ALL
    SELECT 'snapshot: only quarter-end months',
           (SELECT count(*) FROM core.snapshot
            WHERE extract(month FROM snapshot_date) NOT IN (3, 6, 9, 12)),
           0

    UNION ALL
    -- no loan may appear in or after the month it terminated
    SELECT 'snapshot: no rows at/after termination',
           (SELECT count(*)
            FROM core.snapshot s
            JOIN core.perf p
              ON p.loan_seq_no = s.loan_seq_no
             AND p.zero_balance_code IS NOT NULL
            WHERE s.snapshot_date >= p.period),
           0


    UNION ALL
    SELECT 'snapshot: no REO months',
           (SELECT count(*)
            FROM core.snapshot s
            JOIN core.perf p
              ON p.loan_seq_no = s.loan_seq_no
             AND p.period      = s.snapshot_date
            WHERE p.is_reo_acq),
           0

    UNION ALL
    -- a loan is either already defaulted or may default in the future, never both
    SELECT 'snapshot: has_defaulted and defaults_next_12m exclusive',
           (SELECT count(*) FROM core.snapshot
            WHERE has_defaulted AND defaults_next_12m),
           0

    UNION ALL
    -- the last four quarter-ends cannot have a full 12-month outcome window
    SELECT 'snapshot: censored snapshot dates',
           (SELECT count(DISTINCT snapshot_date) FROM core.snapshot
            WHERE NOT target_observable),
           4

    UNION ALL
    -- defect loans stay in PD data; excluded from LGD in Phase 4
    SELECT 'default_event: defaults on defect loans',
           (SELECT count(*) FROM core.default_event WHERE loan_has_defect),
           NULL

    UNION ALL
    SELECT 'default_event: ead_at_default missing or <= 0',
           (SELECT count(*) FROM core.default_event
            WHERE ead_at_default IS NULL OR ead_at_default <= 0),
           NULL

    UNION ALL
    -- negative = snapshot before first payment date (loan acquired early); a few are fine
    SELECT 'snapshot: rows with months_on_books < 0',
           (SELECT count(*) FROM core.snapshot WHERE months_on_books < 0),
           NULL

    UNION ALL
    -- active loans with zero or missing balance; exist in the raw data, should be rare
    SELECT 'snapshot: rows with ead <= 0 or NULL',
           (SELECT count(*) FROM core.snapshot WHERE ead IS NULL OR ead <= 0),
           NULL
)
SELECT check_name,
       result,
       expected,
       CASE WHEN expected IS NULL   THEN 'INFO'
            WHEN result = expected  THEN 'OK'
            ELSE 'FAIL'
       END AS status
FROM checks;


-- =====================================================================
-- Part 2: plausibility tables
-- =====================================================================

-- 2a. Defaults by trigger.
-- Expect DPD90 to be the large majority; REO and ZB_xx only a small residual.
SELECT default_trigger,
       count(*)                                           AS loans,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM core.default_event
GROUP BY default_trigger
ORDER BY loans DESC;


-- 2b. Lifetime default rate by vintage.
-- Expect high rates for 2006-2007, somewhat lower for 2008, near zero for 2022+.
SELECT o.vintage,
       count(*)                                              AS loans,
       count(de.loan_seq_no)                                 AS defaulted,
       round(100.0 * count(de.loan_seq_no) / count(*), 2)    AS default_pct
FROM core.orig o
LEFT JOIN core.default_event de USING (loan_seq_no)
GROUP BY o.vintage
ORDER BY o.vintage;


-- 2c. The book over time.
-- Expect: active loans rise as each vintage enters, then decay through prepayments;
-- 12m PD (performing, observable population) peaks for 2007-2008 snapshots;
-- currently 90+ peaks around 2009-2011; pd_12m_pct is NULL for the last four dates.
SELECT snapshot_date,
       count(*)                                             AS active_loans,
       round(sum(ead) / 1e6, 1)                             AS ead_mn,
       count(*) FILTER (WHERE delinquency_months >= 3)      AS currently_90plus,
       count(*) FILTER (WHERE has_defaulted)                AS ever_defaulted,
       round(100.0 * avg(defaults_next_12m::int)
             FILTER (WHERE NOT has_defaulted AND target_observable), 2) AS pd_12m_pct
FROM core.snapshot
GROUP BY snapshot_date
ORDER BY snapshot_date;


-- 2d. Ranges of the derived month columns.
-- months_on_books: roughly 0 to ~240; months_since_last_del: 0 upwards, NULL = never delinquent.
SELECT min(months_on_books)                                  AS mob_min,
       max(months_on_books)                                  AS mob_max,
       min(months_since_last_del)                            AS msld_min,
       max(months_since_last_del)                            AS msld_max,
       round(100.0 * avg((months_since_last_del IS NULL)::int), 1) AS pct_never_delinquent
FROM core.snapshot;