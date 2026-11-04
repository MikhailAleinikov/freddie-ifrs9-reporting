-- 20_loan_month.sql
-- Augments the data with derived columns >> core.loan_month
-- Run from the repo root:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/20_core/20_loan_month.sql


CREATE TABLE core.loan_month AS
SELECT
    p.*,
    o.vintage, o.credit_score, o.orig_ltv, o.orig_dti, o.orig_interest_rate,
    o.occupancy_status, o.loan_purpose, o.property_state, o.orig_upb,

    LAG(p.delinquency_months) OVER w                          AS prev_delinquency_months,

  -- worst delinquency in the last 12 months
    MAX(p.delinquency_months) OVER (w ROWS BETWEEN 11 PRECEDING AND CURRENT ROW)
                                                            AS max_delinq_12m,

  -- most recent month with any delinquency, up to now
    MAX(CASE WHEN p.delinquency_months >= 1 THEN p.period END)
      OVER (w ROWS UNBOUNDED PRECEDING)                     AS last_delinq_period,

    BOOL_OR(p.modification_flag IN ('Y','P'))
      OVER (w ROWS UNBOUNDED PRECEDING)                     AS ever_modified,
    BOOL_OR(p.payment_deferral_flag IN ('C','P'))
      OVER (w ROWS UNBOUNDED PRECEDING)                     AS ever_deferred,

  -- current LTV: ELTV if available, otherwise recomputed
    COALESCE(p.eltv,
           round(p.current_upb * o.orig_ltv / NULLIF(o.orig_upb, 0)))
                                                            AS current_ltv,
    

FROM core.perf p
JOIN core.orig o USING (loan_seq_no)
WINDOW w AS (PARTITION BY loan_seq_no ORDER BY period);