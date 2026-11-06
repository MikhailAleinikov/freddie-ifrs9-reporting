-- 32_binning.sql
-- Fine/coarse classing results: goods, bads, WoE and IV per (feature, bin), computed on TRAIN only.
-- Bin cut points come from mart.bin_def (hand-maintained decisions); this file only computes results.
-- Method: aggregate first (one scan with GROUPING SETS -> per-value counts), bin second (small join).
-- Features excluded on purpose:
--   vintage                -> encodes "crisis or not", does not generalise
--   orig_interest_rate     -> replaced by sato (rate minus median rate of the same origination quarter)
--   months_since_last_90   -> always NULL in the PD sample (ever-90+ loans have has_defaulted = true)
--   delinquency_months     -> duplicate of dpd_bucket
-- Depends on: mart.pd_sample, mart.bin_def, core.orig
-- Run from the repo root:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/30_risk/32_binning.sql

SET work_mem = '256MB';

-- 1. Per-value counts on TRAIN, unpivoted to long format (a few thousand rows)
DROP TABLE IF EXISTS pg_temp.binning_long;
CREATE TEMP TABLE binning_long AS
WITH orig_q AS (
    SELECT substring(loan_seq_no FROM 2 FOR 4)                          AS orig_qtr,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY orig_interest_rate) AS median_rate
    FROM core.orig
    GROUP BY 1
),
base AS (
    SELECT ps.credit_score,
           ps.orig_ltv,
           ps.current_ltv,
           ps.orig_dti,
           round((ps.orig_interest_rate - q.median_rate)::numeric, 2)  AS sato,
           ps.months_on_books,
           ps.months_since_last_del,
           ps.max_delinq_12m,
           round(ps.ead::numeric, -3)                                   AS ead_k,
           ps.num_borrowers,
           ps.dpd_bucket,
           ps.occupancy_status,
           ps.loan_purpose,
           ps.channel,
           ps.property_state,
           ps.first_time_homebuyer,
           ps.is_forbearance,
           ps.ever_modified,
           ps.ever_deferred,
           ps.target
    FROM mart.pd_sample ps
    JOIN orig_q q ON q.orig_qtr = substring(ps.loan_seq_no FROM 2 FOR 4)
    WHERE ps.sample_split = 'TRAIN'
),
agg AS (
    SELECT
        credit_score, orig_ltv, current_ltv, orig_dti, sato, months_on_books,
        months_since_last_del, max_delinq_12m, ead_k, num_borrowers,
        dpd_bucket, occupancy_status, loan_purpose, channel, property_state,
        first_time_homebuyer, is_forbearance, ever_modified, ever_deferred,
        GROUPING(credit_score)          AS g_credit_score,
        GROUPING(orig_ltv)              AS g_orig_ltv,
        GROUPING(current_ltv)           AS g_current_ltv,
        GROUPING(orig_dti)              AS g_orig_dti,
        GROUPING(sato)                  AS g_sato,
        GROUPING(months_on_books)       AS g_months_on_books,
        GROUPING(months_since_last_del) AS g_months_since_last_del,
        GROUPING(max_delinq_12m)        AS g_max_delinq_12m,
        GROUPING(ead_k)                 AS g_ead,
        GROUPING(num_borrowers)         AS g_num_borrowers,
        GROUPING(dpd_bucket)            AS g_dpd_bucket,
        GROUPING(occupancy_status)      AS g_occupancy_status,
        GROUPING(loan_purpose)          AS g_loan_purpose,
        GROUPING(channel)               AS g_channel,
        GROUPING(property_state)        AS g_property_state,
        GROUPING(first_time_homebuyer)  AS g_first_time_homebuyer,
        GROUPING(is_forbearance)        AS g_is_forbearance,
        GROUPING(ever_modified)         AS g_ever_modified,
        GROUPING(ever_deferred)         AS g_ever_deferred,
        count(*) FILTER (WHERE NOT target) AS goods,
        count(*) FILTER (WHERE target)     AS bads
    FROM base
    GROUP BY GROUPING SETS (
        (credit_score), (orig_ltv), (current_ltv), (orig_dti), (sato), (months_on_books),
        (months_since_last_del), (max_delinq_12m), (ead_k), (num_borrowers),
        (dpd_bucket), (occupancy_status), (loan_purpose), (channel), (property_state),
        (first_time_homebuyer), (is_forbearance), (ever_modified), (ever_deferred)
    )
)
SELECT v.feature, v.num_val, v.cat_val, a.goods, a.bads
FROM agg a
CROSS JOIN LATERAL (VALUES
    ('credit_score',          a.g_credit_score,          a.credit_score::numeric,          NULL::text),
    ('orig_ltv',              a.g_orig_ltv,              a.orig_ltv::numeric,              NULL),
    ('current_ltv',           a.g_current_ltv,           a.current_ltv::numeric,           NULL),
    ('orig_dti',              a.g_orig_dti,              a.orig_dti::numeric,              NULL),
    ('sato',                  a.g_sato,                  a.sato,                           NULL),
    ('months_on_books',       a.g_months_on_books,       a.months_on_books::numeric,       NULL),
    ('months_since_last_del', a.g_months_since_last_del, a.months_since_last_del::numeric, NULL),
    ('max_delinq_12m',        a.g_max_delinq_12m,        a.max_delinq_12m::numeric,        NULL),
    ('ead',                   a.g_ead,                   a.ead_k,                          NULL),
    ('num_borrowers',         a.g_num_borrowers,         a.num_borrowers::numeric,         NULL),
    ('dpd_bucket',            a.g_dpd_bucket,            NULL, a.dpd_bucket),
    ('occupancy_status',      a.g_occupancy_status,      NULL, a.occupancy_status),
    ('loan_purpose',          a.g_loan_purpose,          NULL, a.loan_purpose),
    ('channel',               a.g_channel,               NULL, a.channel),
    ('property_state',        a.g_property_state,        NULL, a.property_state),
    ('first_time_homebuyer',  a.g_first_time_homebuyer,  NULL, a.first_time_homebuyer::text),
    ('is_forbearance',        a.g_is_forbearance,        NULL, a.is_forbearance::text),
    ('ever_modified',         a.g_ever_modified,         NULL, a.ever_modified::text),
    ('ever_deferred',         a.g_ever_deferred,         NULL, a.ever_deferred::text)
) AS v(feature, g, num_val, cat_val)
WHERE v.g = 0;

