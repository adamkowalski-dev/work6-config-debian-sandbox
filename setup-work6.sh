#!/usr/bin/env bash
# ============================================================================
# work6 — setup-work6.sh — główny instalator środowiska agentowego
#
# Uruchamiany WYŁĄCZNIE jako użytkownik agenta (bez sudo):
#     sudo -iu ai-agent
#     cd ~/work6-config && ./setup-work6.sh
#
# Co robi:
#   1. kreator (pierwsze uruchomienie): pyta o komponenty i tryby,
#      zapisuje wybory do <work6>/config/install.env,
#   2. preflight: sprawdza narzędzia systemowe i miejsce na dysku —
#      na czystym Debianie wypisze dokładnie, co ma doinstalować
#      administrator (prepare-system.sh),
#   3. instaluje wybrane komponenty modułami z setup.d/ (idempotentnie;
#      przy ponownym uruchomieniu: zachowaj/zaktualizuj/napraw/pomiń),
#   4. kopiuje launchery i skrypty do <work6>, ustawia uprawnienia.
#
# Flagi:
#   --reconfigure   ponownie uruchom kreator
#   --yes           bez pytań (wymaga wcześniej zapisanej konfiguracji)
#   --only NAZWA    tylko jeden moduł (node|python|claude|agy|playwright|
#                   flutter|vscode)
# ============================================================================
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$ROOT_DIR/lib/common.sh"
common_init

RECONFIGURE=0
ONLY_MODULE=""
export ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --reconfigure) RECONFIGURE=1 ;;
    --yes) export ASSUME_YES=1 ;;
    --only) ONLY_MODULE="${2:?--only wymaga nazwy modułu}"; shift ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "nieznany argument: $1 (użyj --help)" ;;
  esac
  shift
done

require_agent_user

# ----------------------------------------------------------------------------
# Kreator konfiguracji
# ----------------------------------------------------------------------------
write_install_env() {
  local f="$CONFIG_FILE" tmp
  tmp="$(mktemp "$WORK6/tmp/install.env.XXXXXX")"
  cat >"$tmp" <<EOF
# shellcheck shell=bash
# work6 — konfiguracja zapisana przez kreator $(timestamp)
# (opisy pól: config/install.env w katalogu instalacyjnym)
AGENT_USER="$AGENT_USER"
WORK6_DIR="$WORK6_DIR"
INSTALL_NODE="$INSTALL_NODE"
NODE_POLICY="$NODE_POLICY"
NODE_MAJOR_PIN="$NODE_MAJOR_PIN"
INSTALL_PYTHON="$INSTALL_PYTHON"
INSTALL_CLAUDE="$INSTALL_CLAUDE"
CLAUDE_CHANNEL="$CLAUDE_CHANNEL"
CLAUDE_MAX_MODE="$CLAUDE_MAX_MODE"
INSTALL_AGY="$INSTALL_AGY"
AGY_MAX_MODE="$AGY_MAX_MODE"
INSTALL_PLAYWRIGHT="$INSTALL_PLAYWRIGHT"
PLAYWRIGHT_ENGINES="$PLAYWRIGHT_ENGINES"
INSTALL_FLUTTER="$INSTALL_FLUTTER"
FLUTTER_CHANNEL="$FLUTTER_CHANNEL"
FLUTTER_TARGETS="$FLUTTER_TARGETS"
INSTALL_VSCODE="$INSTALL_VSCODE"
VSCODE_FLAVOR="$VSCODE_FLAVOR"
VSCODE_EXTENSIONS="$VSCODE_EXTENSIONS"
OAUTH_MODE="$OAUTH_MODE"
WANT_SYSTEM_CHROMIUM="$WANT_SYSTEM_CHROMIUM"
BACKUP_KEEP="$BACKUP_KEEP"
WIZARD_DONE="yes"
EOF
  chmod 0600 "$tmp"
  mv -- "$tmp" "$f"
  ok "konfiguracja zapisana: $f"
}

ask_component() { # ask_component ZMIENNA "opis"
  local -n _v="$1"
  local desc="$2" def
  is_yes "$_v" && def=tak || def=nie
  if confirm "Zainstalować: ${desc}?" "$def"; then _v="yes"; else _v="no"; fi
}

