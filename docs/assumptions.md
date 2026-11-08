# Methodology and Assumptions

This document describes how the pipeline turns Freddie Mac loan-level data into IFRS 9 stages and expected credit losses, and records every judgment call with the evidence behind it. Section numbers follow the order of the pipeline. Script names refer to `sql/` and `python/`.

**Conventions used throughout**

- A **snapshot** is one loan at one quarter-end. `snapshot_date` is stored as the first day of the quarter-end month (e.g. `2026-06-01` = the June 2026 monthly record).
- **DPD** counts are taken from Freddie Mac's delinquency status in months: 0 = current, 1 = 30–59 days, 2 = 60–89 days, 3+ = 90+ days.
- All rates are 12-month rates unless stated otherwise.

---

## 1. Data

### 1.1 Source

Freddie Mac Single-Family Loan-Level Dataset, *Standard* sample files: 50,000 loans per origination year, with origination data (one row per loan) and monthly performance data (one row per loan per month). The Standard dataset contains fixed-rate mortgages only. The latest monthly record is **June 2026**, which is the reporting date.

### 1.2 Vintages

13 vintages: **2006–2008** and **2016–2025** (`sql/00_load/02_load_raw.sql`). Each group has a specific job:

| Vintages | Role |
|---|---|
| 2006–2008 | The full credit cycle: pre-crisis, crash, long recovery. Supplies most defaults and almost all liquidations for LGD. |
| 2016–2019 | Post-crisis underwriting with complete histories through COVID and the high-rate period |
| 2020–2021 | The low-rate refinancing wave, the largest part of a real 2026 mortgage book |
| 2022–2025 | Current originations at high rates |

### 1.3 Sample book

Every vintage contributes 50,000 loans regardless of its real origination volume. All portfolio figures therefore describe a **sample book**, not Freddie Mac's actual portfolio:

- Crisis vintages are over-weighted against today's real book.
- 2006–2015 contains only crisis vintages. All time series jump in 2016, when the first modern vintage enters at full size. That jump is a sample effect, not a credit event.
- No 2026 vintage is loaded, so new business in the latest quarter is almost absent (101 loans).

### 1.4 Layers

| Layer | Content |
|---|---|
| `raw` | Files exactly as delivered, every column TEXT |
| `core` | Typed and cleaned data, loan history, default events, snapshots: facts, no business judgment beyond the default definition |
| `mart` | Model sample, bins, scores, stages, LGD, ECL, reports: all business decisions |

---

## 2. Cleaning rules (`10_staging`)

- **Sentinel codes become NULL:** credit score 9999; LTV, CLTV, DTI, MI % and ELTV 999; number of units, borrowers and property type 99; occupancy, channel and loan purpose 9; MI cancellation 7; valuation method 7; postal code 000.
- **Dates:** `YYYYMM` text → DATE, first of the month.
- **Y/N flags** → BOOLEAN. Flags with only Y/blank values stay as text.
- **Delinquency:** the original status is kept as text. `delinquency_months` is its integer value, NULL for non-numeric codes (`RA` = REO acquired, `XX` = unknown).
- **Derived flags on `core.perf`:**
  - `is_reo_acq`: status `RA`.
  - `is_credit_event_zb`: zero balance code 02 (third-party sale), 03 (short sale), 09 (REO disposition) or 15 (note sale).
  - `is_defect`: zero balance code 96 or a defect settlement date.
  - `is_forbearance`: borrower assistance plan `F` (forbearance) **or** disaster flag `Y`. Repayment (`R`) and trial (`T`) plans are not included.
- **Vintage** = `20` + characters 2–3 of the loan ID.

---

## 3. Core layer (`20_core`)

### 3.1 Monthly loan history (`core.loan_month`)

One row per loan per month, with point-in-time features computed by window functions over the loan's own history:

| Column | Definition |
|---|---|
| `max_delinq_12m` | Worst delinquency over the current and previous 11 **rows** |
| `last_delinq_period` | Latest month with 30+ DPD, up to now |
| `last_90_period` | Latest month with 90+ DPD, up to now |
| `last_mod` | Latest month with modification flag `Y` |
| `ever_modified` | Any modification flag `Y` or `P` so far (false if never) |
| `ever_deferred` | Any payment deferral flag `C` or `P` so far (false if never) |
| `current_ltv` | Freddie Mac ELTV if present; otherwise original LTV × current UPB / original UPB |

