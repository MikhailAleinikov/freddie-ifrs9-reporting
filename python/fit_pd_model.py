"""
fit_pd_model.py
Logistic regression PD scorecard on WoE-transformed features.
Step 1: connect and load one sample split from mart.snapshot_woe + mart.pd_sample.

Run from the repo root (venv active):
    python python/fit_pd_model.py

Connection: reads DATABASE_URL from .env in the repo root, e.g.
    DATABASE_URL=postgresql://mikhail:YOUR_PASSWORD@localhost:5432/freddie
"""


import os
from pathlib import Path

import statsmodels.api as sm
from statsmodels.stats.outliers_influence import variance_inflation_factor

import numpy as np
from sklearn.metrics import roc_auc_score, roc_curve

import pandas as pd
from sqlalchemy import create_engine, text

FEATURES = [
    "woe_credit_score",
    "woe_orig_ltv",
    "woe_orig_dti",
    "woe_sato",
    "woe_num_borrowers",
    "woe_delinq_history",
    "woe_loan_purpose",
]

REPO_ROOT = Path(__file__).resolve().parents[1]


def read_env(path: Path) -> None:
    """Load KEY=VALUE lines from a .env file into os.environ (existing variables win)."""
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


def get_engine():
    read_env(REPO_ROOT / ".env")
    url = os.environ.get("DATABASE_URL")
    if not url:
        raise SystemExit("DATABASE_URL not found in .env or environment")
    # newer SQLAlchemy defaults postgresql:// to psycopg 3; we use psycopg2, so name the driver explicitly
    if url.startswith("postgresql://"):
        url = "postgresql+psycopg2://" + url[len("postgresql://"):]
    return create_engine(url)


def load_split(engine, split: str) -> pd.DataFrame:
    """Target (0/1) and the WoE features for one sample split."""
    query = text(f"""
        SELECT ps.loan_seq_no,
                ps.target::int AS target,
               {", ".join("w." + f for f in FEATURES)}
        FROM mart.snapshot_woe w
        JOIN mart.pd_sample ps USING (loan_seq_no, snapshot_date)
        WHERE ps.sample_split = :split
    """)
    df = pd.read_sql(query, engine, params={"split": split})
    df[FEATURES] = df[FEATURES].astype("float64")
    return df

def check_collinearity(df: pd.DataFrame, corr_limit: float = 0.6) -> None:
    """Pairwise correlations and VIF of the WoE features."""
    corr = df[FEATURES].corr()
    short = {f: f.removeprefix("woe_") for f in FEATURES}
    print("\ncorrelation matrix:")
    with pd.option_context("display.width", 200, "display.max_columns", None):
        print(corr.rename(index=short, columns=short).round(2))

    print(f"\npairs with |correlation| > {corr_limit}:")
    flagged = False
    for i in range(len(FEATURES)):
        for j in range(i + 1, len(FEATURES)):
            r = corr.iloc[i, j]
            if abs(r) > corr_limit:
                print(f"  {FEATURES[i]} - {FEATURES[j]}: {r:.2f}")
                flagged = True
    if not flagged:
        print("  none")

    sample = df[FEATURES].sample(min(200_000, len(df)), random_state=42)
    X = sm.add_constant(sample)
    vif = pd.Series(
        [variance_inflation_factor(X.values, i) for i in range(1, X.shape[1])],
        index=FEATURES,
        name="VIF",
    )
    print("\nVIF (constant excluded, 200k-row sample):")
    print(vif.round(2))

def fit_logit(df: pd.DataFrame, features: list[str]):
    """Logistic regression of target on the given WoE features (plus intercept).
    Standard errors are cluster-robust by loan: the same loan appears in many snapshots,
    so rows are not independent and ordinary standard errors would be too small."""
    X = sm.add_constant(df[features])
    groups = pd.factorize(df["loan_seq_no"])[0]
    model = sm.Logit(df["target"], X).fit(
        disp=False, cov_type="cluster", cov_kwds={"groups": groups}
    )
    return model