-- 2. Bin statistics, WoE, IV and quality flags
DROP TABLE IF EXISTS mart.binning CASCADE;
CREATE TABLE mart.binning AS
WITH b AS (
    SELECT d.feature, d.bin_id, d.bin_label,
           (d.lo IS NOT NULL OR d.hi IS NOT NULL) AS is_numeric_bin,
           sum(l.goods) AS goods,
           sum(l.bads)  AS bads
    FROM binning_long l
    JOIN mart.bin_def d
      ON d.feature = l.feature
          AND CASE
           WHEN l.num_val IS NULL AND l.cat_val IS NULL THEN d.is_missing
           WHEN d.cat_values IS NOT NULL                THEN l.cat_val = ANY (d.cat_values)
           WHEN d.lo IS NOT NULL OR d.hi IS NOT NULL    THEN (d.lo IS NULL OR l.num_val >= d.lo)
                                                         AND (d.hi IS NULL OR l.num_val <  d.hi)
           ELSE false
         END
    GROUP BY d.feature, d.bin_id, d.bin_label, is_numeric_bin
),
t AS (
    SELECT b.*,
           (b.goods + 0.5) / sum(b.goods + 0.5) OVER (PARTITION BY b.feature) AS pg,   -- +0.5 avoids ln(0)
           (b.bads  + 0.5) / sum(b.bads  + 0.5) OVER (PARTITION BY b.feature) AS pb
    FROM b
),
stats AS (
    SELECT t.feature, t.bin_id, t.bin_label, t.is_numeric_bin,
           t.goods, t.bads,
           t.goods + t.bads                                                            AS n,
           100.0 * (t.goods + t.bads) / sum(t.goods + t.bads) OVER (PARTITION BY t.feature) AS pct_pop,
           100.0 * t.bads / NULLIF(t.goods + t.bads, 0)                                AS default_rate_pct,
           ln(t.pg / t.pb)                                                             AS woe,
           (t.pg - t.pb) * ln(t.pg / t.pb)                                             AS iv_part,
           sum((t.pg - t.pb) * ln(t.pg / t.pb)) OVER (PARTITION BY t.feature)          AS iv_total
    FROM t
),
mono AS (   -- numeric bins only, in bin_id order (bin_id must follow increasing values)
    SELECT feature,
           bool_and(diff >= 0) OR bool_and(diff <= 0) AS monotonic
    FROM (
        SELECT s.feature,
               s.default_rate_pct - lag(s.default_rate_pct)
                   OVER (PARTITION BY s.feature ORDER BY s.bin_id) AS diff
        FROM stats s
        WHERE s.is_numeric_bin
    ) x
    WHERE diff IS NOT NULL
    GROUP BY feature
)
SELECT s.feature,
       s.bin_id,
       s.bin_label,
       s.goods,
       s.bads,
       s.n,
       s.pct_pop,
       s.default_rate_pct,
       s.woe,
       s.iv_part,
       s.iv_total,
       CASE WHEN s.iv_total < 0.02 THEN 'useless'
            WHEN s.iv_total < 0.1  THEN 'weak'
            WHEN s.iv_total < 0.3  THEN 'medium'
            WHEN s.iv_total < 0.5  THEN 'strong'
            ELSE                        'suspicious'
       END                    AS iv_strength,
       s.pct_pop < 5          AS flag_small_bin,
       s.bads < 30            AS flag_few_bads,
       m.monotonic            AS feature_monotonic   -- NULL for purely categorical features
