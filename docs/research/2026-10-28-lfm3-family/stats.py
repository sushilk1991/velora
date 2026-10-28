"""Paired statistics for small decision and ASR benchmarks (stdlib only).

Every head-to-head in this study is paired: both models answer the same items,
so the test is on the discordant pairs, not on two independent accuracies.

    item:     1  2  3  4  5 ...
    model A:  ✓  ✓  ✗  ✓  ✗
    model B:  ✓  ✗  ✓  ✓  ✗
                 b  c          b = A right & B wrong, c = A wrong & B right
    exact McNemar p = P(Binomial(b + c, 0.5) as extreme as b), two-sided

Example: 56/62 vs 52/62 with b = 5, c = 1 gives p = 0.22 — not a real
difference at n = 62.
"""

from __future__ import annotations

import math
from collections.abc import Sequence

Z95 = 1.959963984540054


def wilson(successes: int, n: int, z: float = Z95) -> tuple[float, float]:
    """95% Wilson score interval for a proportion; stays inside [0, 1] at
    the extremes, where the normal interval does not (e.g. 62/62)."""
    if n == 0:
        return (0.0, 1.0)
    p = successes / n
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    return (max(0.0, centre - half), min(1.0, centre + half))


def mcnemar_exact(a_right: Sequence[bool], b_right: Sequence[bool]) -> dict:
    """Two-sided exact McNemar test on paired correctness vectors."""
    if len(a_right) != len(b_right):
        raise ValueError("paired vectors must have the same length")
    b = sum(1 for x, y in zip(a_right, b_right) if x and not y)
    c = sum(1 for x, y in zip(a_right, b_right) if y and not x)
    n = b + c
    if n == 0:
        return {"a_only": b, "b_only": c, "p": 1.0}

    # P(X <= min(b, c)) under Binomial(n, 1/2), doubled, capped at 1.
    k = min(b, c)
    tail = sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n
    return {"a_only": b, "b_only": c, "p": min(1.0, 2 * tail)}


def roc_auc(scores: Sequence[float], positives: Sequence[bool]) -> float | None:
    """Area under the ROC curve (Mann-Whitney U with ties counted half).
    None when one class is empty."""
    pos = [s for s, y in zip(scores, positives) if y]
    neg = [s for s, y in zip(scores, positives) if not y]
    if not pos or not neg:
        return None
    wins = 0.0
    for p in pos:
        for q in neg:
            wins += 1.0 if p > q else 0.5 if p == q else 0.0
    return wins / (len(pos) * len(neg))


def brier(probs: Sequence[float], outcomes: Sequence[bool]) -> float:
    """Mean squared error of a probability against a 0/1 outcome."""
    return sum((p - (1.0 if y else 0.0)) ** 2 for p, y in zip(probs, outcomes)) / len(probs)


def ece(confidences: Sequence[float], correct: Sequence[bool], bins: int = 10) -> dict:
    """Expected calibration error of top-choice confidence, equal-width bins.

    Returns the ECE and the per-bin rows a reliability plot draws:
    (bin low, bin high, n, mean confidence, accuracy).
    """
    rows = []
    total = len(confidences)
    error = 0.0
    for index in range(bins):
        low, high = index / bins, (index + 1) / bins
        members = [
            (c, y) for c, y in zip(confidences, correct)
            if (low <= c < high) or (index == bins - 1 and c == 1.0)
        ]
        if not members:
            continue
        mean_conf = sum(c for c, _ in members) / len(members)
        accuracy = sum(1 for _, y in members if y) / len(members)
        error += len(members) / total * abs(mean_conf - accuracy)
        rows.append((low, high, len(members), round(mean_conf, 4), round(accuracy, 4)))
    return {"ece": error, "bins": rows}


def coverage_at(confidences: Sequence[float], correct: Sequence[bool],
                threshold: float) -> dict:
    """Answer only when confidence >= threshold: the share answered
    (coverage), how many of those are right (precision), and its Wilson CI."""
    taken = [y for c, y in zip(confidences, correct) if c >= threshold]
    right = sum(taken)
    return {
        "threshold": threshold,
        "coverage": len(taken) / len(confidences) if confidences else 0.0,
        "taken": len(taken),
        "precision": right / len(taken) if taken else None,
        "precision_ci": wilson(right, len(taken)) if taken else None,
    }


def max_coverage(confidences: Sequence[float], correct: Sequence[bool],
                 min_precision: float = 0.95) -> dict:
    """The lowest threshold whose answered set still holds precision >=
    `min_precision`, and the coverage it buys. Thresholds are the observed
    confidences, so the result is exact for this sample (and optimistic
    for the next one: the CI says by how much)."""
    best = {"threshold": None, "coverage": 0.0, "taken": 0, "precision": None,
            "precision_ci": None}
    for threshold in sorted(set(confidences)):
        row = coverage_at(confidences, correct, threshold)
        if row["precision"] is not None and row["precision"] >= min_precision:
            if row["coverage"] > best["coverage"]:
                best = row
    return best


def percentile(values: Sequence[float], q: float) -> float:
    """Nearest-rank percentile (q in 0..100) of a non-empty sample."""
    ordered = sorted(values)
    rank = max(1, math.ceil(q / 100 * len(ordered)))
    return ordered[rank - 1]


if __name__ == "__main__":
    # The two numbers PR #25 compared: 56/62 vs 52/62.
    print(wilson(56, 62), wilson(52, 62))
    a = [True] * 56 + [False] * 6
    b = [True] * 51 + [False] * 5 + [True] * 1 + [False] * 5
    print(mcnemar_exact(a, b))