wizard() {
  echo
  info "=== Kreator work6 — odpowiedz na pytania (Enter = wartość domyślna) ==="
  echo

  ask_component INSTALL_NODE "lokalny Node.js LTS (wymagany dla Playwright/npm)"
  if is_yes "$INSTALL_NODE"; then
    choose NODE_POLICY \
      "Polityka wersji Node ('pinned' = trzymaj linię ${NODE_MAJOR_PIN}.x; 'follow-lts' = zawsze najnowsza linia LTS — uwaga, w 10.2026 LTS zmienia się na 26)" \
      "$NODE_POLICY" pinned follow-lts
    if [ "$NODE_POLICY" = "pinned" ]; then
      local ans
      read -r -p "Linia major do przypięcia [${NODE_MAJOR_PIN}]: " ans </dev/tty || true
      if [ -n "$ans" ]; then
        [[ "$ans" =~ ^[0-9]+$ ]] || die "major musi być liczbą"
        NODE_MAJOR_PIN="$ans"
      fi
    fi
  fi

  ask_component INSTALL_PYTHON "Python + lokalny venv"
  ask_component INSTALL_CLAUDE "Claude Code CLI (natywna binarka, weryfikacja GPG)"
  if is_yes "$INSTALL_CLAUDE"; then
    choose CLAUDE_CHANNEL "Kanał wersji Claude Code" "$CLAUDE_CHANNEL" stable latest
    echo
    info "Tryb autonomii launchera run-claude (zawsze WEWNĄTRZ sandboxa bwrap):"
    info "  default     — Claude pyta o każdą edycję i komendę"
    info "  acceptEdits — edycje plików auto-akceptowane, komendy pytają"
    info "  bypass      — --dangerously-skip-permissions: pełna autonomia,"
    info "                zapis możliwy tylko w katalogach work6 widocznych w sandboxie"
    choose CLAUDE_MAX_MODE "Maksymalny (i domyślny) tryb autonomii" \
      "$CLAUDE_MAX_MODE" default acceptEdits bypass
  fi

  ask_component INSTALL_AGY "Antigravity CLI (agy)"
  if is_yes "$INSTALL_AGY"; then
    info "Tryb autonomii launchera run-agy (zawsze WEWNĄTRZ sandboxa bwrap):"
    info "  default — agy pyta o każde działanie"
    info "  bypass  — --dangerously-skip-permissions: pełna autonomia,"
    info "            zapis możliwy tylko w katalogach work6 widocznych w sandboxie"
    choose AGY_MAX_MODE "Maksymalny (i domyślny) tryb autonomii agy" \
      "${AGY_MAX_MODE:-bypass}" default bypass
  fi

  ask_component INSTALL_PLAYWRIGHT "Playwright (przeglądarki w work6/browsers)"
  if is_yes "$INSTALL_PLAYWRIGHT"; then
    choose PLAYWRIGHT_ENGINES "Silniki przeglądarek (każdy to setki MB)" \
      "$PLAYWRIGHT_ENGINES" \
      "chromium" "chromium firefox" "chromium webkit" "chromium firefox webkit"
  fi

  ask_component INSTALL_FLUTTER "Flutter SDK (~3-4.5 GB)"
  if is_yes "$INSTALL_FLUTTER"; then
    choose FLUTTER_CHANNEL "Kanał Fluttera" "$FLUTTER_CHANNEL" stable beta
    choose FLUTTER_TARGETS "Platformy docelowe (android = tylko wykrycie istniejącego SDK)" \
      "$FLUTTER_TARGETS" "linux web" "linux" "web" "linux web android"
  fi

  ask_component INSTALL_VSCODE "VS Code / VSCodium (portable)"
  if is_yes "$INSTALL_VSCODE"; then
    choose VSCODE_FLAVOR \
      "Edytor ('vscodium' publikuje sumy SHA-256 i nie ma telemetrii MS; 'vscode' = oficjalny, bez publikowanych sum)" \
      "$VSCODE_FLAVOR" vscodium vscode
    local ans tok bad=0
    echo "Rozszerzenia (ID rozdzielone spacjami), np.: ms-python.python dart-code.flutter eamodio.gitlens"
    read -r -p "Lista [${VSCODE_EXTENSIONS:-brak}]: " ans </dev/tty || true
    if [ -n "$ans" ]; then
      for tok in $ans; do
        [[ "$tok" =~ ^[A-Za-z0-9-]+\.[A-Za-z0-9-]+$ ]] || { warn "niepoprawne ID: $tok"; bad=1; }
      done
      [ "$bad" -eq 0 ] && VSCODE_EXTENSIONS="$ans" || warn "zostawiam poprzednią listę"
    fi
  fi

  echo
  info "Jak będziesz logować się do kont (OAuth) i używać GUI?"
  info "  desktop-session — mam osobną sesję pulpitu jako ${AGENT_USER}"
  info "  headless-remote — bez GUI; URL-e loginów otwieram na innym urządzeniu"
  info "  shared-gui      — GUI tylko administratora; loguję jak headless-remote"
  choose OAUTH_MODE "Wariant OAuth/GUI" "$OAUTH_MODE" \
    desktop-session headless-remote shared-gui
  ask_component WANT_SYSTEM_CHROMIUM "systemowy Chromium do OAuth (instaluje administrator; przy 'no' użyję Chromium Playwrighta)"

  echo
  info "=== Podsumowanie wyborów ==="
  local v
  for v in INSTALL_NODE NODE_POLICY NODE_MAJOR_PIN INSTALL_PYTHON \
           INSTALL_CLAUDE CLAUDE_CHANNEL CLAUDE_MAX_MODE INSTALL_AGY \
           AGY_MAX_MODE INSTALL_PLAYWRIGHT PLAYWRIGHT_ENGINES INSTALL_FLUTTER \
           FLUTTER_CHANNEL FLUTTER_TARGETS INSTALL_VSCODE VSCODE_FLAVOR \
           VSCODE_EXTENSIONS OAUTH_MODE WANT_SYSTEM_CHROMIUM; do
    printf '  %-22s %s\n' "$v" "${!v}"
  done
  echo
  confirm "Zapisać konfigurację i kontynuować instalację?" tak \
    || die "przerwano — nic nie zapisano"
  write_install_env
  # shellcheck source=/dev/null
  . "$CONFIG_FILE"
}

