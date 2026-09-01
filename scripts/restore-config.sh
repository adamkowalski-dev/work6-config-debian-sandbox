#!/usr/bin/env bash
# ============================================================================
# work6 - restore-config.sh - przywracanie konfiguracji z backupu
#
#   restore-config.sh <archiwum.tar.gz>
#
# Zasady:
#   * najpierw pokazuje zawartość archiwum i plan,
#   * każdy nadpisywany plik wymaga potwierdzenia (albo „a" = wszystkie),
#   * przywraca wyłącznie do <work6>, odrzuca ścieżki spoza jawnej listy,
#   * sekretów nie przywraca - backupy ich nie zawierają.
# ============================================================================
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$ROOT_DIR/lib/common.sh"
common_init

require_agent_user
require_owned_dir "$WORK6"

ARCHIVE="${1:-}"
[ -n "$ARCHIVE" ] || die "użycie: restore-config.sh <archiwum.tar.gz> (backupy: $WORK6/backups)"
[ -f "$ARCHIVE" ] || die "brak pliku: $ARCHIVE"

# ścieżki, które wolno przywrócić (te same, które pakuje backup-config.sh)
allowed() {
  case "$1" in
    config/install.env|config/sandbox.env|config/versions.env|config/npmrc|\
    state/manifest.tsv|state/admin-todo.pkgs|state/backup-inventory.txt|\
    home/.claude/settings.json|home/.claude/CLAUDE.md) return 0 ;;
    *) return 1 ;;
  esac
}

info "zawartość archiwum:"
tar -tzf "$ARCHIVE" | sed 's/^/    /'
echo
confirm "Kontynuować przywracanie do $WORK6?" nie || die "przerwano"

# --- walidacja zawartości archiwum PRZED jakąkolwiek ekstrakcją -----------------
# tar -tzf listuje wpisy (pliki i katalogi) bez ich wypakowywania; odrzucamy
# całe archiwum, jeśli którykolwiek wpis wygląda podejrzanie, zanim cokolwiek
# trafi na dysk.
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  case "$entry" in
    /*) die "archiwum zawiera ścieżkę absolutną: $entry" ;;
  esac
  case "$entry" in
    *..*) die "archiwum zawiera podejrzaną ścieżkę (..): $entry" ;;
  esac
  case "$entry" in
    */)
      # wpis katalogowy - dopuszczalny tylko jako prefiks dozwolonej ścieżki
      ok_dir=0
      for allowed_path in \
        config/install.env config/sandbox.env config/versions.env config/npmrc \
        state/manifest.tsv state/admin-todo.pkgs state/backup-inventory.txt \
        home/.claude/settings.json home/.claude/CLAUDE.md; do
        candidate="$allowed_path/"
        if [ "${candidate#"$entry"}" != "$candidate" ]; then
          ok_dir=1
          break
        fi
      done
      [ "$ok_dir" -eq 1 ] || die "archiwum zawiera katalog spoza listy dozwolonych: $entry"
      ;;
    *)
      allowed "$entry" || die "archiwum zawiera plik spoza listy dozwolonych: $entry"
      ;;
  esac
done < <(tar -tzf "$ARCHIVE")

staging="$(mktemp -d "$WORK6/tmp/restore.XXXXXX")"
cleanup() { rm -rf -- "$staging"; }
trap cleanup EXIT
tar -xzf "$ARCHIVE" -C "$staging"

ALL=0
restored=0; skipped=0
while IFS= read -r -d '' f; do
  rel="${f#"$staging"/}"
  if ! allowed "$rel"; then
    warn "pomijam ścieżkę spoza listy dozwolonych: $rel"
    skipped=$((skipped + 1))
    continue
  fi
  target="$WORK6/$rel"
  if [ -f "$target" ] && cmp -s -- "$f" "$target"; then
    info "$rel - identyczny, pomijam"
    continue
  fi
  if [ -f "$target" ] && [ "$ALL" -eq 0 ]; then
    warn "$rel różni się od bieżącego"
    ans=""
    read -r -p "  nadpisać? [t/N/a=wszystkie] " ans </dev/tty || die "brak terminala"
    case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
      a) ALL=1 ;;
      t|tak|y|yes) : ;;
      *) info "  zostawiam bieżący"; skipped=$((skipped + 1)); continue ;;
    esac
  fi
  ensure_dir "$(dirname "$target")" 0700
  install -m 0600 -- "$f" "$target"
  ok "przywrócono: $rel"
  restored=$((restored + 1))
done < <(find "$staging" -type f -print0)

echo
ok "przywracanie zakończone: ${restored} plików (pominięto: ${skipped})"
info "sprawdź środowisko: $WORK6/scripts/doctor.sh"
