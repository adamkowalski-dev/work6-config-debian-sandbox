# shellcheck shell=bash
# ============================================================================
# Moduł: Playwright — pakiet npm w work6/npm-global, przeglądarki
# WYŁĄCZNIE w work6/browsers (PLAYWRIGHT_BROWSERS_PATH).
#
# Zależności systemowe przeglądarek wymagają roota — ten moduł ich NIE
# instaluje: generuje listę pakietów (install-deps --dry-run) do
# state/admin-todo.pkgs, którą administrator przegląda i instaluje
# przez prepare-system.sh --stage2. Root nigdy nie wykonuje wprost
# niczego wygenerowanego na koncie agenta.
# ============================================================================

MODULE_LIST+=("playwright")

playwright_enabled() { is_yes "$INSTALL_PLAYWRIGHT"; }

_pw_bin() { printf '%s' "$WORK6/npm-global/bin/playwright"; }
_pw_npm() { printf '%s' "$WORK6/node/current/bin/npm"; }

playwright_installed_version() {
  [ -x "$(_pw_bin)" ] || return 0
  "$(_pw_bin)" --version 2>/dev/null | awk '{print $2}' || true
}

playwright_remote_version() {
  [ -x "$(_pw_npm)" ] || return 0
  "$(_pw_npm)" view playwright version 2>/dev/null || true
}

_pw_engines() {
  local e
  local -a valid=()
  for e in ${PLAYWRIGHT_ENGINES:-chromium}; do
    case "$e" in
      chromium|firefox|webkit) valid+=("$e") ;;
      *) warn "Playwright: pomijam nieznany silnik '$e'" ;;
    esac
  done
  [ "${#valid[@]}" -gt 0 ] || die "Playwright: pusta lista silników"
  printf '%s\n' "${valid[@]}"
}

playwright_install() {
  local action="$1" resolved engines=() deps_raw deps_line pkgs tok
  [ -x "$(_pw_npm)" ] || die "Playwright wymaga lokalnego Node (włącz moduł node)"
  # npm i playwright to skrypty `#!/usr/bin/env node` — świeżo
  # zainstalowany Node mógł nie być na PATH przy starcie skryptu.
  case ":$PATH:" in
    *":$WORK6/node/current/bin:"*) : ;;
    *) export PATH="$WORK6/node/current/bin:$PATH" ;;
  esac

  info "instaluję pakiet npm playwright (prefix: $WORK6/npm-global)"
  "$(_pw_npm)" install -g "playwright@latest"
  resolved="$(playwright_installed_version)"
  [ -n "$resolved" ] || die "Playwright: instalacja npm nie powiodła się"
  ok "playwright ${resolved}"

  mapfile -t engines < <(_pw_engines)
  info "instaluję przeglądarki (${engines[*]}) do $PLAYWRIGHT_BROWSERS_PATH"
  "$(_pw_bin)" install "${engines[@]}"

  # Lista zależności systemowych dla administratora (dane wyjściowe
  # dry-run traktujemy jako niezaufane — stage2 filtruje nazwy pakietów).
  deps_raw="$WORK6/state/playwright-deps-raw.txt"
  if "$(_pw_bin)" install-deps --dry-run "${engines[@]}" >"$deps_raw" 2>&1; then
    chmod 0600 "$deps_raw"
    deps_line="$(grep -o -- '--no-install-recommends[^"]*' "$deps_raw" | head -n1 || true)"
    deps_line="${deps_line#--no-install-recommends}"
    pkgs=""
    for tok in $deps_line; do
      [[ "$tok" =~ ^[a-z0-9][a-z0-9+.-]*$ ]] && pkgs="$pkgs $tok"
    done
    if [ -n "${pkgs// /}" ]; then
      {
        echo "# playwright ${resolved} (${engines[*]}) — $(timestamp)"
        echo "${pkgs# }"
      } >>"$ADMIN_TODO"
      chmod 0600 "$ADMIN_TODO"
      warn "zależności systemowe przeglądarek zgłoszone do: $ADMIN_TODO"
      warn "administrator: sudo .../prepare-system.sh --stage2"
    else
      warn "nie udało się sparsować listy zależności — surowy zrzut w $deps_raw"
    fi
  else
    warn "playwright install-deps --dry-run nie zadziałał (zrzut: $deps_raw)."
    warn "Zależności ustalisz później: doctor.sh wykryje brakujące biblioteki."
  fi

  record_component playwright "$resolved" "registry.npmjs.org/playwright" "-" "$action"
  info "przeglądarki headed w sandboxie: patrz README (sekcja GUI); w razie"
  info "blokady wewnętrznego sandboxa Chromium użyj chromiumSandbox:false w projekcie"
}
