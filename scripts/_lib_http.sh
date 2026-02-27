#!/usr/bin/env bash
set -euo pipefail

# BASE_URL must be like: http://127.0.0.1:7090
BASE_URL="${BASE_URL:-http://127.0.0.1:7090}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Fetch headers safely (preserve CRLF removal)
http_headers() {
  local url="$1"
  curl -sS -D- -o /dev/null "$url" | tr -d '\r'
}

# Get HTTP status code (first line)
http_status() {
  local url="$1"
  http_headers "$url" | head -n 1 | awk '{print $2}'
}

# Extract Location header (case-insensitive)
http_location() {
  local url="$1"
  http_headers "$url" | awk 'BEGIN{IGNORECASE=1} /^location:/ {sub(/^location:[[:space:]]*/,""); print; exit}'
}

# Turn relative Location into absolute URL
abs_url() {
  local loc="$1"
  if [[ "$loc" =~ ^https?:// ]]; then
    echo "$loc"
  else
    echo "${BASE_URL}${loc}"
  fi
}