**Gaps:** 77 loans have missing months in their history, mostly crisis vintages in 2009–2014 (`29_checks`). For them, "12 rows" in `max_delinq_12m` covers slightly more than 12 calendar months. Too few loans to matter; the check stays in place to catch broken loads.

### 3.2 Default definition (`core.default_event`)

A loan's **first** month meeting any of these triggers (CRR Art. 178):

1. **90+ DPD** (`delinquency_months` ≥ 3);
2. **REO acquisition** (status `RA`);
3. **Credit-event zero balance** (codes 02, 03, 09, 15).

Only the first default per loan is kept, so re-defaults after a cure are not modelled as new events. The table also stores `ead_at_default` (UPB in the default month, or the removal UPB when the trigger row has zero balance) for LGD.

**Defects.** Loans with an underwriting defect (2,107 defaults) **stay in all PD data**. The borrower default is real; only the loss was transferred to the seller. They are excluded from LGD only (§7). The first version excluded defect loans from all data based on a whole-history flag. That both looked into the future and removed real, mostly crisis-era defaults, biasing PD downward.

### 3.3 Quarterly snapshots (`core.snapshot`)

One row per **active** loan per quarter-end:

- **Excluded:** the termination month and everything after it, and REO months. An REO property is no longer a loan.
- **`ead`** = current unpaid principal balance (UPB).
- **`has_defaulted`:** the first default happened on or before the snapshot.
- **`defaults_next_12m` (the PD target):** the first default happens within the 12 months after the snapshot.
- **`target_observable`:** the full 12-month window lies within the data (snapshot + 12 months ≤ June 2026). The last 4 quarter-ends are censored: their outcome is unknown, so they are excluded from model development instead of being counted as non-defaults.
- **`months_on_books`:** from the first payment date, following Freddie Mac's loan-age convention. One loan with a modification-related date anomaly gets NULL.
- **Time-since features:** `months_since_last_del`, `months_since_last_90` and `months_since_last_mod` count months from the respective `last_*` month. NULL means never.

---

## 4. PD model

### 4.1 Development sample (`30_pd_sample.sql`)

**Population:** snapshots of loans that have **not yet defaulted** and whose outcome window is complete (`NOT has_defaulted AND target_observable`).

**Splits:**

| Split | Snapshots | Rows | Default rate | Purpose |
|---|---|---|---|---|
| TRAIN | before 2019, 70% of loans | 2,264,990 | 2.46% | Binning and fit |
| TEST | before 2019, 30% of loans | 965,675 | 2.48% | Overfitting check |
| COVID | 2019Q1–2021Q4 | 1,893,733 | 2.01% | Stress check only |
| OOT | 2022Q1 onward | 3,070,600 | 0.69% | Out-of-time validation |

- **TRAIN/TEST are split by loan, not by row.** Every loan appears in many quarters. A row-level split would put near-identical observations in both sets and inflate TEST performance. Assignment uses the first 7 hex characters of `md5(loan_seq_no)`, modulo 10 (buckets 0–2 → TEST). It's deterministic and independent of the Postgres version.
- **COVID is held out of development** because outcome windows overlapping 2020–2021 contain forbearance-reported delinquency that often wasn't credit distress, which would change the meaning of the label.
- **Correlated observations:** repeated snapshots of the same loan are not independent. Coefficient estimates are unaffected; standard errors are corrected by clustering (§4.6).

### 4.2 Candidate features and derived variables

All features are point-in-time: they use only information available at the snapshot date.

**`sato` (spread at origination):** the loan's original note rate minus the median note rate of all loans originated in the same quarter (quarter from loan ID characters 2–5). It replaces the raw interest rate, whose meaning changes across rate regimes: 6.5% signalled a risky borrower in 2016, an average one in 2023.

**`delinq_history`:** a combined recency and severity measure:

| Value | Meaning |
|---|---|
| 0 | Never delinquent |
| 1 | Last delinquency 25+ months ago |
| 2 | Last delinquency 12–24 months ago |
| 3 | Worst status in the last 12 months: 30 DPD |
| 4 | Worst status in the last 12 months: 60 DPD |

90+ cannot occur in the sample, since such loans have defaulted.

**Why combined:** `max_delinq_12m` (severity) and `months_since_last_del` (recency) were near-duplicates within 12 months, but beyond 12 months only recency carries information. Among loans current at the snapshot (TRAIN):

| History | Rows | Default rate |
|---|---|---|
| never late | 2,023,555 | 1.26% |
| last late 25+ months ago | 62,978 | 1.77% |
| last late 13–24 months ago | 38,719 | 3.57% |
| worst 30 DPD within 12 months | 75,558 | 7.91% |
| worst 60 DPD within 12 months | 9,903 | 16.03% |

