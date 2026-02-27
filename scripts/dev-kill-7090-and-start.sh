#!/usr/bin/env bash
set -euo pipefail
# ASCII-only runner. No patching, no perl.
# Use the canonical dev script that frees the port then runs pnpm dev.
exec bash scripts/dev_7090.sh
