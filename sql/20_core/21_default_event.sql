-- 21_default_event.sql
-- First default per loan (CRR Art. 178: 90+ DPD, REO acquisition, or credit-event zero balance).
-- Defect loans are KEPT: the borrower default is real; only the loss moved to the seller.
-- loan_has_defect is an OUTCOME flag for LGD exclusion only. Never use it as a feature.
-- Run from the repo root:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/20_core/21_default_event.sql

DROP TABLE IF EXISTS core.default_event CASCADE;
CREATE TABLE core.default_event AS
SELECT DISTINCT ON (lm.loan_seq_no)
    lm.loan_seq_no,
    lm.period AS default_date,
    CASE WHEN lm.is_credit_event_zb      THEN 'ZB_' || lm.zero_balance_code
         WHEN lm.is_reo_acq              THEN 'REO'
         WHEN lm.delinquency_months >= 3 THEN 'DPD90'
    END AS default_trigger,
    COALESCE(NULLIF(lm.current_upb, 0), lm.zero_balance_removal_upb) AS ead_at_default,
    lm.delinquency_months,
    lm.is_reo_acq,
    lm.is_credit_event_zb,
    lm.zero_balance_code,
    lm.zero_balance_date,
    EXISTS (SELECT 1 FROM core.perf d
            WHERE d.loan_seq_no = lm.loan_seq_no AND d.is_defect) AS loan_has_defect
FROM core.loan_month lm
WHERE lm.delinquency_months >= 3 OR lm.is_reo_acq OR lm.is_credit_event_zb
ORDER BY lm.loan_seq_no, lm.period;

ALTER TABLE core.default_event ADD PRIMARY KEY (loan_seq_no);
ANALYZE core.default_event;

DROP TABLE IF EXISTS core.default_event CASCADE;
CREATE TABLE core.default_event AS
    SELECT DISTINCT ON (loan_seq_no)
        lm.loan_seq_no,
        lm.period AS default_date,
        CASE WHEN lm.is_credit_event_zb      THEN 'ZB_' || lm.zero_balance_code
             WHEN lm.is_reo_acq              THEN 'REO'
             WHEN lm.delinquency_months >= 3 THEN 'DPD90'
        END AS default_trigger,
        COALESCE(NULLIF(lm.current_upb, 0), lm.zero_balance_removal_upb) AS ead_at_default,
        lm.delinquency_months,
        lm.is_reo_acq,
        lm.is_credit_event_zb,
        lm.zero_balance_code,
        lm.zero_balance_date,
        EXISTS (SELECT 1 FROM core.perf d
                WHERE d.loan_seq_no = lm.loan_seq_no AND d.is_defect) AS loan_has_defect
    FROM core.loan_month lm
    WHERE lm.delinquency_months >= 3 OR lm.is_reo_acq OR lm.is_credit_event_zb
    ORDER BY lm.loan_seq_no, lm.period;

    ALTER TABLE core.default_event ADD PRIMARY KEY (loan_seq_no);
    ANALYZE core.default_event;