`max_delinq_12m` alone puts "late 13–24 months ago" (3.57%) together with "never late" (1.26%). One combined variable keeps both signals without collinearity. `dpd_bucket` was dropped: it is constant within Stage 1 (all current), which is where the PD matters most.

### 4.3 Binning methodology (`31_bin_def.sql`, `32_binning.sql`)

**Weight of evidence (WoE)** for a bin: WoE = ln(%goods in bin / %bads in bin), where %goods is the bin's share of all non-defaulters and %bads its share of all defaulters. Positive WoE = safer than average. Counts are smoothed by +0.5 per bin (avoids ln 0).

**Information value (IV)** for a feature: IV = Σ (%goods − %bads) × WoE, the divergence between the feature's distribution among goods and among bads.

| IV | Reading |
|---|---|
| < 0.02 | No predictive power |
| 0.02–0.1 | Weak |
| 0.1–0.3 | Medium |
| 0.3–0.5 | Strong |
| > 0.5 | Very strong: check for leakage |

**Rules for coarse classing:**

1. Bins and cut points are hand-maintained decisions in `mart.bin_def`. `32_binning.sql` only computes statistics from them.
2. Each bin should hold ≥ 5% of rows and ≥ 30 defaults. **Exception:** small bins with many defaults and clearly separated risk are kept (they carry the signal and their rate is stable). Applied to `credit_score <620`, `orig_ltv >95` and `delinq_history` 3–4.
3. Numeric bins must be monotone in default rate.
4. Bins with nearly identical default rates are merged.
5. Missing values either get their own bin or join the bin with the closest default rate. Missing bins with very few rows and no defaults join the largest bin (a neutral choice).
6. Every feature must cover every row exactly once (holes and overlaps are checked).

All binning statistics use **TRAIN only**.

### 4.4 Feature decisions

**Kept (7):**

| Feature | Bins | Decision and evidence |
|---|---|---|
| `credit_score` | <620 or missing / 620–659 / 660–699 / 700–739 / 740–779 / 780+ | Monotone (TRAIN default rates 7.49% → 0.63%). Missing (rare) joins <620, the closest default rate. <620 kept at 3.0% of rows (5,018 defaults); almost exclusively crisis-era, since Freddie Mac rarely acquires <620 after 2009. |
| `orig_ltv` | ≤60 / 61–80 or missing / 81–95 / >95 | 61–70 and 71–80 merged (2.47% vs 2.68%). 81–90 and 91–95 merged: the pooled default rate dips at 91–95, but within every era × loan-purpose group it rises with LTV. The dip is Simpson's paradox: 81–90 is 71% crisis loans with 27% cash-out refinances among them, 91–95 only 54% and 0.3%. WoE is estimated on pooled data, so separate bins would teach the model the reversed pattern. Missing (176 rows, 0 defaults) joins the largest bin. >95 kept at 2.2% (2,502 defaults). Final default rates 1.19 / 2.63 / 3.24 / 4.99%. |
| `orig_dti` | <30 / 30–36 or missing / 37–43 / 44–50 / >50 | Monotone (1.37 → 4.73%). Missing (2.7%; relief refinances, pre-crisis no-ratio loans) joins 30–36 (2.27% vs 2.09%). >50 kept (9.6%, 10,332 defaults), almost exclusively crisis-era since the current DTI cap is 50%. |
| `sato` | missing / <−0.25 / −0.25–0 / 0–0.25 / 0.25–0.5 / ≥0.5 (pp) | Monotone, no flags, stable in every split. |
| `num_borrowers` | 1 / 2+ or missing | 3.00% vs 1.92%. Missing (415 rows, 0 defaults) joins 2+. |
| `delinq_history` | 0–4 as in §4.2 | Strongest feature, monotone. |
| `loan_purpose` | no cash-out (P, N, R) or missing / cash-out (C) | The order of purchase vs. rate/term refinance flips between eras (TRAIN: refi riskier; OOT: refi much safer, being mostly the 2020–21 low-rate wave). The cash-out premium is stable: 1.48× TRAIN, 1.45× OOT. |

**Dropped:**

