#!/usr/bin/env python3
"""Scoring parity gate: Swift QueryEngine vs the Python reference client.

The five-dimension scorer (DESIGN.md §6.2) is implemented twice on purpose:
`QueryEngine` in GVGLQuery (used by gvglui and gvglact) and `score_entity`
here (the CLI agents actually call). They were kept in sync by hand — the
exact drift risk this repository has already paid for twice (size bands were
recalibrated in both files manually).

This script pins both implementations to the same vectors in
Tests/Fixtures/query_vectors.json, so a weight, band or normalization drift
fails loudly instead of surfacing later as "the CLI disagrees with the
daemon-side library".

Usage:
    python3 scripts/test_scoring_parity.py

Exit 0 = every vector matches on all five tiers and the total.
"""
import importlib.util
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURE = ROOT / "Tests" / "Fixtures" / "query_vectors.json"


def prepare(entity: dict) -> dict:
    """Fill the derived keys the frame JSON normally carries.

    Recomputed here instead of stored in the fixture, so a wrong fixture
    value cannot silently agree with both implementations.
    """
    geometry = entity["geometry"]

    def rect(array: list) -> dict:
        return {"x": array[0], "y": array[1], "w": array[2], "h": array[3]}

    geometry["screen"] = rect(geometry["screen"])
    geometry["window"] = rect(geometry["window"])
    screen = geometry["screen"]
    geometry["area"] = screen["w"] * screen["h"]
    cx, cy = screen["x"] + screen["w"] / 2, screen["y"] + screen["h"] / 2
    row = "q1" if cy < 0.5 else "q3"
    geometry["region"] = row if cx < 0.5 else ("q2" if cy < 0.5 else "q4")
    return entity


def load_client():
    spec = importlib.util.spec_from_file_location(
        "gvgl_query", ROOT / "client" / "gvgl_query.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    cases = json.loads(FIXTURE.read_text())["cases"]
    client = load_client()
    failures = []

    for case in cases:
        by_id = {e["id"]: prepare(dict(e)) for e in case["entities"]}
        target = by_id[case["target"]]
        params = case["params"]
        ref_id = params.get("refID")
        ref = by_id.get(ref_id) if ref_id else None

        total, breakdown = client.score_entity(
            target, params.get("role"), params.get("label"),
            ref, params.get("refDir"), by_id,
        )
        expected = case["expected"]
        for key in ("semantic", "role", "spatial", "size", "topology"):
            if abs(breakdown[key] - expected[key]) > 1e-9:
                failures.append(
                    f"{case['name']}: {key} got {breakdown[key]}, want {expected[key]}"
                )
        if abs(total - expected["total"]) > 1e-9:
            failures.append(
                f"{case['name']}: total got {total}, want {expected['total']}"
            )

    if failures:
        print("scoring parity FAILED:")
        for line in failures:
            print("  " + line)
        return 1
    print(f"✓ scoring parity: {len(cases)} vectors match between "
          f"QueryEngine (Swift) and client/gvgl_query.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
