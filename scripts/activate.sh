# shellcheck shell=bash
# ============================================================================
# work6 — activate.sh — środowisko work6 w BIEŻĄCEJ powłoce
#
#   source /home/<agent>/work6/scripts/activate.sh
#
# Ustawia PATH i zmienne (npm, pip, pub, Playwright, CLAUDE_CONFIG_DIR,
# TMPDIR, XDG_*) na katalogi wewnątrz work6. NIE zmienia HOME, NICZEGO
# nie dopisuje do .bashrc/.profile/.zshrc.
#
# UWAGA: to NIE jest sandbox — służy do ręcznej pracy (npm, pip, git).
# Agentów uruchamiaj wyłącznie launcherami z <work6>/bin.
# ============================================================================

# plik musi być source'owany, nie wykonywany
if [ -z "${BASH_SOURCE:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "[work6] użyj: source ${0}" >&2
  exit 64
fi

if [ "$(id -u)" -eq 0 ]; then
  echo "[work6] nie aktywuj środowiska jako root" >&2
  return 64
fi

_w6="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ ! -f "$_w6/.work6-root" ]; then
  echo "[work6] $_w6 nie wygląda na zainstalowane środowisko (brak .work6-root)" >&2
  unset _w6
  return 64
fi

# shellcheck source=../lib/env.sh
. "$_w6/lib/env.sh"
work6_export_env "$_w6"
export WORK6="$_w6"

echo "[work6] środowisko aktywne: $_w6"
echo "[work6] launchery: $_w6/bin  (agent-shell, run-claude, run-agy, ...)"
unset _w6