| Feature | Reason (evidence) |
|---|---|
| `current_ltv` | Not consistently defined over time. Freddie Mac ELTV exists only from April 2017; before that the fallback uses the original property value, so it cannot capture the 2007–2011 price fall. Share of rows with ELTV: TRAIN/TEST 20%, COVID/OOT 91%. The underwater bin held only 0.3% of TRAIN with the same default rate as 90–99%. A house-price-indexed LTV would fix this (not implemented). |
| `months_on_books` | Confounded with calendar time. Crisis-vintage default rates peak at 25–36 months (4.42%), which is exactly 2008–2011. Modern vintages are flat after month 6 (0.35 / 0.45 / 0.43 / 0.40%), and TRAIN contains no modern loan older than 36 months. Only a small seasoning effect (months 0–6 safer) holds in both eras. |
| `channel` | Stable ranking, but no power outside the crisis: IV 0.139 TRAIN, 0.004 OOT (broker 0.79% vs retail/correspondent 0.67%). Code T (TPO unspecified) exists only before 2009. |
| `property_state` (5 tiers) | IV 0.110 TRAIN, 0.006 OOT; rank correlation of tier default rates 0.30; OOT tier default rates flat (0.60–0.74%). The tiers reflect where the 2007–08 housing bubble was. |
| `dpd_bucket`, `max_delinq_12m`, `months_since_last_del` | Replaced by `delinq_history` |
| `ead` | IV 0.03, not monotone |
| `occupancy_status`, `first_time_homebuyer` | IV 0.006 and 0.003 |
| `is_forbearance`, `ever_modified`, `ever_deferred` | IV ≤ 0.01 in TRAIN (before 2019, almost no performing loan was in forbearance or modified). Used as staging triggers instead (§6). |
| `vintage`, raw `orig_interest_rate` | Encode the era rather than borrower risk; the rate is replaced by `sato` |

### 4.5 Stability analysis (`33_binning_stability.sql`)

The TRAIN bins are applied to every split. Per feature:

- **IV** within the split (diagnostic only; scoring always uses TRAIN WoE);
- **PSI** vs TRAIN = Σ (share_split − share_TRAIN) × ln(share_split / share_TRAIN): **population** shift;
- **Rank correlation** of bin default rates vs TRAIN, over bins with ≥ 30 defaults: **relationship** shift;
- whether the riskiest TRAIN bin is still the riskiest.

**Decision rule:** tolerate population shift, reject relationship shift. High PSI alone is not a reason to drop a feature (the book changed); a flipped ranking is.

**Final results (7 features):**

| Feature | IV TRAIN | IV TEST | IV COVID | IV OOT | PSI OOT | Rank corr. OOT |
|---|---|---|---|---|---|---|
| `delinq_history` | 1.482 | 1.475 | 0.751 | 1.679 | 0.019 | 1.00 |
| `credit_score` | 0.559 | 0.537 | 0.394 | 0.776 | 0.161 | 0.83 |
| `orig_dti` | 0.164 | 0.166 | 0.188 | 0.187 | 0.390 | 0.90 |
| `orig_ltv` | 0.127 | 0.134 | 0.087 | 0.092 | 0.042 | 1.00 |
| `sato` | 0.125 | 0.139 | 0.141 | 0.141 | 0.019 | 0.90 |
| `num_borrowers` | 0.052 | 0.048 | 0.049 | 0.130 | 0.007 | 1.00 |
| `loan_purpose` | 0.037 | 0.038 | 0.002 | 0.027 | 0.067 | 1.00 |

- **TEST matches TRAIN for every feature:** no overfitting of the bins.
- **`credit_score` and `orig_dti`** have their only OOT ranking deviation in `<620` and `>50`, which are 0.3% and 0.2% of the OOT book. All other bins stay monotone.
- **`delinq_history` IV halves in COVID** (forbearance-reported delinquency), which supports holding COVID out of development.
- **`loan_purpose` has no cash-out premium during COVID** (IV 0.002).

### 4.6 Logistic regression (`python/fit_pd_model.py`)

**Model:**

  ln( PD / (1 − PD) ) = β₀ + Σᵢ βᵢ · WoEᵢ

with PD = probability of default within 12 months, and WoEᵢ the TRAIN WoE of the loan's bin in feature i (`34_snapshot_woe.sql`). Estimated by maximum likelihood on TRAIN.

**Why a regression on top of WoE:** adding the WoEs would be a naive Bayes classifier, which assumes the features are independent and double-counts shared evidence. The regression weights each feature. Under independence every βᵢ would be −1. The sign is negative because WoE measures evidence for "good" while the model predicts "bad".

