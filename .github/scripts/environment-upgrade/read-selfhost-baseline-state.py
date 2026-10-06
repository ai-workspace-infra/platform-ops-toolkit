#!/usr/bin/env python3
"""Validate a bound selfhost baseline and select safe read-only acceptance."""

import json
import os
from pathlib import Path


def main() -> None:
    receipt_path = Path(os.environ["RECEIPT_PATH"])
    try:
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit("baseline receipt is missing or invalid JSON") from exc

    parent_run_id = os.environ["EXPECTED_PARENT_RUN_ID"]
    expected = {
        "schema": 1,
        "parent_workflow_run_id": parent_run_id,
        "baseline_workflow_run_id": os.environ["EXPECTED_BASELINE_RUN_ID"],
        "target_host": os.environ["EXPECTED_HOST"],
        "acceptance_run_id": os.environ["EXPECTED_ACCEPTANCE_RUN_ID"],
    }
    if any(receipt.get(key) != value for key, value in expected.items()):
        raise SystemExit("baseline receipt is not bound to this parent, child, host, and acceptance")

    state = receipt.get("captured_state")
    counts = receipt.get("row_counts")
    if state not in {"present", "absent"} or not isinstance(counts, dict):
        raise SystemExit("baseline receipt lacks captured database evidence")

    if any(
        not isinstance(value, int) or isinstance(value, bool) or value < 0
        for value in counts.values()
    ):
        raise SystemExit("baseline receipt has invalid row counts")

    # An initialized Accounts database can contain administrative users while
    # still having no subscription/business sample. Use the read-only health
    # probe for that first-release state; retain fingerprint verification for
    # any database with subscriptions to preserve.
    if state == "present" and "subscriptions" not in counts:
        raise SystemExit("present baseline receipt lacks subscription row count")
    acceptance_mode = (
        "verify" if state == "present" and counts["subscriptions"] > 0 else "probe"
    )

    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with open(output_path, "a", encoding="utf-8") as output:
            output.write(f"captured_state={state}\n")
            output.write(f"acceptance_mode={acceptance_mode}\n")
    print(
        "Verified bound selfhost baseline receipt; "
        f"captured_state={state}, acceptance_mode={acceptance_mode}."
    )


if __name__ == "__main__":
    main()
