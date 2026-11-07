-- 35_pd_score.sql
-- Scores every snapshot row with the fitted logistic regression, builds the scorecard (points per bin),
-- a 7-grade master scale, and calibrates PD per grade to point-in-time (PIT) levels.
-- Outputs:
--   mart.scorecard : points per feature and bin (presentation table)
--   mart.pd_grade  : grade score ranges, observed default rates, TTC PD, PIT PD
--   mart.pd_score  : one row per snapshot row: log-odds, raw model PD, score, grade, calibrated 12m PD
-- Method:
--   score   = offset - factor * log-odds(bad); 600 points at good:bad odds 50:1, 20 points to double the odds
--   grades  = cut points at TRAIN score percentiles 2/5/10/25/50/75 (grade 7 = riskiest 2% of TRAIN)
--   TTC PD  = observed 12m default rate per grade over ALL observable snapshots (2006-2025: a full cycle)
--   PIT PD  = observed 12m default rate per grade over the last 8 observable quarter-ends, floored at 0.05%
--             (CRR3 retail IRB floor, applied as prudence). A single odds scalar on TTC PDs was tested and rejected:
--             it matched the portfolio level but understated grades 6-7 by ~1/3 (recent risk separation is steeper).
--   TTC PD and odds_scalar are kept for reference only.
-- Depends on: mart.snapshot_woe, mart.pd_coef, mart.binning, mart.pd_sample
-- Run from the repo root:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/30_risk/35_pd_score.sql

BEGIN;

SET LOCAL work_mem = '256MB';

-- 0. Scaling parameters and coefficients (features missing from pd_coef get coefficient 0)
DROP TABLE IF EXISTS pg_temp.params;
CREATE TEMP TABLE params AS
SELECT 20 / ln(2)                               AS factor,
       600 - (20 / ln(2)) * ln(50)              AS offset_pts,
       0.0005::double precision                 AS pd_floor,
       max(coef) FILTER (WHERE feature = 'intercept')                   AS b0,
       COALESCE(max(coef) FILTER (WHERE feature = 'credit_score'),   0) AS b_credit_score,
       COALESCE(max(coef) FILTER (WHERE feature = 'orig_ltv'),       0) AS b_orig_ltv,
       COALESCE(max(coef) FILTER (WHERE feature = 'orig_dti'),       0) AS b_orig_dti,
       COALESCE(max(coef) FILTER (WHERE feature = 'sato'),           0) AS b_sato,
       COALESCE(max(coef) FILTER (WHERE feature = 'num_borrowers'),  0) AS b_num_borrowers,
       COALESCE(max(coef) FILTER (WHERE feature = 'delinq_history'), 0) AS b_delinq_history,
       COALESCE(max(coef) FILTER (WHERE feature = 'loan_purpose'),   0) AS b_loan_purpose,
       count(*) FILTER (WHERE feature <> 'intercept')                   AS n_features
FROM mart.pd_coef;

-- 1. Scorecard: points per bin. Sum of a loan's bin points = its total score (up to rounding).
DROP TABLE IF EXISTS mart.scorecard CASCADE;
CREATE TABLE mart.scorecard AS
SELECT b.feature,
       b.bin_id,
       b.bin_label,
       round(b.woe::numeric, 4)                                              AS woe,
       round(c.coef::numeric, 4)                                             AS coef,
       round((-(c.coef * b.woe + p.b0 / p.n_features) * p.factor
              + p.offset_pts / p.n_features)::numeric)                       AS points
FROM mart.binning b
JOIN mart.pd_coef c ON c.feature = b.feature
CROSS JOIN params p
ORDER BY b.feature, b.bin_id;

-- 2. Log-odds, raw PD and score for every snapshot row
DROP TABLE IF EXISTS pg_temp.score_raw;
CREATE TEMP TABLE score_raw AS
SELECT w.loan_seq_no,
       w.snapshot_date,
       p.b0
         + p.b_credit_score   * w.woe_credit_score
         + p.b_orig_ltv       * w.woe_orig_ltv
         + p.b_orig_dti       * w.woe_orig_dti
         + p.b_sato           * w.woe_sato
         + p.b_num_borrowers  * w.woe_num_borrowers
         + p.b_delinq_history * w.woe_delinq_history
         + p.b_loan_purpose   * w.woe_loan_purpose                  AS log_odds
FROM mart.snapshot_woe w
CROSS JOIN params p;

ALTER TABLE score_raw ADD PRIMARY KEY (loan_seq_no, snapshot_date);
ANALYZE score_raw;