**Pre-checks:** highest absolute WoE correlation 0.24 (`orig_ltv`–`loan_purpose`); all VIFs ≤ 1.14 (computed on a 200,000-row random sample).

**Standard errors** are cluster-robust by loan, because repeated snapshots of the same loan are not independent. Clustering leaves the coefficients unchanged and roughly doubled the standard errors.

**Selection rule:** refit until every coefficient is negative and significant at 5%, removing one feature per round (wrong signs first, then the highest p-value). No feature was removed.

**Result** (TRAIN, n = 2,264,990, 55,719 defaults):

| Term | Coefficient | Std. error (clustered) | z |
|---|---|---|---|
| intercept | −3.6777 | 0.0097 | −380.5 |
| `delinq_history` | −0.8841 | 0.0055 | −161.6 |
| `orig_ltv` | −0.8587 | 0.0302 | −28.4 |
| `loan_purpose` | −0.8055 | 0.0540 | −14.9 |
| `num_borrowers` | −0.7339 | 0.0436 | −16.8 |
| `orig_dti` | −0.6594 | 0.0248 | −26.6 |
| `credit_score` | −0.4830 | 0.0142 | −34.1 |
| `sato` | −0.3369 | 0.0284 | −11.9 |

Converged in 9 iterations; McFadden pseudo R² 0.223.

**Interpretation:**

- **The intercept** is the log-odds of a loan with average evidence in every feature (all WoE = 0): ln(0.0246 / 0.9754) = −3.68, the TRAIN default rate.
- **Each term multiplies the odds** by e^(βᵢ·WoEᵢ). Example: the "worst 60 DPD within 12 months" bin (WoE −3.458) multiplies the odds by e^(0.884 × 3.458) ≈ 21; FICO 780+ (WoE +1.374) by e^(−0.483 × 1.374) ≈ 0.52.
- **All coefficients are between −0.34 and −0.88**, i.e. discounted relative to −1, because the features share evidence (all WoE correlations are positive except one). `credit_score` is discounted strongly because delinquency history and SATO already carry part of its information. `sato` is discounted most because the rate spread is partly the lender's own pricing of FICO and LTV.
- **Coefficients are predictive, not causal.**

**Model assumptions and how they hold:**

| Assumption | Status |
|---|---|
| Binary outcome, logit link | Holds |
| Linearity in log-odds | Holds across bins by construction (WoE). Constraint: one coefficient per feature keeps the univariate spacing between that feature's bins. |
| Independent observations | Violated (panel data); handled by clustered standard errors. Estimates remain consistent. |
| No strong multicollinearity | Holds (VIF ≤ 1.14) |
| Additivity (no interactions) | Simplification: e.g. LTV risk is higher for cash-out loans, not modelled |
| Stable relationship over time | Ranking yes (OOT Gini ≥ TRAIN); level no (handled by calibration, §4.8) |
| Enough events per parameter | ~7,000 defaults per parameter |
| Correct outcome measurement | Label noise in COVID; that period is held out |

### 4.7 Validation

| Split | Default rate | Mean model PD | AUC | Gini | KS |
|---|---|---|---|---|---|
| TRAIN | 2.46% | 2.46% | 0.841 | 0.682 | 0.514 |
| TEST | 2.48% | 2.43% | 0.838 | 0.677 | 0.507 |
| COVID | 2.01% | 1.72% | 0.771 | 0.542 | 0.390 |
| OOT | 0.69% | 1.56% | 0.857 | 0.713 | 0.542 |

**Metrics:**

- **AUC** is the probability that a random defaulter gets a higher PD than a random non-defaulter.
- **Gini** = 2·AUC − 1.
- **KS** is the maximum distance between the cumulative score distributions of defaulters and non-defaulters.
- **Mean model PD vs default rate** measures calibration-in-the-large. It is equal in TRAIN by construction (maximum-likelihood property with an intercept).

**Findings:**

- **No overfitting:** TEST ≈ TRAIN.
- **The ranking transfers to the modern book:** OOT Gini 0.713 is higher than TRAIN.
- **The level does not:** mean model PD is 2.3× the observed OOT default rate. Better borrower characteristics explain part of the drop (mean PD falls from 2.46% to 1.56%); the rest is the benign macro environment, which the features cannot see.
- **COVID is the only period where the model underestimates** (1.72% vs 2.01%), with weaker ranking (Gini 0.54): a shock not visible in borrower data.

### 4.8 Scores and master scale (`35_pd_score.sql`)

**Every snapshot row is scored,** not only the sample. This includes the reporting date and already-defaulted loans.