FROM stats s
LEFT JOIN mono m USING (feature);

ALTER TABLE mart.binning ADD PRIMARY KEY (feature, bin_id);
ANALYZE mart.binning;

-- 3. Checks (both must return no rows)

-- 3a. Values that fall into no bin (holes in bin_def, or wrong cat_values spelling)
SELECT l.feature, sum(l.goods + l.bads) AS unmatched_rows
FROM binning_long l
LEFT JOIN mart.bin_def d
  ON d.feature = l.feature
      AND CASE
           WHEN l.num_val IS NULL AND l.cat_val IS NULL THEN d.is_missing
           WHEN d.cat_values IS NOT NULL                THEN l.cat_val = ANY (d.cat_values)
           WHEN d.lo IS NOT NULL OR d.hi IS NOT NULL    THEN (d.lo IS NULL OR l.num_val >= d.lo)
                                                         AND (d.hi IS NULL OR l.num_val <  d.hi)
           ELSE false
         END
WHERE d.feature IS NULL
GROUP BY l.feature;

-- 3b. Every feature must cover the same number of TRAIN rows (catches holes AND overlapping bins)
SELECT feature, sum(n) AS rows_binned,
       (SELECT count(*) FROM mart.pd_sample WHERE sample_split = 'TRAIN') AS train_rows
FROM mart.binning
GROUP BY feature
HAVING sum(n) <> (SELECT count(*) FROM mart.pd_sample WHERE sample_split = 'TRAIN');

-- 4. Reports for coarse classing

-- 4a. Feature ranking
SELECT feature, round(max(iv_total), 4) AS iv, max(iv_strength) AS strength,
       bool_or(flag_small_bin) AS has_small_bin, bool_or(flag_few_bads) AS has_few_bads_bin,
       bool_and(feature_monotonic) AS monotonic
FROM mart.binning
GROUP BY feature
ORDER BY iv DESC;

-- 4b. Bins that need merging
SELECT feature, bin_id, bin_label, n, round(pct_pop, 1) AS pct_pop, bads,
       round(default_rate_pct, 3) AS dr_pct, round(woe, 3) AS woe
FROM mart.binning
WHERE flag_small_bin OR flag_few_bads
ORDER BY feature, bin_id;