#!/usr/bin/env bash
# ============================================================================
# work6 — doctor.sh — diagnostyka środowiska
#
#   doctor.sh [--quick]
#
# Sprawdza: użytkownika, uprawnienia, komponenty, sandbox (w tym testy
# szczelności wewnątrz bwrap), miejsce na dysku. Kod wyjścia:
#   0 = OK (ew. ostrzeżenia), 1 = problemy krytyczne.
# --quick pomija wolne testy (wersje Fluttera itp.).
# ============================================================================
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$ROOT_DIR/lib/common.sh"
common_init
# shellcheck source=../lib/sandbox.sh
. "$ROOT_DIR/lib/sandbox.sh"

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

CRIT=0; WARNS=0
pass() { ok "$*"; }
crit() { error "$*"; CRIT=$((CRIT + 1)); }
warns() { warn "$*"; WARNS=$((WARNS + 1)); }

echo "=== work6 doctor — $(timestamp) ==="

# --- 1. użytkownik -----------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  crit "działasz jako root — środowisko agenta nigdy nie działa jako root"
  exit 1
fi
if [ "$(id -un)" = "$AGENT_USER" ]; then
  pass "użytkownik: $(id -un) (uid $(id -u))"
else
  crit "użytkownik $(id -un) ≠ ${AGENT_USER} (launchery odmówią pracy)"
fi

# --- 2. drzewo i uprawnienia ---------------------------------------------------
if [ -f "$WORK6/.work6-root" ]; then
  pass "środowisko: $WORK6"
else
  crit "brak $WORK6/.work6-root — uruchom setup-work6.sh"
fi
if [ -d "$WORK6" ]; then
  [ "$(stat -c %u -- "$WORK6")" = "$(id -u)" ] \
    && pass "właściciel work6: $(id -un)" \
    || crit "work6 nie należy do $(id -un)"
  [ "$(stat -c %a -- "$WORK6")" = "700" ] \
    && pass "tryb work6: 0700" \
    || warns "tryb work6 to $(stat -c %a -- "$WORK6"), oczekiwane 0700 (chmod 0700 '$WORK6')"
  for d in home config browser-profile backups state; do
    [ -d "$WORK6/$d" ] || { warns "brak katalogu $WORK6/$d"; continue; }
    [ "$(stat -c %a -- "$WORK6/$d")" = "700" ] \
      || warns "tryb $d: $(stat -c %a -- "$WORK6/$d") (oczekiwane 0700)"
  done
  for f in "$CONFIG_FILE" "$VERSIONS_FILE"; do
    [ -f "$f" ] || continue
    [ "$(stat -c %a -- "$f")" = "600" ] \
      || warns "tryb $(basename "$f"): $(stat -c %a -- "$f") (oczekiwane 0600)"
  done
fi

# --- 3. komponenty -------------------------------------------------------------
if is_yes "$INSTALL_NODE"; then
  if [ -x "$WORK6/node/current/bin/node" ]; then
    pass "node: $("$WORK6/node/current/bin/node" --version)"
    npm_prefix="$(NPM_CONFIG_USERCONFIG="$WORK6/config/npmrc" \
      "$WORK6/node/current/bin/npm" config get prefix 2>/dev/null || true)"
    [ "$npm_prefix" = "$WORK6/npm-global" ] \
      && pass "npm prefix: $npm_prefix" \
      || crit "npm prefix '$npm_prefix' ≠ $WORK6/npm-global (npmrc?)"
  else
    crit "brak lokalnego Node (setup-work6.sh --only node)"
  fi
fi
if is_yes "$INSTALL_PYTHON"; then
  [ -x "$WORK6/python/venv/bin/python" ] \
    && pass "python venv: $("$WORK6/python/venv/bin/python" --version 2>&1)" \
    || crit "brak venv (setup-work6.sh --only python)"
