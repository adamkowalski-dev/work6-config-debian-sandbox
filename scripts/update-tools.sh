#!/usr/bin/env bash
# ============================================================================
# work6 — update-tools.sh — ręczna aktualizacja komponentów
#
#   update-tools.sh [node|python|claude|agy|playwright|flutter|vscode ...]
#   update-tools.sh all            # wszystkie włączone
#   update-tools.sh --check        # tylko diagnoza, NIC nie zmienia
#   Flagi: --check, --force (także przy tej samej wersji / downgrade), --yes
#
# URUCHAMIAĆ NA KONCIE AGENTA, POZA SANDBOXEM:
#   sudo -iu ai-agent
#   ~/work6/scripts/update-tools.sh --check
# To NIE jest skrypt do uruchamiania wewnątrz agent-shell — katalog
# scripts/ jest celowo niewidoczny z sandboxa (agent nie ma podmieniać
# tego, co instaluje jego własne narzędzia).
#
# Zasady:
#   * pokazuje plan (obecna → dostępna wersja) i pyta o potwierdzenie,
#   * PRZED zmianami robi backup konfiguracji (bez tokenów/sesji),
#   * pobrania weryfikowane jak przy instalacji (te same moduły setup.d),
#   * Node wg polityki z install.env (pinned/follow-lts),
#   * po aktualizacji uruchamia szybkie doctor.sh,
#   * NIGDY nie dotyka pakietów systemowych,
#   * NIGDY nie cofa wersji bez --force (porównanie semver, nie string),
#   * przerywa, gdy setup.d w work6 jest starszy niż repo — inaczej
#     aktualizacja leciałaby kodem sprzed `git pull`.
# ============================================================================
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$ROOT_DIR/lib/common.sh"
common_init

require_agent_user
require_owned_dir "$WORK6"

FORCE=0
CHECK_ONLY=0
export ASSUME_YES="${ASSUME_YES:-0}"
declare -a WANTED=()
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    --check|--dry-run) CHECK_ONLY=1 ;;
    --yes) export ASSUME_YES=1 ;;
    -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    all) WANTED=() ;;
    node|python|claude|agy|playwright|flutter|vscode) WANTED+=("$1") ;;
    *) die "nieznany komponent/argument: $1 (użyj --help)" ;;
  esac
  shift
done

log_init update-tools
# eksport środowiska work6 dla instalatorów (npm, playwright itd.)
work6_export_env "$WORK6"

# --- czy work6 ma aktualny kod z repo? -----------------------------------------
# Moduły ładujemy z $WORK6/setup.d (kopia zsynchronizowana przez
# setup-work6.sh), a NIE z repo. Po `git pull` w repo aktualizacja
# leciałaby więc starym kodem — i to jest cichy powód, dla którego
# „poprawka jest w repo, a nic się nie zmienia".
check_repo_sync() {
  local repo="${WORK6_CONFIG_REPO:-$HOME/work6-config}" d f base stale=0
  [ -d "$repo" ] || return 0
  [ "$(readlink -f "$repo")" = "$(readlink -f "$WORK6")" ] && return 0
  for d in setup.d lib bin scripts; do
    [ -d "$repo/$d" ] || continue
    for f in "$repo/$d"/*; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"
      [ -f "$WORK6/$d/$base" ] || { stale=1; break 2; }
      cmp -s "$f" "$WORK6/$d/$base" || { stale=1; break 2; }
    done
  done
  [ "$stale" -eq 0 ] && return 0
  error "kod w $WORK6 jest inny niż w repo ($repo)"
  error "aktualizacja poleciałaby STARYMI modułami — przerywam."
  error "zsynchronizuj najpierw:  $repo/setup-work6.sh --yes"
  exit 1
}
check_repo_sync

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
# Każdy komponent kończy się JAWNYM werdyktem. Żadnego cichego „pomijam":
# jeśli czegoś nie da się ustalić, na ekranie ma być powód.
declare -a PLAN=()
for mod in "${MODULE_LIST[@]}"; do
  wanted "$mod" || continue
  if ! "${mod}_enabled"; then
    info "[$mod] wyłączony w install.env — pomijam"
    continue
  fi

  cur="$("${mod}_installed_version" || true)"
  if [ -z "$cur" ]; then
    warn "[$mod] nie wykryto zainstalowanej wersji"
    info  "[$mod] instalacja od zera: setup-work6.sh --only $mod"
    continue
  fi

  # Błędy remote_version idą na ekran (moduły nie wołają już die).
  if ! rem="$("${mod}_remote_version")"; then
    warn "[$mod] nie mogę ustalić dostępnej wersji (powód wyżej) — pomijam"
    continue
  fi

  # Kontekst: dryf self-update / dystans między kanałami.
  if declare -F "${mod}_channel_note" >/dev/null; then
    note="$("${mod}_channel_note" 2>/dev/null || true)"
    [ -n "$note" ] && info "[$mod] $note"
  fi

  semver_cmp "$cur" "$rem"; cmp_rc=$?
  case "$cmp_rc" in
    0)  # ta sama wersja
        if [ "$FORCE" -eq 1 ]; then
          PLAN+=("$mod|$cur|$rem|przeinstalowanie (--force)")
        else
          ok "[$mod] aktualny ($cur)"
        fi
        ;;
    2)  # lokalnie starsza → normalna aktualizacja
        PLAN+=("$mod|$cur|$rem|aktualizacja")
        ;;
    1)  # lokalnie NOWSZA niż źródło → downgrade, domyślnie odmawiamy
        if [ "$FORCE" -eq 1 ]; then
          warn "[$mod] COFNIĘCIE wersji $cur -> $rem (wymuszone --force)"
          PLAN+=("$mod|$cur|$rem|COFNIĘCIE WERSJI")
        else
          warn "[$mod] lokalna wersja ($cur) jest nowsza niż dostępna ($rem)"
          info  "[$mod] nie cofam wersji; jeśli świadomie chcesz: --force"
        fi
        ;;
    *)  # nieporównywalne — nie zgadujemy kierunku
        if [ "$cur" = "$rem" ]; then
          ok "[$mod] aktualny ($cur)"
        else
          warn "[$mod] wersji '$cur' i '$rem' nie umiem porównać (nie-semver)"
          info  "[$mod] wymuszenie instalacji dostępnej wersji: --force"
          [ "$FORCE" -eq 1 ] && PLAN+=("$mod|$cur|$rem|wymuszone (nieporównywalne)")
        fi
        ;;
  esac
done

if [ "${#PLAN[@]}" -eq 0 ]; then
  echo
  ok "nic do aktualizacji"
  exit 0
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  echo
  info "do aktualizacji (--check: NIC nie zostało zmienione):"
  for p in "${PLAN[@]}"; do
    IFS='|' read -r m c r why <<<"$p"
    printf '    %-12s %s  ->  %s   [%s]\n' "$m" "$c" "$r" "$why"
  done
  echo
  info "wykonanie: $WORK6/scripts/update-tools.sh ${WANTED[*]:-all}"
  exit 0
fi

echo
info "plan aktualizacji:"
for p in "${PLAN[@]}"; do
  IFS='|' read -r m c r why <<<"$p"
  printf '    %-12s %s  ->  %s   [%s]\n' "$m" "$c" "$r" "$why"
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
  IFS='|' read -r m _ _ _ <<<"$p"
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
