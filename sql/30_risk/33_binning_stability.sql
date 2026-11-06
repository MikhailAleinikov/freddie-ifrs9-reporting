-- 33_binning_stability.sql
-- Stability of the TRAIN bins across splits (TRAIN, TEST, COVID, OOT).
-- Same bins (mart.bin_def) and same method as 32_binning.sql, computed per split, compared with TRAIN:
--   iv            : information value within the split (own WoE, for diagnosis only - scoring always uses TRAIN WoE)
--   psi           : population stability index vs TRAIN, sum((a - e) * ln(a / e)) over bin shares
--   rank_corr     : correlation of bin default-rate ranks, split vs TRAIN, over bins with >= 30 defaults
--   riskiest_bin_holds : the bin with the highest default rate in TRAIN is also the highest in the split
-- Reading: TEST should look like TRAIN (rank_corr ~1, psi ~0). OOT decides keep/drop:
--   ranking must hold (rank_corr >= ~0.8, riskiest bin unchanged) and iv should stay >= 0.02.
--   High PSI alone is NOT a reason to drop (the book changed); a flipped ranking is.
-- Depends on: mart.pd_sample, mart.bin_def
-- Run from the repo root:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/30_risk/33_binning_stability.sql

BEGIN;

SET LOCAL work_mem = '256MB';

-- 1. Per-value counts per split, unpivoted to long format (one scan of mart.pd_sample)
DROP TABLE IF EXISTS pg_temp.stab_long;
CREATE TEMP TABLE stab_long AS
WITH agg AS (
    SELECT
        sample_split,
        credit_score, orig_ltv, orig_dti, sato, num_borrowers, delinq_history,
        loan_purpose,
        GROUPING(credit_score)    AS g_credit_score,
        GROUPING(orig_ltv)        AS g_orig_ltv,
        GROUPING(orig_dti)        AS g_orig_dti,
        GROUPING(sato)            AS g_sato,
        GROUPING(num_borrowers)   AS g_num_borrowers,
        GROUPING(delinq_history)  AS g_delinq_history,
        GROUPING(loan_purpose)    AS g_loan_purpose,
        count(*) FILTER (WHERE NOT target) AS goods,
        count(*) FILTER (WHERE target)     AS bads
    FROM mart.pd_sample
    GROUP BY GROUPING SETS (
        (sample_split, credit_score),   (sample_split, orig_ltv),       (sample_split, orig_dti),
        (sample_split, sato),           (sample_split, num_borrowers),  (sample_split, delinq_history),
        (sample_split, loan_purpose)
    )
)
SELECT a.sample_split, v.feature, v.num_val, v.cat_val, a.goods, a.bads
FROM agg a
CROSS JOIN LATERAL (VALUES
    ('credit_score',   a.g_credit_score,   a.credit_score::numeric,   NULL::text),
    ('orig_ltv',       a.g_orig_ltv,       a.orig_ltv::numeric,       NULL),
    ('orig_dti',       a.g_orig_dti,       a.orig_dti::numeric,       NULL),
    ('sato',           a.g_sato,           a.sato,                    NULL),
    ('num_borrowers',  a.g_num_borrowers,  a.num_borrowers::numeric,  NULL),
    ('delinq_history', a.g_delinq_history, a.delinq_history::numeric, NULL),
    ('loan_purpose',   a.g_loan_purpose,   NULL, a.loan_purpose)
) AS v(feature, g, num_val, cat_val)
WHERE v.g = 0;

