-- 31_bin_def.sql
-- Bin definitions (cut points) for the PD scorecard. These are DECISIONS, maintained by hand;
-- 32_binning.sql computes the statistics from them.
-- Conventions:
--   numeric bins     : lo <= x < hi, NULL = open end; bin_id increases with the value
--   categorical bins : cat_values lists the codes exactly as stored (booleans as 'true'/'false')
--   missing bin      : bin_id 0, is_missing = true (every feature that can be NULL has one)
-- Iterate: run 32_binning.sql, check report 4b (small / few-bads bins) and feature_monotonic,
--          merge neighbouring bins here, rerun.
-- Depends on: core.orig (states), mart.pd_sample (ead quantiles)
-- Run from the repo root:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/30_risk/31_bin_def.sql

DROP TABLE IF EXISTS mart.bin_def CASCADE;
CREATE TABLE mart.bin_def (
    feature     TEXT    NOT NULL,
    bin_id      INTEGER NOT NULL,
    bin_label   TEXT    NOT NULL,
    lo          NUMERIC,
    hi          NUMERIC,
    cat_values  TEXT[],
    is_missing  BOOLEAN NOT NULL DEFAULT false,
    PRIMARY KEY (feature, bin_id),
    CHECK (is_missing OR cat_values IS NOT NULL OR lo IS NOT NULL OR hi IS NOT NULL)
);

INSERT INTO mart.bin_def (feature, bin_id, bin_label, lo, hi, cat_values, is_missing) VALUES

-- ===== origination: numeric =====
-- 620 = subprime line, 740+ = top pricing tier
('credit_score', 0, 'missing',  NULL, NULL, NULL, true),
('credit_score', 1, '<620',     NULL, 620,  NULL, false),
('credit_score', 2, '620-659',  620,  660,  NULL, false),
('credit_score', 3, '660-699',  660,  700,  NULL, false),
('credit_score', 4, '700-739',  700,  740,  NULL, false),
('credit_score', 5, '740-779',  740,  780,  NULL, false),
('credit_score', 6, '780+',     780,  NULL, NULL, false),

-- 80 = mortgage insurance threshold
('orig_ltv', 0, 'missing', NULL, NULL, NULL, true),
('orig_ltv', 1, '<=60',    NULL, 61,   NULL, false),
('orig_ltv', 2, '61-70',   61,   71,   NULL, false),
('orig_ltv', 3, '71-80',   71,   81,   NULL, false),
('orig_ltv', 4, '81-90',   81,   91,   NULL, false),
('orig_ltv', 5, '91-95',   91,   96,   NULL, false),
('orig_ltv', 6, '>95',     96,   NULL, NULL, false),

-- 36 / 43 = standard underwriting limits; missing includes HARP / relief refis
('orig_dti', 0, 'missing', NULL, NULL, NULL, true),
('orig_dti', 1, '<20',     NULL, 20,   NULL, false),
('orig_dti', 2, '20-29',   20,   30,   NULL, false),
('orig_dti', 3, '30-36',   30,   37,   NULL, false),
('orig_dti', 4, '37-43',   37,   44,   NULL, false),
('orig_dti', 5, '44-50',   44,   51,   NULL, false),
('orig_dti', 6, '>50',     51,   NULL, NULL, false),

-- rate minus median rate of the same origination quarter, in percentage points
('sato', 0, 'missing',      NULL,  NULL,  NULL, true),
('sato', 1, '<-0.25',       NULL,  -0.25, NULL, false),
('sato', 2, '-0.25 to 0',   -0.25, 0,     NULL, false),
('sato', 3, '0 to 0.25',    0,     0.25,  NULL, false),
('sato', 4, '0.25 to 0.5',  0.25,  0.5,   NULL, false),
('sato', 5, '0.5+',         0.5,   NULL,  NULL, false),

('num_borrowers', 0, 'missing', NULL, NULL, NULL, true),
('num_borrowers', 1, '1',       NULL, 2,    NULL, false),
('num_borrowers', 2, '2+',      2,    NULL, NULL, false),

