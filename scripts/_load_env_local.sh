#!/usr/bin/env bash
# macOS bash 3.2 safe .env loader (no eval)
# supports KEY=value, KEY="value", KEY='value'
# ignores comments/blank lines
load_env_file() {
  local f="${1:-.env.local}"
  [ -f "$f" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac

    case "$line" in
      *=*)
        key="${line%%=*}"
        val="${line#*=}"

        key="${key%"${key##*[![:space:]]}"}"
        key="${key#"${key%%[![:space:]]*}"}"

        echo "$key" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$' || continue

        val="${val#"${val%%[![:space:]]*}"}"
        if [ "${val#\"}" != "$val" ] && [ "${val%\"}" != "$val" ]; then
          val="${val#\"}"; val="${val%\"}"
        elif [ "${val#\'}" != "$val" ] && [ "${val%\'}" != "$val" ]; then
          val="${val#\'}"; val="${val%\'}"
        fi

        export "$key=$val"
      ;;
    esac
  done < "$f"

  # compat: some setups use TENANT_KEYS_JSON but scripts use TENANT_KEYS
  if [ -z "${TENANT_KEYS:-}" ] && [ -n "${TENANT_KEYS_JSON:-}" ]; then
    export TENANT_KEYS="${TENANT_KEYS_JSON}"
  fi
}
