# IFRS 9 Credit Risk Pipeline on Freddie Mac Mortgages

End-to-end IFRS 9 expected credit loss (ECL) pipeline in **PostgreSQL** and **Python**, built on 13 vintages of the Freddie Mac Single-Family Loan-Level Dataset (2006–2008, 2016–2025; ~650k loans, quarterly snapshots 2006–2026).

Raw monthly loan performance is turned into a CRR-compliant default definition, a behavioural **PD scorecard** (WoE logistic regression), a point-in-time **master scale**, rule-based **IFRS 9 staging**, workout-based **LGD**, lifetime **ECL**, and FINREP-style reports.

The exported data was used to build Tableau dashboards for ECL results and the FINREP F18 template.
They are accessible under
https://public.tableau.com/views/IFRS9ECLFINREPreportingFreddieMacmortgages/Modelregulatory?:language=en-US&publish=yes&:sid=&:redirect=auth&:display_count=n&:origin=viz_share_link

## Key results (reporting date 30 June 2026)

| | Stage 1 | Stage 2 | Stage 3 | Total |
|---|---|---|---|---|
| Gross carrying amount | $67.7bn (94.0%) | $3.5bn (4.8%) | $0.9bn (1.2%) | $72.0bn |
| ECL | $38.6m | $189.6m | $116.3m | $344.4m |
| Coverage | 0.06% | 5.48% | 13.67% | 0.48% |

- **NPE ratio 1.18%**. Stage 2 holds 4.8% of exposure but 55% of the allowance: the IFRS 9 "cliff" between 12-month and lifetime ECL.
- **PD scorecard:** Gini 0.68 in-sample, 0.68 on a loan-level holdout, **0.71 out-of-time (2022+)**, 0.54 in the COVID period.
- Coverage history shows both crises: from 0.24% (2006) to a peak of 3.74% (2013), and from 0.38% (2019) to 1.12% (2020).

![Stage mix](docs/img/stage_mix.png)
![ECL and coverage](docs/img/ecl_coverage.png)

## Pipeline

```
raw  ──►  core (staging)  ──►  core (loan history)  ──►  risk  ──►  reporting
00_load    10_staging           20_core                  30_risk    40_reporting
```

| Layer | Scripts | Output |
|---|---|---|
| Load | `00_load/01–02` | Raw pipe-delimited files into `raw.orig`, `raw.perf` |
| Staging | `10_staging/10–11` | Typed, cleaned origination and monthly performance (`core.orig`, `core.perf`); sentinels → NULL |
| Core | `20_core/20–29` | Monthly loan history with behavioural features, first default per loan, quarterly snapshots with 12-month default flag, data checks |
| Risk | `30_risk/30–38` | PD sample, binning, stability analysis, WoE, scores and master scale, staging, LGD, ECL |
| Model | `python/fit_pd_model.py` | Logistic regression, validation, coefficients back to the database |
| Reporting | `40_reporting/40` | Stage summary, stage migration, F 18-style NPE table, master scale, vintage curves |
| Charts | `python/make_charts.py` | `docs/img/*.png` |
| Tableau export | `40_reporting/41`, `python/export_tableau.py` | ECL cube; all reporting marts as CSV in `exports/tableau/` |

`./run_pipeline.sh` rebuilds everything in dependency order. Every SQL script is idempotent and runs in one transaction.

## Methodology

**Default definition (CRR Art. 178).** First month with 90+ days past due, REO acquisition, or a credit-event zero balance (short sale, foreclosure sale, note sale). Loans with underwriting defects stay in PD data (the borrower default is real) and are excluded from LGD (the loss moved to the seller).

**Sample design.** One row per performing loan per quarter-end, target = default within 12 months. Point-in-time features only.

| Split | Snapshots | Use |
|---|---|---|
| TRAIN | before 2019, 70% of loans | Binning and fit |
| TEST | before 2019, 30% of loans (split by loan, not row) | Overfitting check |
| COVID | 2019–2021 | Stress check (forbearance distorts the default label) |
| OOT | 2022+ | Out-of-time validation |

**Scorecard.** 7 features after fine/coarse classing, information value, and a stability analysis of every bin on TEST/COVID/OOT:

| Feature | Coefficient | Note |
|---|---|---|
| `delinq_history` | −0.88 | Combined recency/severity of past delinquency |
| `orig_ltv` | −0.86 | |
| `loan_purpose` | −0.81 | Cash-out vs. no cash-out |
| `num_borrowers` | −0.73 | |
| `orig_dti` | −0.66 | |
| `credit_score` | −0.48 | |
| `sato` | −0.34 | Rate spread vs. the origination-quarter median |