-- ===== behavioural: numeric =====
-- >= 100 = underwater, the strongest default driver in 2008
('current_ltv', 0, 'missing', NULL, NULL, NULL, true),
('current_ltv', 1, '<50',     NULL, 50,   NULL, false),
('current_ltv', 2, '50-69',   50,   70,   NULL, false),
('current_ltv', 3, '70-79',   70,   80,   NULL, false),
('current_ltv', 4, '80-89',   80,   90,   NULL, false),
('current_ltv', 5, '90-99',   90,   100,  NULL, false),
('current_ltv', 6, '100+',    100,  NULL, NULL, false),

-- defaults peak in years 2-4; missing = 1 loan with first_payment_date after a modification
('months_on_books', 0, 'missing', NULL, NULL, NULL, true),
('months_on_books', 1, '0-6',     NULL, 7,    NULL, false),
('months_on_books', 2, '7-12',    7,    13,   NULL, false),
('months_on_books', 3, '13-24',   13,   25,   NULL, false),
('months_on_books', 4, '25-36',   25,   37,   NULL, false),
('months_on_books', 5, '37-60',   37,   61,   NULL, false),
('months_on_books', 6, '61+',     61,   NULL, NULL, false),

-- max is 2 in the PD sample: 3+ means already defaulted (filtered out)
('max_delinq_12m', 0, 'missing',  NULL, NULL, NULL, true),
('max_delinq_12m', 1, '0',        NULL, 1,    NULL, false),
('max_delinq_12m', 2, '1 (30d)',  1,    2,    NULL, false),
('max_delinq_12m', 3, '2 (60d)',  2,    NULL, NULL, false),

-- NULL = never delinquent -> expected safest bin; 0 = delinquent this month
('months_since_last_del', 0, 'never', NULL, NULL, NULL, true),
('months_since_last_del', 1, '0-3',   NULL, 4,    NULL, false),
('months_since_last_del', 2, '4-12',  4,    13,   NULL, false),
('months_since_last_del', 3, '13-24', 13,   25,   NULL, false),
('months_since_last_del', 4, '25+',   25,   NULL, NULL, false),

-- ===== categorical =====
-- 90+ cannot appear in the PD sample. Labels must match core.loan_month exactly:
--   SELECT DISTINCT dpd_bucket FROM mart.pd_sample;
('dpd_bucket', 0, 'missing', NULL, NULL, NULL,      true),
('dpd_bucket', 1, '0-29',    NULL, NULL, '{0-29}',  false),
('dpd_bucket', 2, '30-59',   NULL, NULL, '{30-59}', false),
('dpd_bucket', 3, '60-89',   NULL, NULL, '{60-89}', false),

-- P = primary, I = investment, S = second home (merge I+S if S is tiny)
('occupancy_status', 0, 'missing', NULL, NULL, NULL,  true),
('occupancy_status', 1, 'P',       NULL, NULL, '{P}', false),
('occupancy_status', 2, 'S',       NULL, NULL, '{S}', false),
('occupancy_status', 3, 'I',       NULL, NULL, '{I}', false),

-- P = purchase, C = cash-out refi, N = no cash-out refi, R = unspecified refi (merged with N)
('loan_purpose', 0, 'missing', NULL, NULL, NULL,    true),
('loan_purpose', 1, 'P',       NULL, NULL, '{P}',   false),
('loan_purpose', 2, 'C',       NULL, NULL, '{C}',   false),
('loan_purpose', 3, 'N+R',     NULL, NULL, '{N,R}', false),

-- R = retail, B = broker, C = correspondent, T = TPO not specified
('channel', 0, 'missing', NULL, NULL, NULL,  true),
('channel', 1, 'R',       NULL, NULL, '{R}', false),
('channel', 2, 'B',       NULL, NULL, '{B}', false),
('channel', 3, 'C',       NULL, NULL, '{C}', false),
('channel', 4, 'T',       NULL, NULL, '{T}', false),

