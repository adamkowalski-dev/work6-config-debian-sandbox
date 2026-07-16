#!/usr/bin/env bash
# ============================================================================
# work6 — update-tools.sh — ręczna aktualizacja komponentów
#
#   update-tools.sh [node|python|claude|agy|playwright|flutter|vscode ...]
#   update-tools.sh all            # wszystkie włączone
#   Flagi: --force (aktualizuj także przy tej samej wersji), --yes
#
# Zasady:
#   * pokazuje plan (obecna → dostępna wersja) i pyta o potwierdzenie,
#   * PRZED zmianami robi backup konfiguracji (bez tokenów/sesji),
#   * pobrania weryfikowane jak przy instalacji (te same moduły setup.d),
#   * Node wg polityki z install.env (pinned/follow-lts),
#   * po aktualizacji uruchamia szybkie doctor.sh,
#   * NIGDY nie dotyka pakietów systemowych.
# ============================================================================
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$ROOT_DIR/lib/common.sh"
common_init

require_agent_user
require_owned_dir "$WORK6"

FORCE=0
export ASSUME_YES="${ASSUME_YES:-0}"
declare -a WANTED=()
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --yes) export ASSUME_YES=1 ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    all) WANTED=() ;;
    node|python|claude|agy|playwright|flutter|vscode) WANTED+=("$1") ;;
    *) die "nieznany komponent/argument: $1 (użyj --help)" ;;
  esac
  shift
done

log_init update-tools
# eksport środowiska work6 dla instalatorów (npm, playwright itd.)
work6_export_env "$WORK6"

declare -a MODULE_LIST=()
for f in "$WORK6"/setup.d/[0-9][0-9]-*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done

wanted() {
  local m="$1" w
  [ "${#WANTED[@]}" -eq 0 ] && return 0
  for w in "${WANTED[@]}"; do [ "$w" = "$m" ] && return 0; done
  return 1
}

# --- plan ---------------------------------------------------------------------
declare -a PLAN=()
for mod in "${MODULE_LIST[@]}"; do
  wanted "$mod" || continue
  "${mod}_enabled" || { info "[$mod] wyłączony — pomijam"; continue; }
  cur="$("${mod}_installed_version" || true)"
  if [ -z "$cur" ]; then
    info "[$mod] nie zainstalowany — użyj setup-work6.sh --only $mod"
    continue
  fi
  rem="$("${mod}_remote_version" 2>/dev/null || true)"
  if [ -z "$rem" ]; then
    warn "[$mod] nie mogę ustalić dostępnej wersji — pomijam"
    continue
  fi
  if [ "$cur" = "$rem" ] || [ "v$cur" = "$rem" ] || [ "$cur" = "v$rem" ]; then
    if [ "$FORCE" -eq 1 ]; then
      PLAN+=("$mod|$cur|$rem (wymuszone)")
    else
      ok "[$mod] aktualny ($cur)"
    fi
  else
    PLAN+=("$mod|$cur|$rem")
  fi
done

if [ "${#PLAN[@]}" -eq 0 ]; then
  ok "nic do aktualizacji"
  exit 0
fi

echo
info "plan aktualizacji:"
for p in "${PLAN[@]}"; do
  IFS='|' read -r m c r <<<"$p"
  printf '    %-12s %s  ->  %s\n' "$m" "$c" "$r"
done
echo
confirm "Wykonać powyższe aktualizacje?" nie || die "przerwano na Twoje żądanie"

# --- backup przed zmianami ------------------------------------------------------
info "backup konfiguracji przed aktualizacją..."
ASSUME_YES=1 "$WORK6/scripts/backup-config.sh" --auto \
  || die "backup nie powiódł się — przerywam aktualizację"

# --- aktualizacje -----------------------------------------------------------------
FAILED=0
for p in "${PLAN[@]}"; do
  IFS='|' read -r m _ _ <<<"$p"
  echo
  info "[$m] aktualizuję..."
  if "${m}_install" update; then
    ok "[$m] zaktualizowany"
  else
    error "[$m] aktualizacja NIE powiodła się"
    FAILED=$((FAILED + 1))
  fi
done

echo
info "diagnostyka po aktualizacji:"
"$WORK6/scripts/doctor.sh" --quick || warn "doctor zgłosił problemy — przejrzyj wyżej"

[ "$FAILED" -eq 0 ] || die "niepowodzenia: $FAILED (szczegóły wyżej; backup w $WORK6/backups)"
ok "aktualizacja zakończona"