# ----------------------------------------------------------------------------
# Preflight — od zera do działającego środowiska: co musi być w systemie
# ----------------------------------------------------------------------------
preflight() {
  local -a missing=()
  local c
  for c in curl tar gzip jq git awk sha256sum sha512sum; do
    have_cmd "$c" || missing+=("$c")
  done
  have_cmd xz || missing+=("xz (pakiet xz-utils)")
  is_yes "$INSTALL_CLAUDE" && ! have_cmd gpg && missing+=("gpg (pakiet gnupg)")
  if is_yes "$INSTALL_PYTHON"; then
    have_cmd python3 || missing+=("python3 (+python3-venv)")
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    error "system nie jest gotowy — brakuje: ${missing[*]}"
    error "poproś administratora o uruchomienie:  sudo ./prepare-system.sh"
    exit 1
  fi
  ok "narzędzia systemowe: komplet"

  if ! have_cmd bwrap; then
    warn "brak bubblewrap — instalacja zadziała, ale ŻADEN launcher nie wystartuje."
    warn "Administrator: sudo ./prepare-system.sh (pakiet bubblewrap)"
    confirm "Kontynuować mimo braku bwrap?" tak || exit 1
  fi

  # szacunek miejsca (MB) wg wyborów
  local need=200 e
  is_yes "$INSTALL_NODE" && need=$((need + 250))
  is_yes "$INSTALL_PYTHON" && need=$((need + 100))
  is_yes "$INSTALL_CLAUDE" && need=$((need + 400))
  is_yes "$INSTALL_AGY" && need=$((need + 150))
  if is_yes "$INSTALL_PLAYWRIGHT"; then
    need=$((need + 300))
    for e in $PLAYWRIGHT_ENGINES; do
      case "$e" in
        chromium) need=$((need + 1100)) ;;
        firefox)  need=$((need + 500)) ;;
        webkit)   need=$((need + 600)) ;;
      esac
    done
  fi
  is_yes "$INSTALL_FLUTTER" && need=$((need + 4500))
  is_yes "$INSTALL_VSCODE" && need=$((need + 600))
  local avail_mb
  avail_mb="$(df -Pk "$WORK6" | awk 'NR==2{print int($4/1024)}')"
  info "szacowane zapotrzebowanie: ~${need} MB; wolne: ${avail_mb} MB"
  if [ "$avail_mb" -lt $((need + 1024)) ]; then
    warn "może zabraknąć miejsca na dysku!"
    confirm "Kontynuować mimo to?" nie || exit 1
  fi
}