**Score:**

  score = 600 − (20 / ln 2) · (log-odds + ln 50)

so that 600 points correspond to good:bad odds of 50:1, and every 20 points double the odds (PDO = 20). Higher score = safer. Points per bin (`mart.scorecard`) = −(βᵢ·WoE + β₀/n)·20/ln 2 + (600 − 20/ln 2 · ln 50)/n, with n = 7 features.

**Grades:** 7 bands with cut points at the 2nd, 5th, 10th, 25th, 50th and 75th percentiles of the TRAIN score distribution. The bands are narrow at the risky end, where default rates change fastest. The cut points are fixed, so a grade means the same score range in every period.

**PD per grade:**

- **TTC PD** (through-the-cycle) = observed 12-month default rate of the grade over all observable snapshots, 2006–2025.
- **PIT PD** (point-in-time, used for staging and ECL) = observed 12-month default rate of the grade over the **last 8 observable quarter-ends** (September 2023 – June 2025), floored at 0.05%.

The floor is the CRR3 retail PD floor for IRB capital, applied here as a prudent choice; IFRS 9 does not require it.

| Grade | Score | TTC PD | PIT PD |
|---|---|---|---|
| 1 | ≥ 633 | 0.219% | 0.071% |
| 2 | 617–633 | 0.629% | 0.227% |
| 3 | 601–617 | 1.299% | 0.563% |
| 4 | 585–601 | 2.428% | 1.176% |
| 5 | 553–585 | 4.474% | 2.494% |
| 6 | 525–553 | 12.725% | 8.870% |
| 7 | < 525 | 32.504% | 26.653% |

Default rates rise monotonically across grades in TRAIN, OOT and the recent window.

**Why a master scale instead of the regression PD:** the regression PD is a valid 12-month PD, but conditional on the training period's conditions, which sit in the intercept. The model is used for **ranking**; the **level** comes from observed default rates per grade. Calibration rests on large observed samples per grade, and model errors in the shape of the PD curve do not carry over.

**Rejected alternative: one odds scalar on the TTC PDs.** Scaling all grades by recent/long-run portfolio odds (0.436) matched the portfolio level but overstated grades 1–2 by 21–34% and understated grades 6–7 by ~33%. Risk separation between grades is steeper in benign periods (consistent with the higher OOT Gini). Per-grade calibration was possible because every grade has enough recent defaults. `pd_ttc` and `odds_scalar` remain in `mart.pd_grade` for reference.

**Limits:**

- The PIT PDs are **backward-looking** (the last two observed years); there are no macroeconomic forecasts or scenario weights.
- The OOT backtest per grade is circular, because the calibration window lies inside OOT.
- The same PIT PDs are applied to all historical dates, so historical ECL reflects past stages and grades at **today's** grade PDs.

---

## 5. EAD

EAD = current unpaid principal balance at the snapshot (no accrued interest, no undrawn amounts, since amortising mortgages have none). It also serves as the gross carrying amount in the reports.

---

## 6. Staging (`36_stage.sql`)

Rules in priority order; the first match determines stage and `stage_reason`.

| Stage | Reason | Rule | Basis |
|---|---|---|---|
| 3 | `S3_DPD90` | 90+ DPD | CRR Art. 178 |
| 3 | `S3_PROBATION` | Last 90+ month less than 3 months ago | EBA guidelines on the definition of default: minimum 3-month probation |
| 3 | `S3_DISTRESSED_MOD` | Modified (flag `Y`) within the last 12 months **and** any delinquency within the last 12 months | Distressed restructuring as unlikeliness to pay, CRR Art. 178(3)(d); approximation (§10) |
| 2 | `S2_DPD30` | 30+ DPD | IFRS 9 5.5.11 rebuttable backstop |
| 2 | `S2_FORBEARANCE` | Currently in forbearance or disaster relief | Qualitative SICR indicator |
| 2 | `S2_FORBORNE_PROB` | Modified within the last 24 months | Mirrors the EBA 2-year forborne probation |
| 2 | `S2_PD_SICR` | PIT PD ≥ 3 × PD at initial recognition **and** ≥ +0.5 pp | IFRS 9 5.5.9 |
| 1 | `S1` | Everything else | |