-- 3. Master scale: grade cut points from the TRAIN score distribution, calibration on all observable rows
DROP TABLE IF EXISTS mart.pd_grade CASCADE;
CREATE TABLE mart.pd_grade AS
WITH scored AS (
    SELECT ps.sample_split,
           ps.snapshot_date,
           ps.target::int                                   AS target,
           p.offset_pts - p.factor * s.log_odds             AS score
    FROM mart.pd_sample ps
    JOIN score_raw s USING (loan_seq_no, snapshot_date)
    CROSS JOIN params p
),
cuts AS (
    SELECT percentile_cont(ARRAY[0.02, 0.05, 0.10, 0.25, 0.50, 0.75])
               WITHIN GROUP (ORDER BY score) AS c
    FROM scored
    WHERE sample_split = 'TRAIN'
),
grades AS (   -- grade 1 = best (highest score), 7 = worst
    SELECT g.grade, g.score_lo, g.score_hi
    FROM cuts
    CROSS JOIN LATERAL (VALUES
        (7, NULL::double precision, c[1]),
        (6, c[1], c[2]),
        (5, c[2], c[3]),
        (4, c[3], c[4]),
        (3, c[4], c[5]),
        (2, c[5], c[6]),
        (1, c[6], NULL::double precision)
    ) AS g(grade, score_lo, score_hi)
),
recent AS (
    SELECT snapshot_date
    FROM mart.pd_sample
    GROUP BY snapshot_date
    ORDER BY snapshot_date DESC
    LIMIT 8
),
obs AS (
    SELECT g.grade,
           count(*)                                                     AS n_all,
           sum(s.target)                                                AS d_all,
           count(*)      FILTER (WHERE s.sample_split = 'TRAIN')        AS n_train,
           sum(s.target) FILTER (WHERE s.sample_split = 'TRAIN')        AS d_train,
           count(*)      FILTER (WHERE s.sample_split = 'OOT')          AS n_oot,
           sum(s.target) FILTER (WHERE s.sample_split = 'OOT')          AS d_oot,
           count(*)      FILTER (WHERE s.snapshot_date IN (SELECT snapshot_date FROM recent)) AS n_recent,
           sum(s.target) FILTER (WHERE s.snapshot_date IN (SELECT snapshot_date FROM recent)) AS d_recent
    FROM scored s
    JOIN grades g
      ON (g.score_lo IS NULL OR s.score >= g.score_lo)
     AND (g.score_hi IS NULL OR s.score <  g.score_hi)
    GROUP BY g.grade
),
portfolio AS (   -- scalar in odds space: recent conditions vs long-run average
    SELECT sum(d_all)::double precision    / sum(n_all)    AS dr_long_run,
           sum(d_recent)::double precision / sum(n_recent) AS dr_recent
    FROM obs
),
cal AS (
    SELECT o.*,
           pf.dr_long_run,
           pf.dr_recent,
           o.d_all::double precision / NULLIF(o.n_all, 0)              AS pd_ttc,
           (pf.dr_recent / (1 - pf.dr_recent))
             / (pf.dr_long_run / (1 - pf.dr_long_run))                  AS odds_scalar
    FROM obs o
    CROSS JOIN portfolio pf
)
SELECT g.grade,
       g.score_lo,
       g.score_hi,
       c.n_all,
       c.d_all,
       c.d_train::double precision  / NULLIF(c.n_train, 0)   AS dr_train,
       c.d_oot::double precision    / NULLIF(c.n_oot, 0)     AS dr_oot,
       c.d_recent::double precision / NULLIF(c.n_recent, 0)  AS dr_recent,
       c.n_oot,
       c.d_oot,
       c.pd_ttc,
       c.odds_scalar,
       c.n_recent,
       c.d_recent,
       greatest(
           c.d_recent::double precision / NULLIF(c.n_recent, 0),
           p.pd_floor
       )                                                      AS pd_pit
FROM grades g
JOIN cal c USING (grade)
CROSS JOIN params p
ORDER BY g.grade;

ALTER TABLE mart.pd_grade ADD PRIMARY KEY (grade);

-- 4. Final PD per snapshot row
DROP TABLE IF EXISTS mart.pd_score CASCADE;
CREATE TABLE mart.pd_score AS
SELECT s.loan_seq_no,
       s.snapshot_date,
       s.log_odds,
       1 / (1 + exp(-s.log_odds))                       AS pd_raw,
       p.offset_pts - p.factor * s.log_odds             AS score,
       g.grade,
       g.pd_pit                                         AS pd_12m
FROM score_raw s
CROSS JOIN params p
JOIN mart.pd_grade g
  ON (g.score_lo IS NULL OR p.offset_pts - p.factor * s.log_odds >= g.score_lo)
 AND (g.score_hi IS NULL OR p.offset_pts - p.factor * s.log_odds <  g.score_hi);

ALTER TABLE mart.pd_score ADD PRIMARY KEY (loan_seq_no, snapshot_date);
ANALYZE mart.pd_score;

COMMIT;

-- Report 1: master scale. dr_* must increase from grade 1 to 7; pd_pit is the PD used for staging and ECL.
SELECT grade,
       round(score_lo::numeric)                AS score_from,
       round(score_hi::numeric)                AS score_to,
       n_all,
       round(100 * dr_train::numeric, 3)       AS dr_train_pct,
       round(100 * dr_oot::numeric, 3)         AS dr_oot_pct,
       round(100 * dr_recent::numeric, 3)      AS dr_recent_pct,
       round(100 * pd_ttc::numeric, 3)         AS pd_ttc_pct,
       round(100 * pd_pit::numeric, 3)         AS pd_pit_pct,
       round(odds_scalar::numeric, 3)          AS odds_scalar
FROM mart.pd_grade
ORDER BY grade;

-- Report 2: OOT consistency check per grade (expected = PIT PD x rows).
-- Circular since PIT PDs are estimated on the last 8 quarters, which lie inside OOT.
SELECT grade,
       n_oot,
       d_oot                                   AS defaults_observed,
       round((pd_pit * n_oot)::numeric)        AS defaults_expected,
       round((d_oot / NULLIF(pd_pit * n_oot, 0))::numeric, 2) AS observed_to_expected
FROM mart.pd_grade
ORDER BY grade;

-- Report 3: every snapshot row scored exactly once (the two counts must match)
SELECT (SELECT count(*) FROM mart.pd_score)     AS pd_score_rows,
       (SELECT count(*) FROM mart.snapshot_woe) AS snapshot_rows;