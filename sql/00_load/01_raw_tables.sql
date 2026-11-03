-- 01_raw_tables.sql
-- Raw staging tables: one column per field, in EXACT file order, all TEXT.
-- Column order follows the SFLLD General User Guide (Release 48).
-- Verify the field counts against the official file layout before loading:
--   origination = 31 columns, performance = 35 columns.
-- Run:  psql -h localhost -U mikhail -d freddie -v ON_ERROR_STOP=1 -f sql/00_load/01_raw_tables.sql

DROP TABLE IF EXISTS raw.orig;
CREATE TABLE raw.orig (
    credit_score          TEXT,  -- 1  Classic FICO (9999 = NA)
    first_payment_date    TEXT,  -- 2  YYYYMM
    first_time_homebuyer  TEXT,  -- 3  Y/N/9
    maturity_date         TEXT,  -- 4  YYYYMM
    msa                   TEXT,  -- 5  MSA / Metropolitan Division code
    mi_pct                TEXT,  -- 6  0-55, 999 = NA
    num_units             TEXT,  -- 7  1-4, 99 = NA
    occupancy_status      TEXT,  -- 8  P/I/S/9
    orig_cltv             TEXT,  -- 9  999 = NA
    orig_dti              TEXT,  -- 10 999 = NA
    orig_upb              TEXT,  -- 11
    orig_ltv              TEXT,  -- 12 999 = NA
    orig_interest_rate    TEXT,  -- 13
    channel               TEXT,  -- 14 R/B/C/T/9
    ppm_flag              TEXT,  -- 15 prepayment penalty Y/N
    amortization_type     TEXT,  -- 16 FRM/ARM
    property_state        TEXT,  -- 17
    property_type         TEXT,  -- 18 CP/CO/PU/SF/MH/99
    postal_code           TEXT,  -- 19 first 3 digits
    loan_seq_no           TEXT,  -- 20 loan identifier (join key)
    loan_purpose          TEXT,  -- 21 P/C/N/R/9
    orig_loan_term        TEXT,  -- 22 months
    num_borrowers         TEXT,  -- 23 99 = NA
    seller_name           TEXT,  -- 24
    super_conforming_flag TEXT,  -- 25
    pre_harp_loan_seq_no  TEXT,  -- 26
    program_indicator     TEXT,  -- 27 H/F/R/null
    harp_indicator        TEXT,  -- 28 Y/N
    valuation_method      TEXT,  -- 29 1/2/3/4/7
    io_indicator          TEXT,  -- 30 Y/N
    vantagescore4         TEXT   -- 31 9999 = NA
);

DROP TABLE IF EXISTS raw.perf;
CREATE TABLE raw.perf (
    loan_seq_no                 TEXT,  -- 1  join key
    period                      TEXT,  -- 2  YYYYMM
    current_upb                 TEXT,  -- 3
    delinquency_status          TEXT,  -- 4  00,01,02,... RA, XX
    loan_age                    TEXT,  -- 5
    remaining_months            TEXT,  -- 6
    defect_settlement_date      TEXT,  -- 7  YYYYMM
    modification_flag           TEXT,  -- 8  Y/P/null
    zero_balance_code           TEXT,  -- 9  01,02,03,09,15,16,96
    zero_balance_date           TEXT,  -- 10 YYYYMM
    current_interest_rate       TEXT,  -- 11
    current_non_int_upb         TEXT,  -- 12
    ddlpi                       TEXT,  -- 13 YYYYMM
    mi_recoveries               TEXT,  -- 14
    net_sale_proceeds           TEXT,  -- 15
    non_mi_recoveries           TEXT,  -- 16
    total_expenses              TEXT,  -- 17
    legal_costs                 TEXT,  -- 18
    maint_preservation_costs    TEXT,  -- 19
    taxes_insurance             TEXT,  -- 20
    misc_expenses               TEXT,  -- 21
    actual_loss                 TEXT,  -- 22
    cumulative_mod_cost         TEXT,  -- 23
    step_rate_indicator         TEXT,  -- 24
    payment_deferral_flag       TEXT,  -- 25
    eltv                        TEXT,  -- 26 999 = NA
    zero_balance_removal_upb    TEXT,  -- 27
    delinquent_accrued_interest TEXT,  -- 28
    disaster_flag               TEXT,  -- 29
    borrower_assistance_plan    TEXT,  -- 30
    current_period_mod_cost     TEXT,  -- 31
    current_int_upb             TEXT,  -- 32
    mi_cancellation_indicator   TEXT,  -- 33
    servicer_name               TEXT,  -- 34
    bankruptcy_cramdown_costs   TEXT   -- 35
);