-- 2. Per-bin statistics per split, with TRAIN reference values
DROP TABLE IF EXISTS mart.binning_stability CASCADE;
CREATE TABLE mart.binning_stability AS
WITH matched AS (
    SELECT l.sample_split, d.feature, d.bin_id,
           sum(l.goods) AS goods,
           sum(l.bads)  AS bads
    FROM stab_long l
    JOIN mart.bin_def d
      ON d.feature = l.feature
     AND CASE
           WHEN l.num_val IS NULL AND l.cat_val IS NULL THEN d.is_missing
           WHEN d.cat_values IS NOT NULL                THEN l.cat_val = ANY (d.cat_values)
           WHEN d.lo IS NOT NULL OR d.hi IS NOT NULL    THEN (d.lo IS NULL OR l.num_val >= d.lo)
                                                         AND (d.hi IS NULL OR l.num_val <  d.hi)
           ELSE false
         END
    GROUP BY l.sample_split, d.feature, d.bin_id
),
grid AS (   -- every bin in every split, so bins that are empty in a split still count (PSI)
    SELECT s.sample_split, d.feature, d.bin_id, d.bin_label
    FROM mart.bin_def d
    CROSS JOIN (SELECT DISTINCT sample_split FROM mart.pd_sample) s
),
b AS (
    SELECT g.sample_split, g.feature, g.bin_id, g.bin_label,
           COALESCE(m.goods, 0) AS goods,
           COALESCE(m.bads,  0) AS bads
    FROM grid g
    LEFT JOIN matched m
      ON m.sample_split = g.sample_split AND m.feature = g.feature AND m.bin_id = g.bin_id
),
t AS (
    SELECT b.*,
           b.goods + b.bads                                                         AS n,
           (b.goods + 0.5)          / sum(b.goods + 0.5)          OVER w             AS pg,
           (b.bads  + 0.5)          / sum(b.bads  + 0.5)          OVER w             AS pb,
           (b.goods + b.bads + 0.5) / sum(b.goods + b.bads + 0.5) OVER w             AS share_smoothed
    FROM b
    WINDOW w AS (PARTITION BY b.sample_split, b.feature)
),
stats AS (
    SELECT t.sample_split, t.feature, t.bin_id, t.bin_label,
           t.goods, t.bads, t.n,
           100.0 * t.n / NULLIF(sum(t.n) OVER (PARTITION BY t.sample_split, t.feature), 0) AS pct_pop,
           100.0 * t.bads / NULLIF(t.n, 0)                                                 AS default_rate_pct,
           ln(t.pg / t.pb)                                                                 AS woe,
           (t.pg - t.pb) * ln(t.pg / t.pb)                                                 AS iv_part,
           t.share_smoothed
    FROM t
)
SELECT s.sample_split,
       s.feature,
       s.bin_id,
       s.bin_label,
       s.goods,
       s.bads,
       s.n,
       s.pct_pop,
       s.default_rate_pct,
       s.woe,
       s.iv_part,
       sum(s.iv_part) OVER (PARTITION BY s.sample_split, s.feature)                      AS iv_total,
       tr.pct_pop                                                                        AS train_pct_pop,
       tr.default_rate_pct                                                               AS train_default_rate_pct,
       tr.woe                                                                            AS train_woe,
       (s.share_smoothed - tr.share_smoothed) * ln(s.share_smoothed / tr.share_smoothed) AS psi_part
FROM stats s
JOIN stats tr
  ON tr.sample_split = 'TRAIN'
 AND tr.feature      = s.feature
 AND tr.bin_id       = s.bin_id;

ALTER TABLE mart.binning_stability ADD PRIMARY KEY (sample_split, feature, bin_id);

-- 3. One row per split and feature
DROP TABLE IF EXISTS mart.binning_stability_summary CASCADE;
CREATE TABLE mart.binning_stability_summary AS
WITH ranked AS (   -- ranks over bins with enough defaults in the split to be meaningful
    SELECT s.sample_split, s.feature,
           rank() OVER (PARTITION BY s.sample_split, s.feature ORDER BY s.default_rate_pct)       AS r_split,
           rank() OVER (PARTITION BY s.sample_split, s.feature ORDER BY s.train_default_rate_pct) AS r_train
    FROM mart.binning_stability s
    WHERE s.bads >= 30
),
rc AS (
    SELECT sample_split, feature,
           corr(r_split, r_train) AS rank_corr
    FROM ranked
    GROUP BY sample_split, feature
),
agg AS (
    SELECT sample_split, feature,
           max(iv_total)                         AS iv,
           sum(psi_part)                         AS psi,
           count(*) FILTER (WHERE n > 0)         AS bins_populated,
           count(*) FILTER (WHERE bads >= 30)    AS bins_reliable,
           (array_agg(bin_id ORDER BY default_rate_pct DESC NULLS LAST)
                FILTER (WHERE bads >= 30))[1]    AS riskiest_bin,
           (array_agg(bin_id ORDER BY train_default_rate_pct DESC NULLS LAST)
                FILTER (WHERE bads >= 30))[1]    AS train_riskiest_bin
    FROM mart.binning_stability
    GROUP BY sample_split, feature
)
SELECT a.sample_split,
       a.feature,
       a.iv,
       tr.iv                                           AS train_iv,
       a.iv / NULLIF(tr.iv, 0)                         AS iv_ratio,
       a.psi,
       rc.rank_corr,
       a.riskiest_bin = a.train_riskiest_bin           AS riskiest_bin_holds,
       a.bins_populated,
       a.bins_reliable,
       CASE
           WHEN a.sample_split = 'TRAIN'                                  THEN NULL
           WHEN rc.rank_corr IS NULL                                      THEN 'review: too few defaults'
           WHEN rc.rank_corr < 0.5 OR a.iv < 0.02                         THEN 'drop candidate'
           WHEN rc.rank_corr >= 0.8 AND a.riskiest_bin = a.train_riskiest_bin THEN 'stable'
           ELSE                                                                'review'
       END                                             AS verdict
