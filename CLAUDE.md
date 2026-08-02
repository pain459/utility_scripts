# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Common Commands
- **Lint shell scripts**: `shellcheck <script>`
- **Run all tests**: `bats tests/` (if BATS tests exist)
- **Run a single test**: `bats tests/<test-file>.bats -t <test-name>`
- **Format scripts**: `shfmt -w <script>`

## High-Level Architecture
- Scripts are organized as standalone tools for system maintenance and routine tasks.
- Likely uses POSIX-compliant shell idioms with minimal external dependencies.
- May include common patterns like:
  - Library functions in `lib/` directory
  - Entry points in `bin/` directory
  - Configuration in `defaults.sh` or environment variables

Refer to the README for general purpose, but implementation details are script-specific.