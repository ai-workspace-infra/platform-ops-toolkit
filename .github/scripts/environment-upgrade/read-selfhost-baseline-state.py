#!/usr/bin/env python3
"""Validate the exact selfhost baseline receipt and expose its captured state."""

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
    if state not in {"present", "absent"} or not isinstance(receipt.get("row_counts"), dict):
        raise SystemExit("baseline receipt lacks captured database evidence")

    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with open(output_path, "a", encoding="utf-8") as output:
            output.write(f"captured_state={state}\n")
    print(f"Verified bound selfhost baseline receipt; captured_state={state}.")


if __name__ == "__main__":
    main()
