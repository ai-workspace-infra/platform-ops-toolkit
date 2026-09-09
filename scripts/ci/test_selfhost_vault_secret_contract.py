#!/usr/bin/env python3
"""Regression checks for selfhost Vault Action secret declarations."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/selfhost-orchestrator.yml"


class SelfhostVaultSecretContractTest(unittest.TestCase):
    def test_each_multiline_vault_secret_entry_has_a_delimiter(self) -> None:
        lines = WORKFLOW.read_text().splitlines()
        vault_step = False
        index = 0

        while index < len(lines):
            stripped = lines[index].strip()
            if stripped.startswith("- name:"):
                vault_step = False
            elif stripped == "uses: hashicorp/vault-action@v4":
                vault_step = True
            elif vault_step and stripped == "secrets: |":
                indent = len(lines[index]) - len(lines[index].lstrip())
                entries: list[str] = []
                index += 1
                while index < len(lines):
                    line = lines[index]
                    line_indent = len(line) - len(line.lstrip())
                    if line.strip() and line_indent <= indent:
                        break
                    if line.strip():
                        entries.append(line.strip())
                    index += 1

                for entry in entries[:-1]:
                    self.assertRegex(
                        entry,
                        re.compile(r";\s*$"),
                        f"Vault secret entry must end with ';': {entry}",
                    )
                continue
            index += 1


if __name__ == "__main__":
    unittest.main()
