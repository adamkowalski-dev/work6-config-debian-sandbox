# shellcheck shell=bash
# ============================================================================
# Moduł: VS Code / VSCodium w trybie PORTABLE — aplikacja i wszystkie jej
# dane (ustawienia, rozszerzenia, cache) w work6/tools/vscode.
#   * VSCodium (rekomendowany): GitHub Releases publikuje pliki .sha256,
#   * VS Code (MS): oficjalny tarball BEZ publikowanych sum — hash
#     liczymy i zapisujemy sami (tylko rejestr, nie weryfikacja źródła),
#   * katalog `data` (Portable Mode) jest symlinkiem do wspólnego
#     work6/tools/vscode/data — przeżywa aktualizacje aplikacji,
#   * rozszerzenia: wyłącznie te z install.env, po potwierdzeniu.
# ============================================================================

MODULE_LIST+=("vscode")

vscode_enabled() { is_yes "$INSTALL_VSCODE"; }

_vscode_arch() {
  case "$(uname -m)" in
    x86_64)  echo "x64" ;;
    aarch64) echo "arm64" ;;
    *) die "VS Code: nieobsługiwana architektura $(uname -m)" ;;
  esac
}

_vscode_bin() {
  case "${VSCODE_FLAVOR:-vscodium}" in
    vscodium) printf '%s' "$WORK6/tools/vscode/current/bin/codium" ;;
    vscode)   printf '%s' "$WORK6/tools/vscode/current/bin/code" ;;
  esac
}

vscode_installed_version() {
  local pkg="$WORK6/tools/vscode/current/resources/app/package.json"
  [ -f "$pkg" ] || return 0
  jq -r '.version // empty' "$pkg" 2>/dev/null || true
}

vscode_remote_version() {
  case "${VSCODE_FLAVOR:-vscodium}" in
    vscodium)
      download_stdout "https://api.github.com/repos/VSCodium/vscodium/releases/latest" \
        | jq -r '.tag_name // empty'
      ;;
    vscode) echo "latest" ;;
  esac
}

_vscode_link_data() {
  local appdir="$1"
  ensure_dir "$WORK6/tools/vscode/data" 0700
  # Portable Mode: katalog `data` obok binarki; symlink względny, żeby
  # dane przeżyły wymianę wersji aplikacji.
  ln -sfn ../data "$appdir/data"
}

_vscode_install_vscodium() {
  local action="$1" rel tag arch asset sha_url tar_url tarball appdir
  need_cmd jq "apt install jq"
  arch="$(_vscode_arch)"
  rel="$(download_stdout "https://api.github.com/repos/VSCodium/vscodium/releases/latest")"
  tag="$(printf '%s' "$rel" | jq -r '.tag_name // empty')"
  [ -n "$tag" ] || die "VSCodium: nie mogę odczytać najnowszego release'u"
  asset="VSCodium-linux-${arch}-${tag}.tar.gz"
  tar_url="$(printf '%s' "$rel" | jq -r --arg n "$asset" \
    '.assets[] | select(.name == $n) | .browser_download_url')"
  sha_url="$(printf '%s' "$rel" | jq -r --arg n "$asset.sha256" \
    '.assets[] | select(.name == $n) | .browser_download_url')"
  [ -n "$tar_url" ] && [ -n "$sha_url" ] \
    || die "VSCodium: brak assetu ${asset} (+.sha256) w release ${tag}"

  tarball="$DL_DIR/$asset"
  download "$tar_url" "$tarball"
  download "$sha_url" "$tarball.sha256"
  ( cd "$DL_DIR" && sha256sum -c "$asset.sha256" ) \
    || { rm -f -- "$tarball"; die "VSCodium: suma SHA-256 się nie zgadza"; }
  ok "SHA-256 OK: $asset"
  local hash
  hash="$(awk '{print $1; exit}' "$tarball.sha256")"

  appdir="$WORK6/tools/vscode/app-${tag}"
  rm -rf -- "$appdir"
  ensure_dir "$appdir" 0700
  tar -xzf "$tarball" -C "$appdir"
  rm -f -- "$tarball" "$tarball.sha256"
  _vscode_link_data "$appdir"
  ln -sfn -- "$appdir" "$WORK6/tools/vscode/current"
  record_component vscode "$tag" "$tar_url" "$hash" "$action"
  record_kv "$VERSIONS_FILE" VSCODE_FLAVOR "vscodium"
  ok "VSCodium ${tag} (portable) zainstalowany"
}

_vscode_install_ms() {
  local action="$1" arch url tarball tmpd appdir ver hash
  arch="$(_vscode_arch)"
  url="https://update.code.visualstudio.com/latest/linux-${arch}/stable"
  tarball="$DL_DIR/vscode-linux-${arch}.tar.gz"
  warn "VS Code (MS) nie publikuje sum kontrolnych tarballa — zapisuję hash informacyjnie"
  download "$url" "$tarball"
  hash="$(sha256sum "$tarball" | cut -d' ' -f1)"

  tmpd="$(mktemp -d "$WORK6/tmp/vscode.XXXXXX")"
  tar -xzf "$tarball" -C "$tmpd"
  rm -f -- "$tarball"
  [ -d "$tmpd"/VSCode-linux-* ] || die "VS Code: nieoczekiwana zawartość tarballa"
  ver="$(jq -r '.version // empty' "$tmpd"/VSCode-linux-*/resources/app/package.json)"
  appdir="$WORK6/tools/vscode/app-${ver:-unknown}"
  rm -rf -- "$appdir"
  mv -- "$tmpd"/VSCode-linux-* "$appdir"
  rm -rf -- "$tmpd"
  _vscode_link_data "$appdir"
  ln -sfn -- "$appdir" "$WORK6/tools/vscode/current"
  record_component vscode "${ver:-unknown}" "$url" "$hash" "$action"
  record_kv "$VERSIONS_FILE" VSCODE_FLAVOR "vscode"
  ok "VS Code ${ver} (portable) zainstalowany"
}

_vscode_install_extensions() {
  local bin ext
  [ -n "${VSCODE_EXTENSIONS:-}" ] || return 0
  bin="$(_vscode_bin)"
  [ -x "$bin" ] || return 0
  info "rozszerzenia do instalacji: ${VSCODE_EXTENSIONS}"
  confirm "Zainstalować powyższe rozszerzenia?" tak || return 0
  for ext in $VSCODE_EXTENSIONS; do
    # --install-extension działa headless; dane lądują w portable data/.
    if "$bin" --install-extension "$ext" >/dev/null 2>&1; then
      ok "rozszerzenie: $ext"
    else
      warn "nie udało się zainstalować rozszerzenia: $ext (VSCodium używa open-vsx — nie wszystko tam jest)"
    fi
  done
}

vscode_install() {
  local action="$1"
  case "${VSCODE_FLAVOR:-vscodium}" in
    vscodium) _vscode_install_vscodium "$action" ;;
    vscode)   _vscode_install_ms "$action" ;;
    *) die "VSCODE_FLAVOR musi być 'vscodium' albo 'vscode'" ;;
  esac
  _vscode_install_extensions
}
