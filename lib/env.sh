# shellcheck shell=bash
# ============================================================================
# work6 — definicja środowiska (JEDNO źródło prawdy)
#
# Używane w trzech kontekstach:
#   1. lib/sandbox.sh   — jako --setenv wewnątrz bwrap (z HOME=work6/home),
#   2. scripts/activate.sh — source'owane w powłoce agenta poza sandboxem
#                         (BEZ zmiany HOME),
#   3. setup.d/*        — instalatory uruchamiane poza sandboxem.
#
# UWAGA: ten plik NIE ustawia set -e ani trapów — jest source'owany także
# w interaktywnych powłokach.
# ============================================================================

# Wypisuje pary NAZWA=WARTOŚĆ (po jednej na wiersz) wspólne dla wszystkich
# kontekstów. $1 = katalog work6.
work6_env_pairs() {
  local w6="$1"
  printf '%s\n' \
    "XDG_CONFIG_HOME=$w6/config" \
    "XDG_CACHE_HOME=$w6/cache" \
    "XDG_DATA_HOME=$w6/home/.local/share" \
    "XDG_STATE_HOME=$w6/state" \
    "TMPDIR=$w6/tmp" \
    "NPM_CONFIG_USERCONFIG=$w6/config/npmrc" \
    "NPM_CONFIG_PREFIX=$w6/npm-global" \
    "NPM_CONFIG_CACHE=$w6/cache/npm" \
    "PIP_CACHE_DIR=$w6/cache/pip" \
    "PUB_CACHE=$w6/cache/pub" \
    "PLAYWRIGHT_BROWSERS_PATH=$w6/browsers" \
    "CLAUDE_CONFIG_DIR=$w6/home/.claude" \
    "DISABLE_AUTOUPDATER=1"
}

# Wypisuje elementy PATH środowiska work6 (po jednym na wiersz, tylko
# istniejące katalogi). $1 = katalog work6.
work6_path_entries() {
  local w6="$1" d
  for d in \
    "$w6/npm-global/bin" \
    "$w6/node/current/bin" \
    "$w6/tools/claude/current" \
    "$w6/tools/agy/current" \
    "$w6/python/venv/bin" \
    "$w6/tools/flutter/flutter/bin"
  do
    [ -d "$d" ] && printf '%s\n' "$d"
  done
  return 0
}

# Minimalny PATH wewnątrz sandboxa: work6 + systemowe /usr/bin:/bin.
work6_sandbox_path() {
  local w6="$1" p="" e
  while IFS= read -r e; do p="${p:+$p:}$e"; done < <(work6_path_entries "$w6")
  printf '%s' "${p:+$p:}/usr/bin:/bin"
}

# Eksportuje środowisko work6 w bieżącej powłoce (konteksty 2 i 3).
# HOME pozostaje nietknięte — za HOME odpowiada wyłącznie sandbox.
work6_export_env() {
  local w6="$1" line
  while IFS= read -r line; do
    export "${line?}"
  done < <(work6_env_pairs "$w6")
  local p
  p="$(work6_path_entries "$w6" | tr '\n' ':')"
  export PATH="${p}${PATH}"
}