- **Stage 3 means in default now,** not ever defaulted. Cured loans move back through Stage 2.
- **PD at initial recognition** = PIT PD of the loan's grade at its first snapshot.
- **The absolute threshold** prevents flagging trivial relative moves (e.g. 0.05% → 0.15%).
- **The only time-varying scorecard feature is `delinq_history`,** so `S2_PD_SICR` effectively captures loans that were recently delinquent and are current again: a behavioural backstop beyond the 30-DPD rule.
- **COVID forbearance counts as Stage 2** (conservative choice). EBA guidance (EBA/GL/2020/02) stated that general payment moratoria did not automatically constitute forbearance or SICR.

**Results at the reporting date (June 2026):**

| Stage | Loans | EAD | Share of EAD |
|---|---|---|---|
| 1 | 263,660 | $67.7bn | 94.0% |
| 2 | 14,317 | $3.5bn | 4.8% |
| 3 | 3,045 | $0.85bn | 1.2% |

- **Stage 2 by reason** (EAD): PD-based SICR 71%, 30+ DPD 25%, forborne probation 3%, forbearance 0.4%.
- **Stage 3 by reason** (loans): 90+ DPD 1,995; distressed modification 607; probation 443.
- **SICR sensitivity:** at 2× instead of 3×, the PD-triggered share of otherwise-Stage-1 loans rises from 3.74% to 5.72%.

**History:** Stage 3 peaks at ~15% of EAD in 2013. The surviving crisis book worsened as good borrowers refinanced away, and foreclosure timelines were long in 2010–2013.

---

## 7. LGD (`37_lgd.sql`)

### 7.1 Workout outcomes

Each defaulted loan is classified by its last monthly record:

| Outcome | Rule | Treatment |
|---|---|---|
| Defect | Underwriting defect | Excluded (loss transferred to the seller) |
| Liquidated | Zero balance 02 / 03 / 09 / 15 with actual loss reported | LGD = actual loss / EAD at default, discounted |
| Cured | Zero balance 01 (paid off) or 16 (reperforming loan sale), or still active, current and ≥ 12 months since the last 90+ month | LGD = 0 |
| Unresolved | Everything else (in workout, or loss not yet reported) | Excluded |

- **Actual loss** is Freddie Mac's realised loss, net of mortgage insurance and other recoveries, including expenses and delinquent interest.
- **Discounting:** the loss is discounted to the default date at the loan's original note rate (monthly compounding) over the months between default and zero-balance date. IFRS 9 requires discounting at the effective interest rate.
- **Per-loan LGD** is floored at 0 and capped at 100%.

### 7.2 Results

| Era | Cured | Liquidated | Unresolved | Defect | Cure rate | Loss given liquidation |
|---|---|---|---|---|---|---|
| Crisis (2006–08) | 8,366 | 9,760 | 173 | 1,851 | 46% | 46% |
| Modern (2016+) | 11,919 | 467 | 4,429 | 256 | 96% | 17% |

Average liquidation workout: 28.5 months (crisis), 25.4 months (modern).

### 7.3 LGD used in ECL

  LGD = (1 − cure rate) × LGL

where LGL (loss given liquidation) is the simple average discounted LGD of liquidated loans. It is computed by original-LTV band (≤60, 61–80 incl. missing, 81+) plus an `ALL` fallback row, and floored at 5% (the CRR3 floor for retail exposures secured by residential property, applied as prudence).

**Pooled over eras**, the LGD is about 15%:

- **Modern-only** (~1%, floored to 5%) rests on 467 liquidations during a historic house-price rise with foreclosure moratoria.
- **Crisis-only** (~25%) is a downturn LGD.

**Limits:**

- The pooled LGD is a cycle average while the PDs are point-in-time.
- 26% of modern defaults are unresolved and excluded (resolution bias).
- Segmentation uses original LTV only (no house-price indexation).
- LGD does not depend on time in default: Stage 3 coverage is flat (~13–14%) from 90 days to over a year past due.

---

## 8. ECL (`38_ecl.sql`)

Notation: p = PIT 12-month PD, LGD from §7.3, EAD from §5, r = original note rate, d = 1/(1 + r), CPR = annual prepayment rate, T = remaining years (months to maturity / 12, rounded up, between 1 and 30).

| Stage | Formula |
|---|---|
| 1 | ECL = p × LGD × EAD × d^0.5 |
| 2 | ECL = Σ_{t=1..T} S_{t−1} × p × LGD × EAD × d^(t−0.5), with S_t = [(1 − p)(1 − CPR)]^t |
| 3 | ECL = LGD × EAD (PD = 1) |

**Stage 2 in closed form:** with s = (1 − p)(1 − CPR), ECL = p × LGD × EAD × d^0.5 × (1 − (s·d)^T) / (1 − s·d). A loan can default, prepay or survive each year. Losses occur mid-year on average (hence the −0.5 in the discount exponent).