# ----------------------------------------------------------------------------
# Synchronizacja plików środowiska (launchery, skrypty, biblioteki)
# ----------------------------------------------------------------------------
sync_files() {
  local d f base
  for d in bin scripts lib setup.d; do
    [ "$(readlink -f "$ROOT_DIR/$d")" = "$(readlink -f "$WORK6/$d")" ] && continue
    for f in "$ROOT_DIR/$d"/*; do
      [ -f "$f" ] || continue
      base="$(basename "$f")"
      case "$d" in
        bin|scripts) install -m 0700 -- "$f" "$WORK6/$d/$base" ;;
        *)           install -m 0600 -- "$f" "$WORK6/$d/$base" ;;
      esac
    done
  done
  if [ ! -f "$WORK6/config/sandbox.env" ] \
     && [ -f "$ROOT_DIR/config/sandbox.env" ]; then
    install -m 0600 -- "$ROOT_DIR/config/sandbox.env" "$WORK6/config/sandbox.env"
  fi
  touch -- "$VERSIONS_FILE"; chmod 0600 -- "$VERSIONS_FILE"
  touch -- "$MANIFEST_FILE"; chmod 0600 -- "$MANIFEST_FILE"

  # powłoka wewnątrz sandboxa (HOME=work6/home → czyta ten .bashrc)
  if ! grep -qs '^# work6-sandbox-rc' "$WORK6/home/.bashrc" 2>/dev/null; then
    cat >>"$WORK6/home/.bashrc" <<'EOF'
# work6-sandbox-rc — minimalna powłoka sandboxa (nie edytuj tej linii)
umask 077
PS1='[work6] \w \$ '
EOF
    chmod 0600 "$WORK6/home/.bashrc"
  fi
  ok "launchery i skrypty zsynchronizowane do $WORK6"
}

# ----------------------------------------------------------------------------
# Pętla modułów
# ----------------------------------------------------------------------------
declare -a MODULE_LIST=()

run_modules() {
  local f mod installed act
  for f in "$WORK6"/setup.d/[0-9][0-9]-*.sh; do
    # shellcheck source=/dev/null
    . "$f"
  done
  for mod in "${MODULE_LIST[@]}"; do
    if [ -n "$ONLY_MODULE" ] && [ "$mod" != "$ONLY_MODULE" ]; then
      continue
    fi
    if ! "${mod}_enabled"; then
      info "[$mod] wyłączony w konfiguracji — pomijam"
      continue
    fi
    echo
    installed="$("${mod}_installed_version" || true)"
    if [ -z "$installed" ]; then
      info "[$mod] brak instalacji — instaluję"
      "${mod}_install" fresh
    elif [ "$ASSUME_YES" = "1" ] && [ -z "$ONLY_MODULE" ]; then
      info "[$mod] już zainstalowany ($installed) — zostawiam (--yes)"
    else
      act=""
      choose act "[$mod] zainstalowany (wersja: $installed) — co zrobić?" \
        "zachowaj" zachowaj zaktualizuj napraw pomiń
      case "$act" in
        zachowaj|pomiń) info "[$mod] bez zmian" ;;
        zaktualizuj) "${mod}_install" update ;;
        napraw)      "${mod}_install" repair ;;
      esac
    fi
  done
}

# ----------------------------------------------------------------------------
# Podsumowanie
# ----------------------------------------------------------------------------
summary() {
  echo
  ok "=== setup-work6 zakończony ==="
  echo
  if [ -s "$ADMIN_TODO" ]; then
    warn "SĄ zależności systemowe do instalacji przez administratora:"
    sed 's/^/    /' "$ADMIN_TODO"
    warn "administrator:  sudo <katalog-instalacyjny>/prepare-system.sh --stage2"
    echo
  fi
  info "następne kroki (jako ${AGENT_USER}):"
  echo "  1. diagnostyka:        $WORK6/scripts/doctor.sh"
  echo "  2. shell w sandboxie:  $WORK6/bin/agent-shell"
  is_yes "$INSTALL_CLAUDE" && \
  echo "  3. logowanie Claude:   $WORK6/bin/run-claude   (w sesji: /login lub 'claude auth login')"
  is_yes "$INSTALL_AGY" && \
  echo "  4. logowanie agy:      $WORK6/bin/run-agy      (URL autoryzacji wg trybu: ${OAUTH_MODE})"
  case "$OAUTH_MODE" in
    desktop-session)
      echo "  OAuth: URL-e otwieraj w  $WORK6/bin/open-agent-browser  (osobna sesja ${AGENT_USER})" ;;
    *)
      echo "  OAuth: URL-e z CLI otwieraj w DEDYKOWANYM profilu przeglądarki na innym urządzeniu" ;;
  esac
  echo
  info "pełna instrukcja: README.md; diagnoza problemów: scripts/doctor.sh"
}

# ============================================================================
main() {
  ensure_tree
  log_init setup
  # Środowisko work6 dla wszystkich instalatorów: npm prefix/cache,
  # PLAYWRIGHT_BROWSERS_PATH, PIP_CACHE_DIR, PUB_CACHE itd. — bez tego
  # świeże instalacje trafiałyby do ~/.npm, ~/.cache (poza work6!).
  work6_export_env "$WORK6"
  info "work6: $WORK6 (użytkownik: $(id -un), $(id -u))"

  if [ "$WIZARD_DONE" != "yes" ] || [ "$RECONFIGURE" -eq 1 ]; then
    [ "$ASSUME_YES" = "1" ] \
      && die "--yes wymaga wcześniej zapisanej konfiguracji (uruchom raz interaktywnie)"
    wizard
  else
    info "konfiguracja: $CONFIG_FILE (kreator pominięty; wymuś przez --reconfigure)"
  fi

  preflight
  sync_files
  run_modules
  summary
}
main