fi
if is_yes "$INSTALL_CLAUDE"; then
  cbin="$WORK6/tools/claude/current/claude"
  if [ -x "$cbin" ]; then
    cver="$(HOME="$WORK6/home" CLAUDE_CONFIG_DIR="$WORK6/home/.claude" \
      "$cbin" --version 2>/dev/null | head -n1 || true)"
    [ -n "$cver" ] && pass "claude: $cver" || crit "claude nie odpowiada na --version"
    grep -qs '"DISABLE_AUTOUPDATER"' "$WORK6/home/.claude/settings.json" \
      || warns "settings.json bez DISABLE_AUTOUPDATER — auto-update może się włączyć"
    [ -s "$WORK6/home/.claude/.credentials.json" ] \
      && pass "claude: poświadczenia obecne" \
      || info "claude: brak logowania (pierwsze uruchomienie: run-claude → /login)"
  else
    crit "brak binarki Claude (setup-work6.sh --only claude)"
  fi
fi
if is_yes "$INSTALL_AGY"; then
  abin="$WORK6/tools/agy/current/agy"
  if [ -x "$abin" ]; then
    aver="$(timeout 15 env HOME="$WORK6/home" "$abin" --version 2>/dev/null \
      | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    arec="$(read_kv "$VERSIONS_FILE" AGY_VERSION)"
    if [ -n "$aver" ]; then
      pass "agy: $aver"
      [ -n "$arec" ] && [ "$aver" != "$arec" ] \
        && warns "agy self-update: działa $aver, zapisano $arec (odśwież: update-tools.sh agy)"
    else
      warns "agy nie odpowiada na --version (sprawdź ręcznie: run-agy)"
    fi
  else
    crit "brak binarki agy (setup-work6.sh --only agy)"
  fi
fi
if is_yes "$INSTALL_PLAYWRIGHT"; then
  if [ -x "$WORK6/npm-global/bin/playwright" ]; then
    pass "playwright: $("$WORK6/npm-global/bin/playwright" --version 2>/dev/null || echo '?')"
    for e in $PLAYWRIGHT_ENGINES; do
      case "$e" in
        chromium) pat="chromium-*" ;;
        firefox)  pat="firefox-*" ;;
        webkit)   pat="webkit-*" ;;
        *) continue ;;
      esac
      if compgen -G "$WORK6/browsers/$pat" >/dev/null; then
        pass "przeglądarka $e: jest w work6/browsers"
      else
        crit "brak przeglądarki $e w $WORK6/browsers (setup-work6.sh --only playwright)"
      fi
    done
  else
    crit "brak playwright (setup-work6.sh --only playwright)"
  fi
fi
if is_yes "$INSTALL_FLUTTER"; then
  fbin="$WORK6/tools/flutter/flutter/bin/flutter"
  if [ -x "$fbin" ]; then
    if [ "$QUICK" -eq 1 ]; then
      pass "flutter: binarka jest (wersja: $(read_kv "$VERSIONS_FILE" FLUTTER_VERSION))"
    else
      fver="$("$fbin" --version 2>/dev/null | head -n1 || true)"
      [ -n "$fver" ] && pass "flutter: $fver" || warns "flutter nie odpowiada"
    fi
  else
    crit "brak Fluttera (setup-work6.sh --only flutter)"
  fi
fi
if is_yes "$INSTALL_VSCODE"; then
  case "${VSCODE_FLAVOR:-vscodium}" in
    vscodium) vbin="$WORK6/tools/vscode/current/bin/codium" ;;
    *)        vbin="$WORK6/tools/vscode/current/bin/code" ;;
  esac
  if [ -x "$vbin" ]; then
    pass "vscode (${VSCODE_FLAVOR}): $(read_kv "$VERSIONS_FILE" VSCODE_VERSION)"
    [ -L "$WORK6/tools/vscode/current/data" ] \
      || warns "brak symlinku 'data' (Portable Mode) w katalogu aplikacji"
  else
    crit "brak edytora (setup-work6.sh --only vscode)"
  fi
fi

# --- 4. sandbox ----------------------------------------------------------------
if ! have_cmd bwrap; then
  crit "brak bwrap — administrator: prepare-system.sh (pakiet bubblewrap)"