Logistic regression on WoE features, cluster-robust standard errors by loan (repeated snapshots), all coefficients negative and significant, VIF ≤ 1.14. Dropped after the analysis: `channel`, `property_state` (crisis-specific, flat in OOT), `months_on_books` (confounded with calendar time), `current_ltv` (no house-price indexation before 2017).

**Calibration.** The regression ranks well across eras but carries the crisis-heavy training level (mean PD 2.3× too high in OOT). Scores are mapped to a 7-grade master scale; each grade's PIT PD is its observed 12-month default rate over the last 8 observable quarters, floored at 0.05%.

![Master scale](docs/img/master_scale.png)

**Staging.** First match wins:

- **Stage 3:** 90+ DPD; 3-month probation after cure; recent modification after delinquency (distressed restructuring).
- **Stage 2:** 30+ DPD; forbearance; modification within 24 months; PD ≥ 3× PD at initial recognition and +0.5 pp.
- **Stage 1:** everything else.

![Stage migration](docs/img/stage_migration.png)

**LGD.** Each default is classified as liquidated, cured, defect or unresolved. Liquidation losses are discounted to the default date at the note rate. LGD = (1 − cure rate) × loss given liquidation, by original-LTV band, floored at 5%.

| | Cure rate | Loss given liquidation | LGD |
|---|---|---|---|
| Crisis vintages | 46% | 46% | ~25% |
| Modern vintages | 96% | 17% | ~1% (floored to 5%) |
| Used (pooled) | ~66% | ~45% | ~15% |

**ECL.** Stage 1: 12-month PD × LGD × EAD. Stage 2: lifetime ECL over the remaining term with survival against default and prepayment (CPR 7.7%), discounted at the note rate, closed-form geometric sum. Stage 3: LGD × EAD.

![Vintage curves](docs/img/vintage_curves.png)

## Limitations

- **Sample book:** every vintage has 50k loans regardless of real volume, so crisis vintages are over-weighted against Freddie Mac's actual portfolio, and 2006–2015 contains only crisis loans.
- **PIT, not forward-looking:** PDs reflect the last two observed years. There are no macroeconomic scenarios, and the historical ECL series applies today's grade PDs to past dates.
- **Lifetime ECL** assumes a constant annual PD, no amortisation and one portfolio-wide prepayment rate.
- **LGD** is segmented by original LTV only (no house-price indexation) and is not conditioned on time in default. Pooling crisis and modern workouts gives a cycle-average LGD, unlike the point-in-time PDs.
- **Simplified reporting:** gross carrying amount = unpaid principal balance, and NPE equals Stage 3.

Full list of decisions and their evidence: [`docs/assumptions.md`](docs/assumptions.md). Model output: [`docs/pd_model_summary.txt`](docs/pd_model_summary.txt).

## How to run

1. **Data.** Register at Freddie Mac's Clarity data portal and download the *Standard* sample files for the vintages listed in `sql/00_load/02_load_raw.sql`. Unzip each into `data/raw/sample_YYYY/`. The data is not redistributed in this repo.
2. **Database.** PostgreSQL 16+. Run `sql/000_setup.sql` once as superuser (role, database, schemas). Put the password in `~/.pgpass`.
3. **Python.**
   ```bash
   python3 -m venv venv && source venv/bin/activate
   pip install -r requirements.txt
   echo "DATABASE_URL=postgresql://mikhail:YOUR_PASSWORD@localhost:5432/freddie" > .env
   ```
4. **Run.**
   ```bash
   ./run_pipeline.sh --full   # first time: load raw files, then everything
   ./run_pipeline.sh          # later: rebuild from staging onward
   ```
   Per-step output, including all report tables, goes to `logs/`.

## Repository

```
sql/
  000_setup.sql            one-time setup
  00_load/                 raw tables and file import
  10_staging/              typed core.orig, core.perf
  20_core/                 loan history, default events, snapshots, checks
  30_risk/                 PD sample, bins, stability, WoE, scoring, staging, LGD, ECL
  40_reporting/            reporting marts, ECL cube
python/
  fit_pd_model.py          scorecard fit and validation
  make_charts.py           charts for this README
  export_tableau.py        reporting marts to CSV for Tableau
exports/tableau/           Tableau data sources (aggregates only)
docs/
  assumptions.md           methodological decisions and evidence
  pd_model_summary.txt     regression output and validation
  img/                     charts
run_pipeline.sh            end-to-end runner
```
