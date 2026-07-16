# shellcheck shell=bash
# ============================================================================
# Moduł: Python — lokalny venv w work6/python/venv, pip cache w work6.
# Interpreter bazowy jest systemowy (apt: python3, python3-venv), ale
# żaden pakiet nie jest instalowany globalnie.
# ============================================================================

MODULE_LIST+=("python")

python_enabled() { is_yes "$INSTALL_PYTHON"; }

python_installed_version() {
  [ -x "$WORK6/python/venv/bin/python" ] || return 0
  "$WORK6/python/venv/bin/python" --version 2>/dev/null | awk '{print $2}' || true
}

python_remote_version() {
  # venv bazuje na systemowym interpreterze — "dostępna" wersja to on.
  command -v python3 >/dev/null 2>&1 || return 0
  python3 --version 2>/dev/null | awk '{print $2}' || true
}

python_install() {
  local action="$1" venv="$WORK6/python/venv"
  need_cmd python3 "apt install python3 python3-venv (przez prepare-system.sh)"
  python3 -m venv --help >/dev/null 2>&1 \
    || die "python3 -m venv nie działa — doinstaluj python3-venv (prepare-system.sh)"

  if [ "$action" = "repair" ] && [ -d "$venv" ]; then
    warn "naprawa: usuwam istniejący venv (${venv})"
    rm -rf -- "$venv"
  fi
  if [ ! -x "$venv/bin/python" ]; then
    info "tworzę venv: $venv"
    python3 -m venv "$venv"
  fi
  # PIP_CACHE_DIR jest w środowisku work6; upewniamy się mimo to.
  PIP_CACHE_DIR="$WORK6/cache/pip" "$venv/bin/pip" install --upgrade pip wheel
  ok "Python venv: $("$venv/bin/python" --version 2>&1)"
  record_component python "$(python_installed_version)" "system python3 + venv" "-" "$action"
}
