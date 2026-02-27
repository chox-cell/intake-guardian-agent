#!/usr/bin/env bash
set -e
OUT="dist/zapier-template-pack"
rm -rf "$OUT"
mkdir -p "$OUT"
cp -R docs/onboarding docs/zapier "$OUT"
echo "zapier pack ready"
