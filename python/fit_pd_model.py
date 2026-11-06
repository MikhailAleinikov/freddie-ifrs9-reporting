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
        SELECT ps.target::int AS target,
               {", ".join("w." + f for f in FEATURES)}
        FROM mart.snapshot_woe w
        JOIN mart.pd_sample ps USING (loan_seq_no, snapshot_date)
        WHERE ps.sample_split = :split
    """)
    df = pd.read_sql(query, engine, params={"split": split})
    df[FEATURES] = df[FEATURES].astype("float64")
    return df


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


if __name__ == "__main__":
    main()