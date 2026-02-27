#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/_lib_http.sh"

ADMIN_KEY="${ADMIN_KEY:-}"
[ -n "$ADMIN_KEY" ] || fail "ADMIN_KEY is required"

adminUrl="${BASE_URL}/ui/admin?admin=${ADMIN_KEY}"

echo "==> Open admin autolink (will redirect to client UI)"
echo "$adminUrl"

echo
echo "==> Resolve redirect -> final client link"
loc="$(http_location "$adminUrl" || true)"
[ -n "${loc:-}" ] || fail "no Location header from /ui/admin"

final="$(abs_url "$loc")"
echo "✅ client link:"
echo "$final"

exportUrl="$(echo "$final" | sed 's|/ui/tickets|/ui/export.csv|')"
echo
echo "==> ✅ Export CSV"
echo "$exportUrl"
