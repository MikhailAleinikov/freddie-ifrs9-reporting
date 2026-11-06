-- 31_bin_def.sql
-- Bin definitions (cut points) for the PD scorecard. These are DECISIONS, maintained by hand;
-- 32_binning.sql computes the statistics from them. Rationale per feature: docs/assumptions.md.
-- Conventions:
--   numeric bins     : lo <= x < hi, NULL = open end; bin_id 1..n in increasing value order
--   categorical bins : cat_values lists the codes exactly as stored
--   missing values   : either a separate bin 0 (is_missing = true, no range/codes),
--                      or is_missing = true on the bin they were merged into
-- Run from the repo root:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/30_risk/31_bin_def.sql

BEGIN;

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
-- 620 = subprime line, 740+ = top pricing tier; missing merged into <620 (closest default rate)
('credit_score', 1, '<620 or missing',    NULL, 620,  NULL, true),
('credit_score', 2, '620-659',            620,  660,  NULL, false),
('credit_score', 3, '660-699',            660,  700,  NULL, false),
('credit_score', 4, '700-739',            700,  740,  NULL, false),
('credit_score', 5, '740-779',            740,  780,  NULL, false),
('credit_score', 6, '780+',               780,  NULL, NULL, false),

-- 61-80 merged (no difference); 81-95 merged (pooled dip at 91-95 is an era/purpose mix effect)
('orig_ltv', 1, '<=60',                   NULL, 61,   NULL, false),
('orig_ltv', 2, '61-80 or missing',       61,   81,   NULL, true),
('orig_ltv', 3, '81-95',                  81,   96,   NULL, false),
('orig_ltv', 4, '>95',                    96,   NULL, NULL, false),

-- missing (relief refis, no-ratio loans) merged into 30-36 (closest default rate)
('orig_dti', 1, '<30',                    NULL, 30,   NULL, false),
('orig_dti', 2, '30-36 or missing',       30,   37,   NULL, true),
('orig_dti', 3, '37-43',                  37,   44,   NULL, false),
('orig_dti', 4, '44-50',                  44,   51,   NULL, false),
('orig_dti', 5, '>50',                    51,   NULL, NULL, false),

-- rate minus median rate of the same origination quarter, in percentage points
('sato', 0, 'missing',                    NULL,  NULL,  NULL, true),
('sato', 1, '<-0.25',                     NULL,  -0.25, NULL, false),
('sato', 2, '-0.25 to 0',                 -0.25, 0,     NULL, false),
('sato', 3, '0 to 0.25',                  0,     0.25,  NULL, false),
('sato', 4, '0.25 to 0.5',                0.25,  0.5,   NULL, false),
('sato', 5, '0.5+',                       0.5,   NULL,  NULL, false),

-- missing (415 rows, 0 defaults) merged into the modal bin
('num_borrowers', 1, '1',                 NULL, 2,    NULL, false),
('num_borrowers', 2, '2+ or missing',     2,    NULL, NULL, true),

-- ===== behavioural =====
-- bin 2 = last late 12-24 months ago (12-row window covers t-11..t)
('delinq_history', 0, 'never',            NULL, 1,    NULL, true),
('delinq_history', 1, 'last late 25m+',   1,    2,    NULL, false),
('delinq_history', 2, 'last late 12-24m', 2,    3,    NULL, false),
('delinq_history', 3, 'worst 30d in 12m', 3,    4,    NULL, false),
('delinq_history', 4, 'worst 60d in 12m', 4,    NULL, NULL, false),

-- ===== categorical =====
-- P = purchase, C = cash-out refi, N = no cash-out refi, R = unspecified refi (merged with N)
('loan_purpose', 0, 'missing',            NULL, NULL, NULL,    true),
('loan_purpose', 1, 'P',                  NULL, NULL, '{P}',   false),
('loan_purpose', 2, 'C',                  NULL, NULL, '{C}',   false),
('loan_purpose', 3, 'N+R',                NULL, NULL, '{N,R}', false),

-- B+T: broker / TPO not specified (T only exists pre-2009); R+C: retail / correspondent
('channel', 1, 'retail/correspondent or missing', NULL, NULL, '{R,C}', true),
('channel', 2, 'broker/TPO unspecified',          NULL, NULL, '{B,T}', false),

-- tiers by shrunk TRAIN default rate, 1 = riskiest; NULL state assigned to the middle tier
('property_state', 1, 'risk group 1', NULL, NULL, '{FL,NV,AZ,GA,NJ,CA,MD,IL,CT,MI,RI}', false),
('property_state', 2, 'risk group 2', NULL, NULL, '{MS,PR,ID,NH,ME,DC,GU,VI,NM,AL,NY}', false),
('property_state', 3, 'risk group 3', NULL, NULL, '{HI,DE,MA,LA,WV,WY,MO,OR,ND,WA,SD}', true),
('property_state', 4, 'risk group 4', NULL, NULL, '{MN,UT,OH,VA,TN,WI,NE,MT,SC,AK,AR}', false),
('property_state', 5, 'risk group 5', NULL, NULL, '{VT,PA,KS,NC,OK,IN,IA,KY,CO,TX}',    false);

ANALYZE mart.bin_def;

COMMIT;

-- overview: bins per feature (expect 9 features)
SELECT feature, count(*) AS bins, bool_or(is_missing) AS has_missing_bin
FROM mart.bin_def
GROUP BY feature
ORDER BY feature;