"""
export_tableau.py
Exports the reporting marts to CSV for Tableau (Tableau Public cannot connect to PostgreSQL).
One file per table in exports/tableau/; all are aggregates, no loan-level data.

Run from the repo root (venv active), after sql/40_reporting/:
    python python/export_tableau.py
"""

import pandas as pd
from sqlalchemy import text

from fit_pd_model import REPO_ROOT, get_engine

OUT = REPO_ROOT / "exports" / "tableau"

TABLES = {
    "reporting_dates":     "SELECT * FROM mart.reporting_dates",
    "rpt_ifrs9_stage":     "SELECT * FROM mart.rpt_ifrs9_stage ORDER BY snapshot_date, stage",
    "rpt_stage_migration": "SELECT * FROM mart.rpt_stage_migration ORDER BY from_stage, to_stage",
    "rpt_f18_npe":         "SELECT * FROM mart.rpt_f18_npe ORDER BY category",
    "rpt_pd_grade":        "SELECT * FROM mart.rpt_pd_grade ORDER BY grade",
    "rpt_vintage_curves":  "SELECT * FROM mart.rpt_vintage_curves ORDER BY vintage, months_on_book",
    "rpt_ecl_cube":        "SELECT * FROM mart.rpt_ecl_cube ORDER BY snapshot_date, stage, grade, vintage",
}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    engine = get_engine()
    with engine.connect() as conn:
        for name, sql in TABLES.items():
            df = pd.read_sql(text(sql), conn)
            df.to_csv(OUT / f"{name}.csv", index=False, date_format="%Y-%m-%d")
            print(f"{name:22s} {len(df):>7,d} rows")


if __name__ == "__main__":
    main()
