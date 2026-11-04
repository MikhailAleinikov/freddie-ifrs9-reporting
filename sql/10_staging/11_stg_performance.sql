-- 11_stg_performance.sql
--   raw.perf -> core.perf  (one row per loan per month, PK loan_seq_no + period, FK to core.orig)
--   Cleaning rules:
--   sentinel codes (9999, 999, 99, 9, 7, 000) -> NULL
--   YYYYMM text -> DATE (first of month)
--   Y/N flags -> BOOLEAN; Y/NULL flags kept as TEXT
--   delinquency_status kept as text; delinquency_months derived (RA, XX -> NULL)
--   non-numeric net_sale_proceeds -> NULL
-- Safe to rerun: drops and rebuilds the table. Requires 01 and 02 to have run.
-- Run from the repo root:
--   psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/10_staging/11_stg_performance.sql

DROP TABLE IF EXISTS core.perf;
CREATE TABLE core.perf (
    loan_seq_no                 TEXT NOT NULL REFERENCES core.orig (loan_seq_no),
    period                      DATE NOT NULL,
    current_upb                 NUMERIC(14,2),
    delinquency_status          TEXT,
    delinquency_months          INTEGER,
    loan_age                    INTEGER,
    remaining_months            INTEGER,
    defect_settlement_date      DATE,
    modification_flag           TEXT,
    zero_balance_code           TEXT,
    zero_balance_date           DATE,
    current_interest_rate       NUMERIC(6,3),
    current_non_int_upb         NUMERIC(14,2),
    ddlpi                       DATE,
    mi_recoveries               NUMERIC(14,2),
    net_sale_proceeds           NUMERIC(14,2),
    non_mi_recoveries           NUMERIC(14,2),
    total_expenses              NUMERIC(14,2),
    legal_costs                 NUMERIC(14,2),
    maint_preservation_costs    NUMERIC(14,2),
    taxes_insurance             NUMERIC(14,2),
    misc_expenses               NUMERIC(14,2),
    actual_loss                 NUMERIC(14,2),
    cumulative_mod_cost         NUMERIC(14,2),
    step_rate_indicator         BOOLEAN,
    payment_deferral_flag       TEXT,
    eltv                        INTEGER,
    zero_balance_removal_upb    NUMERIC(14,2),
    delinquent_accrued_interest NUMERIC(14,2),
    disaster_flag               TEXT,
    borrower_assistance_plan    TEXT,
    current_period_mod_cost     NUMERIC(14,2),
    current_int_upb             NUMERIC(14,2),
    mi_cancellation_indicator   TEXT,
    servicer_name               TEXT,
    bankruptcy_cramdown_costs   NUMERIC(14,2),
    PRIMARY KEY (loan_seq_no, period)
);

INSERT INTO core.perf (
    loan_seq_no, period, current_upb, delinquency_status, delinquency_months,
    loan_age, remaining_months, defect_settlement_date, modification_flag,
    zero_balance_code, zero_balance_date, current_interest_rate, current_non_int_upb,
    ddlpi, mi_recoveries, net_sale_proceeds, non_mi_recoveries, total_expenses,
    legal_costs, maint_preservation_costs, taxes_insurance, misc_expenses,
    actual_loss, cumulative_mod_cost, step_rate_indicator, payment_deferral_flag,
    eltv, zero_balance_removal_upb, delinquent_accrued_interest, disaster_flag,
    borrower_assistance_plan, current_period_mod_cost, current_int_upb,
    mi_cancellation_indicator, servicer_name, bankruptcy_cramdown_costs
)
SELECT
    loan_seq_no,
    to_date(period, 'YYYYMM'),
    current_upb::numeric(14,2),
    delinquency_status,
    CASE WHEN delinquency_status ~ '^\d+$' THEN delinquency_status::int END,
    loan_age::int,
    remaining_months::int,
    to_date(defect_settlement_date, 'YYYYMM'),
    modification_flag,
    zero_balance_code,
    to_date(zero_balance_date, 'YYYYMM'),
    current_interest_rate::numeric(6,3),
    current_non_int_upb::numeric(14,2),
    to_date(ddlpi, 'YYYYMM'),
    mi_recoveries::numeric(14,2),
    CASE WHEN net_sale_proceeds ~ '^-?\d+(\.\d+)?$' THEN net_sale_proceeds::numeric(14,2) END,
    non_mi_recoveries::numeric(14,2),
    total_expenses::numeric(14,2),
    legal_costs::numeric(14,2),
    maint_preservation_costs::numeric(14,2),
    taxes_insurance::numeric(14,2),
    misc_expenses::numeric(14,2),
    actual_loss::numeric(14,2),
    cumulative_mod_cost::numeric(14,2),
    CASE step_rate_indicator WHEN 'Y' THEN true WHEN 'N' THEN false END,
    payment_deferral_flag,
    NULLIF(eltv, '999')::int,
    zero_balance_removal_upb::numeric(14,2),
    delinquent_accrued_interest::numeric(14,2),
    disaster_flag,
    borrower_assistance_plan,
    current_period_mod_cost::numeric(14,2),
    current_int_upb::numeric(14,2),
    NULLIF(mi_cancellation_indicator, '7'),
    trim(servicer_name),
    bankruptcy_cramdown_costs::numeric(14,2)
FROM raw.perf;

ALTER TABLE core.perf
    ADD COLUMN is_reo_acq BOOLEAN GENERATED ALWAYS AS (
        COALESCE(delinquency_status = 'RA', false)
    ) STORED,
    ADD COLUMN dpd_bucket TEXT GENERATED ALWAYS AS (
        CASE
            WHEN delinquency_status = 'RA' THEN 'REO'
            WHEN delinquency_status IS NULL
              OR delinquency_status !~ '^\d+$' THEN NULL
            WHEN delinquency_status::int = 0 THEN '0-29'
            WHEN delinquency_status::int = 1 THEN '30-59'
            WHEN delinquency_status::int = 2 THEN '60-89'
            ELSE '90+'
        END
    ) STORED,
    ADD COLUMN is_credit_event_zb BOOLEAN GENERATED ALWAYS AS (
        COALESCE(zero_balance_code IN ('02','03','09','15'), false)
    ) STORED,
    ADD COLUMN is_defect BOOLEAN GENERATED ALWAYS AS (
        COALESCE(zero_balance_code = '96', false)
        OR defect_settlement_date IS NOT NULL
    ) STORED,
    ADD COLUMN is_forbearance BOOLEAN GENERATED ALWAYS AS (
        COALESCE(borrower_assistance_plan = 'F', false)
        OR COALESCE(disaster_flag = 'Y', false)
    ) STORED;

CREATE INDEX perf_period_idx ON core.perf (period);
ANALYZE core.perf;