def prune(df: pd.DataFrame, features: list[str], p_limit: float = 0.05):
    """Refit until every coefficient is negative and significant.
    Each round drops ONE feature: first the worst wrong-sign coefficient, else the highest p-value."""
    features = list(features)
    while True:
        model = fit_logit(df, features)
        coefs = model.params.drop("const")
        pvals = model.pvalues.drop("const")
        wrong_sign = coefs[coefs >= 0]
        insignificant = pvals[pvals > p_limit]
        if not wrong_sign.empty:
            drop = wrong_sign.idxmax()
            reason = f"wrong sign (coef {coefs[drop]:+.4f})"
        elif not insignificant.empty:
            drop = insignificant.idxmax()
            reason = f"not significant (p = {pvals[drop]:.4f})"
        else:
            return model, features
        print(f"dropping {drop}: {reason}")
        features.remove(drop)



SPLITS = ["TRAIN", "TEST", "COVID", "OOT"]


def validate(engine, model, features: list[str], train: pd.DataFrame) -> pd.DataFrame:
    """Discrimination (AUC, Gini, KS) and level (mean predicted PD vs observed default rate) per split."""
    rows = []
    for split in SPLITS:
        df = train if split == "TRAIN" else load_split(engine, split)
        X = sm.add_constant(df[features], has_constant="add")
        pd_hat = model.predict(X)
        y = df["target"]
        auc = roc_auc_score(y, pd_hat)
        fpr, tpr, _ = roc_curve(y, pd_hat)
        rows.append({
            "sample_split": split,
            "n": len(df),
            "defaults": int(y.sum()),
            "default_rate": y.mean(),
            "mean_pd": pd_hat.mean(),
            "auc": auc,
            "gini": 2 * auc - 1,
            "ks": np.max(tpr - fpr),
        })
    return pd.DataFrame(rows)

def save_results(engine, model, features: list[str], validation: pd.DataFrame) -> None:
    """Coefficients and validation to the database, model summary to docs/."""
    coef = pd.DataFrame({
        "feature": ["intercept"] + [f.removeprefix("woe_") for f in features],
        "coef": model.params.values,
        "std_err": model.bse.values,
        "z": model.tvalues.values,
        "p_value": model.pvalues.values,
    })
    coef.to_sql("pd_coef", engine, schema="mart", if_exists="replace", index=False)
    validation.to_sql("pd_validation", engine, schema="mart", if_exists="replace", index=False)

    out = REPO_ROOT / "docs" / "pd_model_summary.txt"
    out.parent.mkdir(exist_ok=True)
    out.write_text(
        "PD scorecard: logistic regression on TRAIN WoE features\n"
        "Standard errors cluster-robust by loan (repeated snapshots of the same loan).\n\n"
        + model.summary2().as_text()
        + "\n\nValidation (mean_pd uses the uncalibrated model; calibration happens in 35_pd_score.sql):\n"
        + validation.round(4).to_string(index=False)
        + "\n"
    )
    print(f"\nwritten: mart.pd_coef ({len(coef)} rows), mart.pd_validation, {out.relative_to(REPO_ROOT)}")

def main():
    engine = get_engine()

    train = load_split(engine, "TRAIN")

    with engine.connect() as con:
        n_expected = con.execute(
            text("SELECT count(*) FROM mart.pd_sample WHERE sample_split = 'TRAIN'")
        ).scalar()

    print(f"rows loaded: {len(train):,}   expected: {n_expected:,}   "
          f"{'OK' if len(train) == n_expected else 'MISMATCH'}")
    print(f"default rate: {train['target'].mean():.4%}   defaults: {train['target'].sum():,}")
    print("\nWoE ranges:")
    print(train[FEATURES].describe().T[["min", "max", "mean"]].round(3))
    print("\ndistinct values per feature (should equal the number of bins):")
    print(train[FEATURES].nunique())
    print("\nmissing values (all must be 0):")
    print(train.isna().sum())
    check_collinearity(train)
    model, selected = prune(train, FEATURES)
    print(f"\nselected features ({len(selected)}): {selected}")
    print(model.summary2())
    validation = validate(engine, model, selected, train)
    with pd.option_context("display.width", 200, "display.max_columns", None):
        print("\nvalidation:")
        print(validation.round(4).to_string(index=False))
    save_results(engine, model, selected, validation)



if __name__ == "__main__":
    main()