else
  ensure_dir "$WORK6/projects" 0700
  if sandbox_try net "$WORK6/projects" -- /bin/true 2>/dev/null; then
    pass "sandbox: uruchamia się (sieć współdzielona)"
  else
    crit "sandbox nie startuje! Debian 13: restrykcja userns/AppArmor — administrator: apt install --reinstall bubblewrap; szczegóły w README"
  fi
  if sandbox_try no-net "$WORK6/projects" -- /bin/true 2>/dev/null; then
    pass "sandbox offline (--unshare-net): działa"
  else
    warns "sandbox offline nie startuje"
  fi

  # test szczelności — asercje WEWNĄTRZ sandboxa
  leak_script='
    set -e
    [ -z "${SSH_AUTH_SOCK:-}" ] || { echo "SSH_AUTH_SOCK przecieka"; exit 1; }
    [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] || { echo "DBUS przecieka"; exit 1; }
    [ -z "${GPG_AGENT_INFO:-}" ] || { echo "GPG_AGENT_INFO przecieka"; exit 1; }
    [ ! -e /var/run/docker.sock ] || { echo "docker.sock widoczny"; exit 1; }
    [ ! -e /run/docker.sock ] || { echo "docker.sock widoczny"; exit 1; }
    [ ! -e /root ] || { echo "/root widoczny"; exit 1; }
    n=0
    for d in /home/*; do [ -e "$d" ] && n=$((n+1)); done
    [ "$n" -le 1 ] || { echo "w /home widać cudze katalogi"; exit 1; }
    for e in /home/*/*; do
      case "$e" in */work6) : ;; *) [ -e "$e" ] && { echo "w HOME agenta widać: $e"; exit 1; } ;; esac
    done
    for u in /run/user/*; do
      [ "$u" = "/run/user/$(id -u)" ] || { echo "obcy /run/user: $u"; exit 1; }
    done
    [ "$HOME" = "$WORK6/home" ] || { echo "HOME=$HOME ≠ work6/home"; exit 1; }
    [ "$PLAYWRIGHT_BROWSERS_PATH" = "$WORK6/browsers" ] || { echo "zły PLAYWRIGHT_BROWSERS_PATH"; exit 1; }
    [ "$TMPDIR" = "$WORK6/tmp" ] || { echo "zły TMPDIR"; exit 1; }
    [ -w /workspace ] || { echo "/workspace niezapisywalny"; exit 1; }
    [ ! -w /usr ] || { echo "/usr zapisywalny!"; exit 1; }
    echo OK
  '
  if out="$(sandbox_try net "$WORK6/projects" -- /bin/bash -c "$leak_script" 2>&1)" \
     && [ "${out##*$'\n'}" = "OK" ]; then
    pass "test szczelności sandboxa: OK"
  else
    crit "test szczelności sandboxa NIE przeszedł: ${out}"
  fi
fi
is_yes "${SANDBOX_ALLOW_DISPLAY:-no}" \
  && warns "SANDBOX_ALLOW_DISPLAY=yes — sockety sesji graficznej są przekazywane do sandboxa"
[ -n "${SANDBOX_EXTRA_RO_BINDS:-}" ] \
  && warns "SANDBOX_EXTRA_RO_BINDS niepuste: ${SANDBOX_EXTRA_RO_BINDS}"

# --- 5. dysk ---------------------------------------------------------------------
avail_mb="$(df -Pk "$WORK6" | awk 'NR==2{print int($4/1024)}')"
if [ "$avail_mb" -lt 1024 ]; then
  crit "wolne miejsce: ${avail_mb} MB (<1 GB!)"
elif [ "$avail_mb" -lt 5120 ]; then
  warns "wolne miejsce: ${avail_mb} MB (<5 GB)"
else
  pass "wolne miejsce: ${avail_mb} MB"
fi

# --- podsumowanie ------------------------------------------------------------------
echo
if [ "$CRIT" -gt 0 ]; then
  error "doctor: ${CRIT} problem(y) krytyczne, ${WARNS} ostrzeżeń"
  exit 1
fi
ok "doctor: bez problemów krytycznych (ostrzeżeń: ${WARNS})"
