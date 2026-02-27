#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> [1] Ensure .gitignore blocks backups/logs/data"
touch .gitignore

grep -q '^# Local junk' .gitignore || cat >> .gitignore <<'GIT'

# Local junk / backups
.tmp_backups/
*.bak.*
*.log
data/
node_modules/
.DS_Store
GIT

echo "==> [2] Move any *.bak.* into .tmp_backups/"
mkdir -p .tmp_backups
find . -maxdepth 6 -type f -name "*.bak.*" -print0 2>/dev/null | while IFS= read -r -d '' f; do
  mv "$f" .tmp_backups/ || true
done

echo "==> [3] Ensure data/ not tracked"
git rm -r --cached data >/dev/null 2>&1 || true

echo "==> [4] Commit cleanup"
git add .gitignore
git commit -m "chore(repo): ignore backups/data and move bak files to .tmp_backups" || true

echo "✅ Cleanup done."
