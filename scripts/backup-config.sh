#!/usr/bin/env bash
# ============================================================================
# work6 — backup-config.sh — kopia KONFIGURACJI (nigdy sekretów)
#
#   backup-config.sh [--auto]
#
# Archiwum trafia do <work6>/backups/work6-config-<data>.tar.gz (0600).
#
# ZAWIERA (jawna lista — nic „przy okazji"):
#   config/install.env, config/sandbox.env, config/versions.env,
#   config/npmrc, state/manifest.tsv, state/admin-todo.pkgs,
#   home/.claude/settings.json, home/.claude/CLAUDE.md,
#   state/backup-inventory.txt (wygenerowany spis wersji narzędzi).
#
# NIE ZAWIERA (celowo): tokenów i sesji OAuth (.credentials.json itd.),
# profilu przeglądarki, projektów, żadnych plików .env projektów,
# cache ani historii. Szyfrowania nie implementujemy — jeśli potrzebne,
# zaszyfruj archiwum samodzielnie (np. age/gpg).
#
# --auto: bez pytań i bez rotacji (używane przez update-tools.sh).
# ============================================================================
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$ROOT_DIR/lib/common.sh"
common_init

require_agent_user
require_owned_dir "$WORK6"

AUTO=0
[ "${1:-}" = "--auto" ] && AUTO=1

ts="$(date +%Y%m%d-%H%M%S)"
out="$WORK6/backups/work6-config-${ts}.tar.gz"

# --- spis wersji narzędzi (manifest do archiwum) -----------------------------
inv="$WORK6/state/backup-inventory.txt"
{
  echo "# work6 inventory — $(timestamp)"
  echo "## versions.env"
  cat "$VERSIONS_FILE" 2>/dev/null || true
  echo "## npm -g"
  [ -x "$WORK6/node/current/bin/npm" ] \
    && NPM_CONFIG_USERCONFIG="$WORK6/config/npmrc" \
       "$WORK6/node/current/bin/npm" ls -g --depth=0 2>/dev/null || true
  echo "## pip freeze"
  [ -x "$WORK6/python/venv/bin/pip" ] \
    && "$WORK6/python/venv/bin/pip" freeze 2>/dev/null || true
  echo "## rozszerzenia edytora"
  for b in "$WORK6/tools/vscode/current/bin/codium" \
           "$WORK6/tools/vscode/current/bin/code"; do
    [ -x "$b" ] && "$b" --list-extensions 2>/dev/null && break
  done
  true
} >"$inv"
chmod 0600 "$inv"

# --- jawna lista plików -------------------------------------------------------
declare -a FILES=()
for f in config/install.env config/sandbox.env config/versions.env \
         config/npmrc state/manifest.tsv state/admin-todo.pkgs \
         home/.claude/settings.json home/.claude/CLAUDE.md \
         state/backup-inventory.txt; do
  [ -f "$WORK6/$f" ] && FILES+=("$f")
done
[ "${#FILES[@]}" -gt 0 ] || die "nie znalazłem żadnych plików konfiguracji do zabezpieczenia"

# Kontrola bezpieczeństwa: nigdy nie pakujemy znanych plików sekretów.
for f in "${FILES[@]}"; do
  case "$f" in
    *credentials*|*token*|*.env.local|home/.claude/.credentials.json)
      die "odmowa: $f wygląda na plik sekretów" ;;
  esac
done

if [ "$AUTO" -eq 0 ]; then
  info "do archiwum trafi:"
  printf '    %s\n' "${FILES[@]}"
  confirm "Utworzyć backup ${out}?" tak || die "przerwano"
fi

tar -czf "$out" -C "$WORK6" "${FILES[@]}"
chmod 0600 "$out"
ok "backup: $out ($(du -h "$out" | cut -f1))"

# --- rotacja (tylko interaktywnie) ---------------------------------------------
if [ "$AUTO" -eq 0 ]; then
  keep="${BACKUP_KEEP:-10}"
  mapfile -t old < <(ls -1t "$WORK6/backups"/work6-config-*.tar.gz 2>/dev/null \
    | tail -n +$((keep + 1)))
  if [ "${#old[@]}" -gt 0 ]; then
    warn "starych backupów ponad limit (${keep}): ${#old[@]}"
    printf '    %s\n' "${old[@]}"
    if confirm "Usunąć powyższe najstarsze archiwa?" nie; then
      rm -f -- "${old[@]}"
      ok "usunięto ${#old[@]} starych archiwów"
    fi
  fi
fi
