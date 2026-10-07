# Toolkit control-plane contract tests

This directory contains offline tests for Toolkit-owned selection, gating,
fixed-SHA owner checkout, caller wiring, receipt validation, and release routing.
The tests may inspect a frozen legacy executor while its owner cutover is still
gated, but they do not execute cloud, host, service, or database operations.

`control-plane-contracts.yml` runs these contracts on pull requests and pushes
using immutable GitOps fixtures. The XConnect XHTTP runtime helper test remains
at `.github/scripts/tests/xconnect_xhttp_runtime_contract_test.sh` until the
Playbooks owner has equivalent helper coverage and the caller cutover is
verified.
