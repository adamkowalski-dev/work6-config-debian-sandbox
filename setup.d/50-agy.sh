# shellcheck shell=bash
# ============================================================================
# Moduł: Antigravity CLI (agy) — odtworzony mechanizm oficjalnego
# instalatora (bez `curl | bash`): manifest per platforma → SHA-512 →
# binarka/tar.gz. Manifest nie jest podpisany GPG (stan 2026-07) —
# integralność opiera się na sumie z manifestu po HTTPS.
#
# UWAGA (zweryfikowane w oficjalnym instalatorze): agy SELF-UPDATE'UJE
# się w tle podczas normalnych uruchomień. Pin wersji jest więc miękki;
# doctor.sh porównuje faktyczną wersję z zapisaną i raportuje dryf.
# ============================================================================

MODULE_LIST+=("agy")

AGY_MANIFEST_BASE="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app"

agy_enabled() { is_yes "$INSTALL_AGY"; }

agy_platform() {
  local arch
  case "$(uname -m)" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    *) die "agy: nieobsługiwana architektura $(uname -m)" ;;
  esac
  if ldd /bin/ls 2>&1 | grep -q musl; then
    echo "linux_${arch}_musl"
  else
    echo "linux_${arch}"
  fi
}

# Manifest pobieramy raz na przebieg.
_AGY_MANIFEST_JSON=""
_agy_manifest() {
  local out
  if [ -z "$_AGY_MANIFEST_JSON" ]; then
    if ! out="$(download_stdout "$AGY_MANIFEST_BASE/manifests/$(agy_platform).json" 2>&1)"; then
      error "agy: nie mogę pobrać manifestu release'ów: $out"
      return 1
    fi
    [ -n "$out" ] || { error "agy: pusty manifest release'ów"; return 1; }
    _AGY_MANIFEST_JSON="$out"
  fi
  printf '%s' "$_AGY_MANIFEST_JSON"
}

agy_installed_version() {
  local bin="$WORK6/tools/agy/current/agy"
  [ -x "$bin" ] || return 0
  # agy się self-update'uje — pytamy binarkę, nie versions.env.
  timeout 15 env HOME="$WORK6/home" "$bin" --version 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true
}

# Wersja zapisana przy ostatniej instalacji — agy self-update'uje się
# w tle, więc rozjazd z agy_installed_version jest normalny i raportowany.
agy_recorded_version() { read_kv "$VERSIONS_FILE" AGY_VERSION; }

# NIE wywołuje die — patrz komentarz przy claude_remote_version.
agy_remote_version() {
  local json ver
  need_cmd jq "apt install jq"
  json="$(_agy_manifest)" || return 1
  ver="$(printf '%s' "$json" | jq -r '.version // empty' 2>/dev/null || true)"
  if [ -z "$ver" ]; then
    error "agy: manifest nie zawiera pola .version"
    return 1
  fi
  printf '%s' "$ver"
}

agy_channel_note() {
  local run rec
  run="$(agy_installed_version)"
  rec="$(agy_recorded_version)"
  [ -n "$run" ] && [ -n "$rec" ] && [ "$run" != "$rec" ] \
    && printf 'self-update w tle: działa %s, zainstalowano %s' "$run" "$rec"
  return 0
}

agy_install() {
  local action="$1" ver url sha512 payload extract_dir dest old json
  need_cmd jq "apt install jq"
  ver="$(agy_remote_version)" \
    || die "agy: nie mogę ustalić wersji do instalacji (szczegóły wyżej)"
  json="$(_agy_manifest)" || die "agy: brak manifestu"
  url="$(printf '%s' "$json" | jq -r '.url // empty')"
  sha512="$(printf '%s' "$json" | jq -r '.sha512 // empty')"
  [ -n "$ver" ] && [ -n "$url" ] && [ -n "$sha512" ] \
    || die "agy: niekompletny manifest (version/url/sha512)"
  case "$url" in
    https://*) : ;;
    *) die "agy: manifest wskazuje nie-HTTPS URL: $url — odmowa" ;;
  esac

  info "Antigravity CLI ${ver} — pobieram i weryfikuję SHA-512"
  case "$url" in
    *.tar.gz*) payload="$DL_DIR/agy-${ver}.tar.gz" ;;
    *)         payload="$DL_DIR/agy-${ver}.bin" ;;
  esac
  download "$url" "$payload"
  sha512_verify "$payload" "$sha512"

  dest="$WORK6/tools/agy/versions/$ver"
  ensure_dir "$dest" 0700
  case "$payload" in
    *.tar.gz)
      extract_dir="$(mktemp -d "$WORK6/tmp/agy.XXXXXX")"
      tar -xzf "$payload" -C "$extract_dir" antigravity \
        || die "agy: w archiwum brak binarki 'antigravity'"
      install -m 0755 -- "$extract_dir/antigravity" "$dest/agy"
      rm -rf -- "$extract_dir"
      ;;
    *)
      install -m 0755 -- "$payload" "$dest/agy"
      ;;
  esac
  rm -f -- "$payload"
  ln -sfn -- "$dest" "$WORK6/tools/agy/current"

  if ! timeout 20 env HOME="$WORK6/home" "$dest/agy" --version >/dev/null 2>&1; then
    warn "agy --version nie odpowiedziało (TUI bywa wybredne poza terminalem) — zweryfikuje to doctor.sh"
  else
    ok "agy: $(timeout 20 env HOME="$WORK6/home" "$dest/agy" --version 2>/dev/null | head -n1)"
  fi

  record_component agy "$ver" "$url" "$sha512" "$action"
  warn "pamiętaj: agy aktualizuje się sam w tle — wersja może odjechać od manifestu (raportuje doctor.sh)"

  for old in "$WORK6/tools/agy/versions"/*; do
    [ -d "$old" ] || continue
    [ "$old" = "$dest" ] && continue
    if confirm "Usunąć starą wersję agy: $(basename "$old")?" tak; then
      rm -rf -- "$old"
    fi
  done
}