FROM agg a
JOIN agg tr
  ON tr.sample_split = 'TRAIN' AND tr.feature = a.feature
LEFT JOIN rc
  ON rc.sample_split = a.sample_split AND rc.feature = a.feature;

ALTER TABLE mart.binning_stability_summary ADD PRIMARY KEY (sample_split, feature);

ANALYZE mart.binning_stability;
ANALYZE mart.binning_stability_summary;

COMMIT;

-- =====================================================================
-- 4. Check: every feature covers every row of each split (no holes, no overlaps). Must return no rows.
-- =====================================================================
SELECT b.sample_split, b.feature, sum(b.n) AS rows_binned, c.rows_in_split
FROM mart.binning_stability b
JOIN (SELECT sample_split, count(*) AS rows_in_split FROM mart.pd_sample GROUP BY 1) c
  USING (sample_split)
GROUP BY b.sample_split, b.feature, c.rows_in_split
HAVING sum(b.n) <> c.rows_in_split;

-- =====================================================================
-- 5. Reports
-- =====================================================================

-- 5a. Overview: one row per feature, splits side by side
SELECT feature,
       round(max(iv)        FILTER (WHERE sample_split = 'TRAIN'), 3) AS iv_train,
       round(max(iv)        FILTER (WHERE sample_split = 'TEST'),  3) AS iv_test,
       round(max(iv)        FILTER (WHERE sample_split = 'COVID'), 3) AS iv_covid,
       round(max(iv)        FILTER (WHERE sample_split = 'OOT'),   3) AS iv_oot,
       round(max(psi)       FILTER (WHERE sample_split = 'OOT'),   3) AS psi_oot,
       round(max(rank_corr) FILTER (WHERE sample_split = 'OOT')::numeric, 2) AS rank_corr_oot,
       bool_or(riskiest_bin_holds) FILTER (WHERE sample_split = 'OOT')      AS riskiest_holds_oot,
       max(verdict)         FILTER (WHERE sample_split = 'OOT')            AS verdict_oot
FROM mart.binning_stability_summary
GROUP BY feature
ORDER BY iv_train DESC;

-- 5b. Bin detail TRAIN vs OOT (and COVID), for features that are not 'stable'
SELECT s.feature, s.bin_id, s.bin_label,
       round(s.train_pct_pop, 1)            AS pct_train,
       round(s.pct_pop, 1)                  AS pct_oot,
       round(s.train_default_rate_pct, 2)   AS dr_train,
       round(s.default_rate_pct, 2)         AS dr_oot,
       round(c.default_rate_pct, 2)         AS dr_covid,
       s.bads                               AS bads_oot
FROM mart.binning_stability s
JOIN mart.binning_stability c
  ON c.sample_split = 'COVID' AND c.feature = s.feature AND c.bin_id = s.bin_id
JOIN mart.binning_stability_summary m
  ON m.sample_split = 'OOT' AND m.feature = s.feature
WHERE s.sample_split = 'OOT'
  AND m.verdict IS DISTINCT FROM 'stable'
ORDER BY s.feature, s.bin_id;