"""Train the PSU risk classifier (thesis Section 3.5) and export it for the app.

Usage:
    pip install pandas scikit-learn
    python ml/train_model.py path/to/smartphone_usage_addiction.csv

Outputs:
    assets/model/rf_model.json  - forest the Flutter app evaluates on-device
    ml/results.txt              - metrics for thesis Table 5.2

Only features with a log-derived counterpart (thesis Table 3.1) are used, and
addiction_level is excluded to avoid target leakage.
"""

import json
import sys
from pathlib import Path

import pandas as pd
from sklearn.ensemble import GradientBoostingClassifier, RandomForestClassifier
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import accuracy_score, classification_report, confusion_matrix, f1_score
from sklearn.model_selection import GridSearchCV, StratifiedKFold, cross_val_score, train_test_split

SEED = 42
TARGET = "addicted_label"
# Must match ForestRiskModel.featureSource in lib/services/risk_model.dart
CANDIDATE_FEATURES = [
    "app_opens_per_day",
    "notifications_per_day",
    "sleep_hours",
    "stress_level",
    "daily_screen_time_hours",
    "social_media_hours",
    "gaming_hours",
    "academic_work_impact",
]
ROOT = Path(__file__).resolve().parent.parent


def load(path):
    df = pd.read_csv(path)
    df.columns = [c.strip().lower() for c in df.columns]
    features = [f for f in CANDIDATE_FEATURES if f in df.columns]
    missing = sorted(set(CANDIDATE_FEATURES) - set(features))
    if missing:
        print(f"Note: dataset lacks {missing}; training without them.")
    df = df.dropna(subset=features + [TARGET]).drop_duplicates()

    # Ordinal-encode text columns (e.g. stress_level = Low/Medium/High).
    order = {"low": 0, "medium": 1, "moderate": 1, "high": 2, "no": 0, "yes": 1}
    for col in features + [TARGET]:
        if df[col].dtype == object:
            df[col] = df[col].str.strip().str.lower().map(order)
            if df[col].isna().any():
                raise ValueError(f"Unrecognised categories in {col}; extend `order`.")
    return df[features].astype(float), df[TARGET].astype(int), features


def export_forest(rf, features, X):
    trees = []
    for est in rf.estimators_:
        t = est.tree_
        values = t.value[:, 0, :]
        positive = (values[:, 1] / values.sum(axis=1)).round(4).tolist()
        trees.append({
            "left": t.children_left.tolist(),
            "right": t.children_right.tolist(),
            "feature": [int(f) if f >= 0 else 0 for f in t.feature],
            "threshold": t.threshold.round(4).tolist(),
            "positive": positive,
        })
    return {
        "features": features,
        "ranges": {f: [float(X[f].min()), float(X[f].max())] for f in features},
        "thresholds": {"medium": 0.4, "high": 0.7},  # probability -> Low/Medium/High
        "trees": trees,
    }


def main(csv_path):
    X, y, features = load(csv_path)
    print(f"{len(X)} rows, features={features}")
    print("Class balance:\n", y.value_counts(normalize=True).round(3))

    X_tr, X_te, y_tr, y_te = train_test_split(X, y, test_size=0.2, stratify=y, random_state=SEED)
    cv = StratifiedKFold(n_splits=5, shuffle=True, random_state=SEED)

    rf = GridSearchCV(
        RandomForestClassifier(random_state=SEED, class_weight="balanced"),
        {"n_estimators": [50, 100], "max_depth": [4, 6, 8], "min_samples_leaf": [5, 20]},
        cv=cv, scoring="f1", n_jobs=-1,
    ).fit(X_tr, y_tr)

    models = {
        "Random Forest": rf.best_estimator_,
        "Gradient Boosting": GradientBoostingClassifier(random_state=SEED).fit(X_tr, y_tr),
        "Logistic Regression (baseline)": LogisticRegression(max_iter=1000).fit(X_tr, y_tr),
    }

    lines = [f"Best RF params: {rf.best_params_}", ""]
    for name, m in models.items():
        pred = m.predict(X_te)
        cv_f1 = cross_val_score(m, X_tr, y_tr, cv=cv, scoring="f1")
        lines += [
            f"== {name} ==",
            f"accuracy={accuracy_score(y_te, pred):.4f}  f1={f1_score(y_te, pred):.4f}  "
            f"cv_f1={cv_f1.mean():.4f} (+/- {cv_f1.std():.4f})",
            classification_report(y_te, pred, digits=4),
            f"confusion matrix:\n{confusion_matrix(y_te, pred)}",
            "",
        ]
    importances = sorted(zip(features, models["Random Forest"].feature_importances_), key=lambda x: -x[1])
    lines += ["RF feature importances:"] + [f"  {f}: {v:.4f}" for f, v in importances]
    report = "\n".join(lines)
    print(report)
    (ROOT / "ml" / "results.txt").write_text(report)

    out = ROOT / "assets" / "model" / "rf_model.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(export_forest(models["Random Forest"], features, X)))
    print(f"\nExported forest to {out} ({out.stat().st_size // 1024} KB). Rebuild the app to use it.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
