-- 21_default_evet.sql
-- collects all the defaulted loans into one table
-- Run from the repo root:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/20_core/21_default_event.sql

DROP TABLE IF EXISTS core.default_event CASCADE;
CREATE TABLE core.default_event AS
    SELECT DISTINCT ON (loan_seq_no)
        loan_seq_no,
        period AS default_date,
        CASE WHEN is_credit_event_zb THEN 'ZB_'||zero_balance_code
            WHEN is_reo_acq THEN 'REO'
            WHEN delinquency_months >= 3 THEN 'DPD90'
            END AS defaul_trigger,
        delinquency_months,
        is_reo_acq,
        is_credit_event_zb,
        zero_balance_code,
        zero_balance_date
    FROM core.loan_month lm
    WHERE ((delinquency_months >= 3 OR is_reo_acq OR is_credit_event_zb)
      AND NOT EXISTS (
    SELECT 1 FROM core.perf d
    WHERE d.loan_seq_no = lm.loan_seq_no
      AND d.is_defect
    ))
    ORDER BY loan_seq_no, period;