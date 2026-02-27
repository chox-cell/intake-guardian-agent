#!/usr/bin/env bash
set -euo pipefail

TS="$(date +%Y%m%d_%H%M%S)"
BAK="__bak_phase5d_${TS}"
mkdir -p "$BAK"

echo "==> Phase5d OneShot (fix FileStore ctor arg) @ $(pwd)"
cp -f src/server.ts "$BAK/server.ts.bak" 2>/dev/null || true

# Replace: new FileStore({ dataDir: ... } as any)  -> new FileStore(path.resolve(DATA_DIR))
# Replace: new FileStore({ dataDir: ... })         -> new FileStore(path.resolve(DATA_DIR))
# Replace: new FileStore({ ... })                  -> new FileStore(path.resolve(DATA_DIR))
perl -0777 -i -pe '
  s/new\s+FileStore\s*\(\s*\{\s*dataDir\s*:\s*path\.resolve\(DATA_DIR\)\s*\}\s*(?:as\s+any)?\s*\)/new FileStore(path.resolve(DATA_DIR))/g;
  s/new\s+FileStore\s*\(\s*\{\s*dataDir\s*:\s*path\.resolve\(DATA_DIR\)\s*\}\s*\)/new FileStore(path.resolve(DATA_DIR))/g;
  s/new\s+FileStore\s*\(\s*\{\s*dataDir\s*:\s*[^}]+\}\s*(?:as\s+any)?\s*\)/new FileStore(path.resolve(DATA_DIR))/g;
' src/server.ts

echo "==> [1] Show patched lines"
grep -n "new FileStore" -n src/server.ts || true

echo "==> [2] Typecheck"
pnpm -s lint:types

echo
echo "✅ Phase5d OK. Now run:"
echo "  pnpm dev"
echo "Then:"
echo "  BASE_URL=http://127.0.0.1:7090 ./scripts/demo-keys.sh"
echo "  BASE_URL=http://127.0.0.1:7090 ./scripts/smoke-ui.sh"
