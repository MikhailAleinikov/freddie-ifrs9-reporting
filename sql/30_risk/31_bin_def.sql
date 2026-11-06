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
('credit_score', 1, '<620 or missing', NULL, 620, NULL, true),
('credit_score', 2, '620-659',  620,  660,  NULL, false),
('credit_score', 3, '660-699',  660,  700,  NULL, false),
('credit_score', 4, '700-739',  700,  740,  NULL, false),
('credit_score', 5, '740-779',  740,  780,  NULL, false),
('credit_score', 6, '780+',     780,  NULL, NULL, false),

-- 80 = mortgage insurance threshold
('orig_ltv', 1, '<=60',    NULL, 61,   NULL, false),
('orig_ltv', 2, '61-80 and missing',   61,   81,   NULL, true),
('orig_ltv', 4, '81-95',   81,   96,   NULL, false),
('orig_ltv', 6, '>95',     96,   NULL, NULL, false),

-- 36 / 43 = standard underwriting limits; missing includes HARP / relief refis
('orig_dti', 1, '<30',     NULL, 30,   NULL, false),
('orig_dti', 3, '30-36 and missing',   30,   37,   NULL, true),
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


('num_borrowers', 1, '1',       NULL, 2,    NULL, false),
('num_borrowers', 2, '2+ or missing',      2,    NULL, NULL, true),



('delinq_history', 0, 'never',            NULL, 1,    NULL, true),
('delinq_history', 1, 'last late 25m+',   1,    2,    NULL, false),
('delinq_history', 2, 'last late 13-24m', 2,    3,    NULL, false),
('delinq_history', 3, 'worst 30d in 12m', 3,    4,    NULL, false),
('delinq_history', 4, 'worst 60d in 12m', 4,    NULL, NULL, false),

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
('ever_deferred', 2, 'yes',     NULL, NULL, '{true}',  false),

('property_state', 0, 'risk group 1', NULL, NULL,
    '{FL,NV,AZ,GA,NJ,CA,MD,IL,CT,MI,RI}', false),
('property_state', 1, 'risk group 2', NULL, NULL,
    '{MS,PR,ID,NH,ME,DC,GU,VI,NM,AL,NY}', false),
('property_state', 2, 'risk group 3', NULL, NULL,
    '{HI, DE, MA, LA, WV, WY, MO, OR, ND, WA, SD}', false),
('property_state', 3, 'risk group 4', NULL, NULL,
    '{MN, UT, OH, VA, TN, WI, NE, MT, SC, AK,AR}', false),
('property_state', 4, 'risk group 5', NULL, NULL,
    '{VT,PA,KS,NC,OK,IN,IA,KY,CO,TX}', false);



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