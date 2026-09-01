# shellcheck shell=bash
# ============================================================================
# Moduł: Node.js LTS — lokalny runtime w work6/node (bez systemowego Node)
# Weryfikacja: SHASUMS256.txt z oficjalnego manifestu nodejs.org.
# UWAGA: to weryfikacja INTEGRALNOŚCI transferu, nie AUTENTYCZNOŚCI źródła
# — suma i tarball pochodzą z tego samego hosta (nodejs.org), a podpis
# SHASUMS256.txt.sig NIE jest weryfikowany (inaczej niż w module Claude).
# Kompromitacja hosta/CDN unieważnia tę kontrolę. Świadomy kompromis.
# ============================================================================

MODULE_LIST+=("node")

node_enabled() { is_yes "$INSTALL_NODE"; }

node_arch() {
  case "$(uname -m)" in
    x86_64)  echo "x64" ;;
    aarch64) echo "arm64" ;;
    *) die "Node: nieobsługiwana architektura $(uname -m)" ;;
  esac
}

node_installed_version() {
  [ -x "$WORK6/node/current/bin/node" ] || return 0
  "$WORK6/node/current/bin/node" --version 2>/dev/null || true
}

# Najnowsza wersja zgodna z polityką (pinned do NODE_MAJOR_PIN / follow-lts).
node_remote_version() {
  need_cmd jq "apt install jq"
  local idx
  idx="$(download_stdout "https://nodejs.org/dist/index.json")"
  if [ "${NODE_POLICY:-pinned}" = "follow-lts" ]; then
    printf '%s' "$idx" | jq -r '[.[] | select(.lts != false)][0].version // empty'
  else
    printf '%s' "$idx" | jq -r --arg p "v${NODE_MAJOR_PIN:-24}." \
      '[.[] | select(.lts != false) | select(.version | startswith($p))][0].version // empty'
  fi
}

node_install() {
  local action="$1" ver arch tarball url sums_file want dir old
  ver="$(node_remote_version)"
  [ -n "$ver" ] || die "Node: nie mogę ustalić wersji (polityka: ${NODE_POLICY}, pin: ${NODE_MAJOR_PIN})"
  arch="$(node_arch)"
  tarball="node-${ver}-linux-${arch}.tar.xz"
  url="https://nodejs.org/dist/${ver}/${tarball}"
  sums_file="$DL_DIR/SHASUMS256-${ver}.txt"

  info "Node ${ver} (${NODE_POLICY:-pinned}) — pobieram i weryfikuję"
  download "https://nodejs.org/dist/${ver}/SHASUMS256.txt" "$sums_file"
  download "$url" "$DL_DIR/$tarball"
  want="$(awk -v f="$tarball" '$2 == f {print $1}' "$sums_file")"
  [ -n "$want" ] || die "Node: brak ${tarball} w SHASUMS256.txt"
  sha256_verify "$DL_DIR/$tarball" "$want"

  dir="$WORK6/node/node-${ver}-linux-${arch}"
  rm -rf -- "$dir"
  tar -xJf "$DL_DIR/$tarball" -C "$WORK6/node"
  [ -x "$dir/bin/node" ] || die "Node: rozpakowanie nie powiodło się"
  ln -sfn -- "$dir" "$WORK6/node/current"
  ok "Node $("$WORK6/node/current/bin/node" --version) aktywny"

  # npm: prefix/cache wyłącznie w work6 (plik czytany też przez narzędzia,
  # które ignorują zmienne środowiskowe).
  cat >"$WORK6/config/npmrc" <<EOF
prefix=$WORK6/npm-global
cache=$WORK6/cache/npm
update-notifier=false
fund=false
EOF
  chmod 0600 "$WORK6/config/npmrc"

  rm -f -- "$DL_DIR/$tarball"
  record_component node "$ver" "$url" "$want" "$action"

  # sprzątanie starych wersji — tylko za zgodą
  for old in "$WORK6/node"/node-v*; do
    [ -d "$old" ] || continue
    [ "$old" = "$dir" ] && continue
    if confirm "Usunąć starą wersję Node: $(basename "$old")?" tak; then
      rm -rf -- "$old"
    fi
  done
}