**Lifetime PD** (reported) = p × (1 − s^T) / (1 − s): the probability of defaulting before maturity, given prepayment as a competing exit.

**CPR = 7.73%:** the share of active loans that paid off in full (zero balance 01) within 12 months, over the snapshots September 2023 – June 2025.

**Simplifications:**

- Constant annual PD over the lifetime (no PD term structure or mean reversion).
- No amortisation: EAD stays at today's balance, which is conservative.
- One portfolio-wide CPR, independent of the loan's rate incentive.
- Discounting at the original note rate.
- No forward-looking scenarios.

The constant PD and missing amortisation make Stage 2 coverage high compared with bank peers.

**Results at the reporting date:**

| Stage | EAD | ECL | Coverage |
|---|---|---|---|
| 1 | $67,659m | $38.6m | 0.06% |
| 2 | $3,456m | $189.6m | 5.48% |
| 3 | $850m | $116.3m | 13.67% |
| Total | $71,966m | $344.4m | 0.48% |

Stage 2 holds 4.8% of EAD but 55% of ECL: the "cliff" between 12-month and lifetime ECL.

**Coverage over time:** 0.24% (2006) → 3.74% (2013 peak) → 0.38% (2019) → 1.12% (2020, COVID forbearance) → 0.48% (June 2026).

---

## 9. Reporting (`40_reports.sql`)

- **Reporting date** = latest quarter-end (June 2026); **comparison date** = previous quarter-end (March 2026).
- **Gross carrying amount** = EAD (current UPB); **accumulated impairment** = ECL.
- **Stage migration:** stage at the comparison date vs the reporting date per loan, plus New (only at the reporting date) and Derecognised (only at the comparison date; paid off or liquidated).
  - Stage 1 → 1: 96.8%;
  - Stage 2 → 1: 8.0%;
  - Stage 3 → 2: 18.4%;
  - Stage 3 → 1: 1 loan. Cures pass through Stage 2.
- **F 18-style table:** performing exposures split into not past due / ≤ 30 days vs > 30 ≤ 90 days. Non-performing exposures split into unlikely to pay ≤ 90 days (Stage 3 without 90+ DPD) and past due > 90 ≤ 180 days, > 180 days ≤ 1 year, > 1 year.
  - NPE = Stage 3 by construction; **NPE ratio 1.18%**.
  - Simplification: in real reporting, NPE and Stage 3 can differ.
- **Vintage curves:** cumulative share of each vintage's loans that have defaulted, by months since first payment, shown only for months observable for all loans of the vintage.

---

## 10. Known limitations and next steps

| Area | Limitation | Possible improvement |
|---|---|---|
| Data | Sample book with equal-sized vintages; no 2026 vintage | Weight vintages by actual origination volume; load the 2026 sample |
| PD | Backward-looking PIT; no macro scenarios; today's PIT PDs applied to past dates | Macro-linked PD term structure with weighted scenarios |
| PD | No interactions (e.g. LTV × purpose) | Interaction terms or segmented scorecards |
| LTV | No house-price indexation; `current_ltv` unusable | FHFA state house-price index for a consistent indexed LTV |
| Staging | Distressed modification approximated; COVID forbearance treated as SICR | Use the modification month's delinquency directly; COVID sensitivity |
| LGD | Pooled over eras; original LTV only; independent of time in default; resolution bias | PIT LGD by era, indexed LTV, LGD by time in default |
| ECL | Constant lifetime PD, no amortisation, one CPR | PD term structure, amortisation schedule, CPR by rate incentive |
| Reporting | GCA = UPB; NPE = Stage 3 | Accrued interest, separate NPE definition |

## 11. Data checks (`20_core/29_checks.sql`)

Run after every core rebuild:

- `loan_month` row count equals `perf`;
- one `default_event` row per loan, each matching a performance row and with a trigger;
- snapshots only at quarter-ends, never at or after termination, never in REO months;
- `has_defaulted` and `defaults_next_12m` mutually exclusive;
- 4 censored quarter-ends.

Informational counts: loans with missing months (77), defaults on defect loans (2,107), missing EAD at default, negative months on books, and zero or missing EAD in snapshots (1 row).

Bin coverage is checked in `32_binning.sql` and `33_binning_stability.sql` (no holes, no overlaps). WoE assignment is reconciled against the bin counts in `34_snapshot_woe.sql`.
