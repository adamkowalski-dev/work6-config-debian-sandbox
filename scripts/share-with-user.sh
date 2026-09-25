#!/usr/bin/env bash
# ============================================================================
# work6 — share-with-user.sh — dostęp ACL do drzewa $WORK6 dla usera hosta
#
#   share-with-user.sh [--mode ro|rw] UZYTKOWNIK
#
# Nadaje wskazanemu userowi Linuksa (typowo: operator/admin, który loguje
# się na tę maszynę fizycznie albo przez GUI) dostęp do CAŁEGO drzewa
# $WORK6 — projekty, home sandboxa, cache, stan, wszystkie podkatalogi —
# łącznie z plikami, które dopiero powstaną (zapisywanymi przez agenta
# w sandboxie). Kierunek izolacji zostaje NIETKNIĘTY: ai-agent nadal nie
# widzi niczego z hosta poza $WORK6 (lib/sandbox.sh, prepare-system.sh) —
# ten skrypt otwiera wyłącznie kierunek przeciwny (operator -> praca agenta).
#
#   --mode ro (domyślnie) — tylko odczyt + wejście do katalogów (rX)
#   --mode rw             — pełny odczyt i zapis (rwX)
#
# Mechanizm: POSIX ACL (setfacl), nie ruszamy umask 077 ani tradycyjnych
# bitów właściciela — to zostaje jak jest (współdzielone z bezpieczeństwem
# całej reszty repo). Default ACL (setfacl -d) sprawia, że NOWY plik
# tworzony przez agenta pod umask 077 i tak dostaje wpis dla UZYTKOWNIKA —
# zweryfikowane empirycznie w kontenerze Debian 13 (PR z tym skryptem).
#
# WAŻNE: zwykły `chmod` na katalogu z ACL nadpisuje maskę ACL (nie usuwa
# wpisów, ale zeruje ich efektywne uprawnienia, dopóki maska nie wróci).
# ensure_tree() w lib/common.sh robi taki chmod na całym $WORK6 przy
# KAŻDYM uruchomieniu setup-work6.sh — dlatego ten skrypt jest wołany
# automatycznie na końcu setup-work6.sh, gdy w config/install.env
# ustawiony jest SHARE_WITH_USER. Ręczne uruchomienie jest równie
# poprawne i w pełni idempotentne.
# ============================================================================
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$ROOT_DIR/lib/common.sh"
common_init

require_agent_user
require_owned_dir "$WORK6"

MODE="ro"
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="${2:?--mode wymaga ro|rw}"; shift ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "nieznana flaga: $1" ;;
    *) [ -z "$TARGET" ] && TARGET="$1" || die "podaj jednego użytkownika" ;;
  esac
  shift
done
[ -n "$TARGET" ] || die "użycie: share-with-user.sh [--mode ro|rw] UZYTKOWNIK"
case "$MODE" in ro|rw) ;; *) die "--mode musi być ro lub rw (jest: $MODE)" ;; esac

getent passwd "$TARGET" >/dev/null || die "brak użytkownika hosta: $TARGET"
[ "$TARGET" != "$AGENT_USER" ] || die "TARGET nie może być kontem agenta samym sobą"
[ "$TARGET" != "root" ] || die "odmowa: nie nadaję ACL dla roota tym skryptem"

need_cmd setfacl "apt install acl (przez prepare-system.sh)"

RIGHTS="rX"
[ "$MODE" = "rw" ] && RIGHTS="rwX"

agent_home="$(getent passwd "$AGENT_USER" | cut -d: -f6)"

# setfacl -R sam w sobie jest odporny — przechodzi całe poddrzewo i zgłasza
# każde niepowodzenie z osobna (np. luźne obiekty gita zhardlinkowane do
# inode'a innego właściciela: EPERM na chmod/ACL, bo o zmianie ACL decyduje
# właściciel PLIKU, nie ścieżki). set -e ubiłby całą pętlę po WORK6_TREE na
# pierwszym takim pliku — zbieramy błędy i lecimy dalej, żeby jeden zepsuty
# obiekt nie blokował ACL na resztę drzewa (scripts/, backups/, state/...).
FAILED=()

_acl_try() { # _acl_try OPIS -- setfacl ...
  local desc="$1"; shift; shift # $1=opis, $2="--" (odrzucone)
  if ! "$@" 2>&1 | sed 's/^/    /'; then
    FAILED+=("$desc")
  fi
  return 0
}

# Traverse-only na home agenta i na korzeniu $WORK6 — bez tego TARGET nie
# wejdzie w głąb, nawet mając pełne ACL na docelowych podkatalogach.
_acl_try "$agent_home (traverse)" -- setfacl -m "u:${TARGET}:x" -- "$agent_home"
_acl_try "$WORK6 (traverse)" -- setfacl -m "u:${TARGET}:${RIGHTS}" -- "$WORK6"

for d in "${WORK6_TREE[@]}"; do
  p="$WORK6/$d"
  [ -e "$p" ] || continue
  [ -L "$p" ] && { warn "$p jest dowiązaniem symbolicznym — pomijam"; continue; }
  [ -d "$p" ] || continue
  _acl_try "$p (access)" -- setfacl -R -m "u:${TARGET}:${RIGHTS}" -- "$p"
  _acl_try "$p (default)" -- setfacl -R -d -m "u:${TARGET}:${RIGHTS}" -- "$p"
done

if [ "${#FAILED[@]}" -eq 0 ]; then
  ok "ACL dla '${TARGET}' (${MODE}) odświeżone na całym drzewie \$WORK6 ($WORK6)"
else
  warn "ACL dla '${TARGET}' (${MODE}) odświeżone częściowo — ${#FAILED[@]} ścieżek zgłosiło błędy (patrz wyżej):"
  printf '    %s\n' "${FAILED[@]}" >&2
  warn "typowa przyczyna: pliki nie należą do '${AGENT_USER}' (np. luźne obiekty .git"
  warn "zhardlinkowane przy lokalnym 'git clone' z checkoutu innego użytkownika) —"
  warn "zmiana ACL wymaga bycia właścicielem PLIKU, nie tylko dostępu do ścieżki."
fi
info "sprawdź:  sudo -u ${TARGET} ls -la ${WORK6}/projects"
info "kierunek izolacji nietknięty: ai-agent nadal nie widzi niczego z hosta poza \$WORK6."
[ "${#FAILED[@]}" -eq 0 ] || exit 1
