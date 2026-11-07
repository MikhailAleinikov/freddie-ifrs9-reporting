"""
make_charts.py
Static charts from the reporting marts, saved to docs/img/ for the README.

Run from the repo root (venv active), after sql/40_reporting/40_reports.sql:
    python python/make_charts.py
"""

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as mtick
import numpy as np
import pandas as pd
from sqlalchemy import text

from fit_pd_model import REPO_ROOT, get_engine

OUT = REPO_ROOT / "docs" / "img"
STAGE_COLORS = {1: "#4C9F70", 2: "#E3A33B", 3: "#C4483E"}

plt.rcParams.update({
    "figure.dpi": 120,
    "axes.spines.top": False,
    "axes.spines.right": False,
    "axes.grid": True,
    "grid.alpha": 0.3,
    "font.size": 10,
})


def q(engine, sql: str) -> pd.DataFrame:
    return pd.read_sql(text(sql), engine)


def stage_mix(engine):
    df = q(engine, "SELECT snapshot_date, stage, gross_carrying_amount FROM mart.rpt_ifrs9_stage")
    df["gross_carrying_amount"] = df["gross_carrying_amount"].astype(float)
    wide = df.pivot(index="snapshot_date", columns="stage", values="gross_carrying_amount").fillna(0)
    share = wide.div(wide.sum(axis=1), axis=0)
    fig, ax = plt.subplots(figsize=(9, 4.5))
    ax.stackplot(pd.to_datetime(share.index), *[share[s] for s in (1, 2, 3)],
                 labels=["Stage 1", "Stage 2", "Stage 3"],
                 colors=[STAGE_COLORS[s] for s in (1, 2, 3)], alpha=0.9)
    ax.set_ylim(0.6, 1)
    ax.yaxis.set_major_formatter(mtick.PercentFormatter(1))
    ax.set_title("IFRS 9 stage mix (share of gross carrying amount, y-axis from 60%)")
    ax.legend(loc="lower left", frameon=False)
    fig.tight_layout()
    fig.savefig(OUT / "stage_mix.png")
    plt.close(fig)


def ecl_coverage(engine):
    df = q(engine, """
        SELECT snapshot_date, sum(ecl) AS ecl, sum(ecl) / sum(gross_carrying_amount) AS coverage
        FROM mart.rpt_ifrs9_stage GROUP BY snapshot_date ORDER BY snapshot_date
    """)
    df[["ecl", "coverage"]] = df[["ecl", "coverage"]].astype(float)
    dates = pd.to_datetime(df["snapshot_date"])
    fig, ax1 = plt.subplots(figsize=(9, 4.5))
    ax1.bar(dates, df["ecl"] / 1e6, width=70, color="#6C8EBF", label="ECL ($m)")
    ax1.set_ylabel("ECL ($m)")
    ax2 = ax1.twinx()
    ax2.plot(dates, df["coverage"], color="#C4483E", lw=2, label="Coverage (ECL / GCA)")
    ax2.yaxis.set_major_formatter(mtick.PercentFormatter(1, decimals=1))
    ax2.grid(False)
    ax2.spines["right"].set_visible(True)
    ax1.set_title("Expected credit loss and coverage ratio")
    h1, l1 = ax1.get_legend_handles_labels()
    h2, l2 = ax2.get_legend_handles_labels()
    ax1.legend(h1 + h2, l1 + l2, loc="upper right", frameon=False)
    fig.tight_layout()
    fig.savefig(OUT / "ecl_coverage.png")
    plt.close(fig)


def master_scale(engine):
    df = q(engine, "SELECT grade, dr_train, dr_oot, pd_pit FROM mart.rpt_pd_grade ORDER BY grade")
    df = df.astype(float)
    x = np.arange(len(df))
    w = 0.27
    fig, ax = plt.subplots(figsize=(8, 4.5))
    ax.bar(x - w, df["dr_train"], w, label="Default rate TRAIN (2006-2018)", color="#9DB4C0")
    ax.bar(x, df["dr_oot"], w, label="Default rate OOT (2022+)", color="#5C6B73")
    ax.bar(x + w, df["pd_pit"], w, label="Calibrated PIT PD", color="#C4483E")
    ax.set_yscale("log")
    ax.yaxis.set_major_formatter(mtick.PercentFormatter(1, decimals=2))
    ax.set_xticks(x, [f"Grade {int(g)}" for g in df["grade"]])
    ax.set_title("Master scale: 12-month default rate by grade (log scale)")
    ax.legend(frameon=False)
    fig.tight_layout()
    fig.savefig(OUT / "master_scale.png")
    plt.close(fig)


def migration(engine):
    df = q(engine, "SELECT from_stage, to_stage, loans FROM mart.rpt_stage_migration")
    rows = [r for r in ["New", "Stage 1", "Stage 2", "Stage 3"] if r in set(df["from_stage"])]
    cols = ["Stage 1", "Stage 2", "Stage 3", "Derecognised"]
    m = df.pivot(index="from_stage", columns="to_stage", values="loans").reindex(index=rows, columns=cols).fillna(0)
    pct = m.div(m.sum(axis=1), axis=0)
    fig, ax = plt.subplots(figsize=(7, 4))
    ax.imshow(pct.values, cmap="Blues", vmin=0, vmax=1)
    ax.grid(False)
    ax.set_xticks(range(len(cols)), cols)
    ax.set_yticks(range(len(rows)), rows)
    for i in range(len(rows)):
        for j in range(len(cols)):
            v = pct.values[i, j]
            ax.text(j, i, f"{v:.1%}\n({int(m.values[i, j]):,})", ha="center", va="center",
                    fontsize=8, color="white" if v > 0.6 else "black")
    ax.set_xlabel("Reporting date")
    ax.set_ylabel("Comparison date")
    ax.set_title("Stage migration over the last quarter (share of loans)")
    fig.tight_layout()
    fig.savefig(OUT / "stage_migration.png")
    plt.close(fig)


def vintage_curves(engine):
    df = q(engine, "SELECT vintage, months_on_book, cum_default_rate FROM mart.rpt_vintage_curves")
    df["cum_default_rate"] = df["cum_default_rate"].astype(float)
    fig, ax = plt.subplots(figsize=(9, 4.5))
    vintages = sorted(df["vintage"].unique(), key=lambda v: int(v))
    cmap = plt.get_cmap("viridis", len(vintages))
    for i, v in enumerate(vintages):
        d = df[df["vintage"] == v]
        style = "-" if int(v) <= 2008 else "--"
        ax.plot(d["months_on_book"], d["cum_default_rate"], style, color=cmap(i), lw=1.6, label=str(v))
    ax.yaxis.set_major_formatter(mtick.PercentFormatter(1))
    ax.set_xlabel("Months since first payment")
    ax.set_title("Vintage curves: cumulative share of loans defaulted (solid = 2006-2008)")
    ax.legend(ncol=2, fontsize=8, frameon=False, loc="upper left")
    fig.tight_layout()
    fig.savefig(OUT / "vintage_curves.png")
    plt.close(fig)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    engine = get_engine()
    for chart in (stage_mix, ecl_coverage, master_scale, migration, vintage_curves):
        chart(engine)
        print(f"saved {chart.__name__}")
    print(f"charts in {OUT.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()