-- ===== boolean (stored as text 'true' / 'false') =====
-- first_time_homebuyer: if core.orig keeps it as text Y/N, change to '{Y}' / '{N}'
('first_time_homebuyer', 0, 'missing', NULL, NULL, NULL,      true),
('first_time_homebuyer', 1, 'no',      NULL, NULL, '{false}', false),
('first_time_homebuyer', 2, 'yes',     NULL, NULL, '{true}',  false),

('is_forbearance', 0, 'missing', NULL, NULL, NULL,      true),
('is_forbearance', 1, 'no',      NULL, NULL, '{false}', false),
('is_forbearance', 2, 'yes',     NULL, NULL, '{true}',  false),

('ever_modified', 0, 'missing', NULL, NULL, NULL,      true),
('ever_modified', 1, 'no',      NULL, NULL, '{false}', false),
('ever_modified', 2, 'yes',     NULL, NULL, '{true}',  false),

('ever_deferred', 0, 'missing', NULL, NULL, NULL,      true),
('ever_deferred', 1, 'no',      NULL, NULL, '{false}', false),
('ever_deferred', 2, 'yes',     NULL, NULL, '{true}',  false);

-- ===== property_state: fine classing, one bin per state =====
-- After the first binning run, replace this block with 4-6 hand-written groups by default rate,
-- e.g. ('property_state', 1, 'high risk', NULL, NULL, '{FL,NV,AZ,CA}', false)
INSERT INTO mart.bin_def (feature, bin_id, bin_label, lo, hi, cat_values, is_missing)
VALUES ('property_state', 0, 'missing', NULL, NULL, NULL, true);

INSERT INTO mart.bin_def (feature, bin_id, bin_label, lo, hi, cat_values, is_missing)
SELECT 'property_state',
       row_number() OVER (ORDER BY property_state),
       property_state,
       NULL, NULL,
       ARRAY[property_state],
       false
FROM (SELECT DISTINCT property_state FROM core.orig WHERE property_state IS NOT NULL) s;

-- ===== ead: quintiles of TRAIN, rounded to 1,000 (32_binning rounds ead to ead_k) =====
-- After the first run, freeze: replace this block with the printed cut points as literal INSERTs.
INSERT INTO mart.bin_def (feature, bin_id, bin_label, lo, hi, cat_values, is_missing)
VALUES ('ead', 0, 'missing', NULL, NULL, NULL, true);

INSERT INTO mart.bin_def (feature, bin_id, bin_label, lo, hi, cat_values, is_missing)
WITH q AS (
    SELECT percentile_cont(ARRAY[0.2, 0.4, 0.6, 0.8]) WITHIN GROUP (ORDER BY ead) AS p
    FROM mart.pd_sample
    WHERE sample_split = 'TRAIN'
),
c AS (
    SELECT round(p[1]::numeric, -3) AS c1, round(p[2]::numeric, -3) AS c2,
           round(p[3]::numeric, -3) AS c3, round(p[4]::numeric, -3) AS c4
    FROM q
)
SELECT 'ead', v.bin_id, v.bin_label, v.lo, v.hi, NULL::text[], false
FROM c
CROSS JOIN LATERAL (VALUES
    (1, '<'   || c.c1,               NULL::numeric, c.c1),
    (2, c.c1  || '-' || c.c2,        c.c1,          c.c2),
    (3, c.c2  || '-' || c.c3,        c.c2,          c.c3),
    (4, c.c3  || '-' || c.c4,        c.c3,          c.c4),
    (5, c.c4  || '+',                c.c4,          NULL::numeric)
) AS v(bin_id, bin_label, lo, hi);

ANALYZE mart.bin_def;

-- ===== overview: bins per feature (expect 19 features) =====
SELECT feature, count(*) AS bins, bool_or(is_missing) AS has_missing_bin
FROM mart.bin_def
GROUP BY feature
ORDER BY feature;

-- ===== ead cut points to freeze after the first run =====
SELECT bin_id, bin_label, lo, hi FROM mart.bin_def WHERE feature = 'ead' ORDER BY bin_id;